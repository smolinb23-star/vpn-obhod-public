import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/clash_yaml_parser.dart';
import 'package:vpn_service/core/services/mihomo_service.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/core/services/xray_json_parser.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Безопасное хранилище (flutter_secure_storage).
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

/// Состояние подключения Mihomo для UI.
@immutable
class VpnUiState {
  const VpnUiState({
    this.state = TunnelState.disconnected,
    this.metrics = const TunnelMetrics(),
    this.remark = '',
    this.error,
    this.ipBefore,
    this.ipAfter,
    this.config,
    this.currentServer = '',
  });

  final TunnelState state;
  final TunnelMetrics metrics;
  final String remark;
  final String? error;
  final String? ipBefore;
  final String? ipAfter;
  final VpnConfig? config;
  final String currentServer;

  VpnUiState copyWith({
    TunnelState? state,
    TunnelMetrics? metrics,
    String? remark,
    String? error,
    bool clearError = false,
    String? ipBefore,
    String? ipAfter,
    VpnConfig? config,
    String? currentServer,
  }) {
    return VpnUiState(
      state: state ?? this.state,
      metrics: metrics ?? this.metrics,
      remark: remark ?? this.remark,
      error: clearError ? null : (error ?? this.error),
      ipBefore: ipBefore ?? this.ipBefore,
      ipAfter: ipAfter ?? this.ipAfter,
      config: config ?? this.config,
      currentServer: currentServer ?? this.currentServer,
    );
  }
}

/// Провайдер MihomoService.
final mihomoServiceProvider = Provider<MihomoService>((ref) {
  return MihomoService();
});

/// Режим раздельного туннелирования.
enum SplitTunnelMode {
  allThroughVpn, // Все через VPN
  onlySelected, // Только выбранные приложения через VPN
  exceptSelected, // Все кроме выбранных через VPN
}

/// Провайдер режима раздельного туннелирования.
final splitTunnelModeProvider =
    StateProvider<SplitTunnelMode>((ref) => SplitTunnelMode.allThroughVpn);

/// Провайдер списка выбранных пакетов.
final selectedAppsProvider =
    StateProvider<Set<String>>((ref) => <String>{});

class VpnController extends Notifier<VpnUiState> {
  static const _subscriptionKey = 'subscription_url';
  static const _splitTunnelModeKey = 'split_tunnel_mode';
  static const _selectedAppsKey = 'split_tunnel_selected_apps';

  MihomoService get _mihomo => ref.read(mihomoServiceProvider);
  ProfileRepository get _profiles => ref.read(profileRepositoryProvider);

  StreamSubscription? _statusSub;
  MethodChannel? _controlChannel;
  bool _autoReconnecting = false;

  SplitTunnelMode _splitTunnelMode = SplitTunnelMode.allThroughVpn;
  Set<String> _selectedPackages = <String>{};

  @override
  VpnUiState build() {
    _statusSub?.cancel();
    _statusSub = _mihomo.stateStream.listen(_onMihomoStatus);

    // Канал для команд из уведомления foreground service (Ускорить / Остановить)
    _controlChannel = const MethodChannel('dev.local.vpnservice/vpn_control');
    _controlChannel!.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'disconnect':
          await disconnect();
          return null;
        case 'accelerate':
          await accelerate();
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });

    ref.onDispose(() {
      _statusSub?.cancel();
      _controlChannel?.setMethodCallHandler(null);
      _mihomo.dispose();
    });
    _loadSplitTunnelSettings();
    return const VpnUiState();
  }

  /// Загружает настройки раздельного туннелирования.
  Future<void> _loadSplitTunnelSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeRaw = prefs.getString(_splitTunnelModeKey);
    final pkgsRaw = prefs.getStringList(_selectedAppsKey) ?? <String>[];

    if (modeRaw != null) {
      _splitTunnelMode = SplitTunnelMode.values.firstWhere(
        (m) => m.index == (int.tryParse(modeRaw) ?? 0),
        orElse: () => SplitTunnelMode.allThroughVpn,
      );
    }
    _selectedPackages = pkgsRaw.toSet();
    state = state.copyWith();
  }

  /// Сохраняет настройки раздельного туннелирования.
  Future<void> _saveSplitTunnelSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_splitTunnelModeKey, _splitTunnelMode.index.toString());
    await prefs.setStringList(_selectedAppsKey, _selectedPackages.toList());
  }

  /// Переключает выбор приложения.
  Future<void> toggleApp(String packageName) async {
    if (_selectedPackages.contains(packageName)) {
      _selectedPackages.remove(packageName);
    } else {
      _selectedPackages.add(packageName);
    }
    await _saveSplitTunnelSettings();
  }

  /// Возвращает список package names для Mihomo PROCESS-NAME правил.
  List<String> get excludedAppsForMihomo {
    switch (_splitTunnelMode) {
      case SplitTunnelMode.allThroughVpn:
        return <String>[];
      case SplitTunnelMode.onlySelected:
        return <String>[];
      case SplitTunnelMode.exceptSelected:
        return _selectedPackages.toList();
    }
  }

  void _onMihomoStatus(MihomoUiState mihomoState) {
    final mapped = switch (mihomoState.state) {
      MihomoTunnelState.connected => TunnelState.connected,
      MihomoTunnelState.connecting => TunnelState.connecting,
      MihomoTunnelState.disconnected => TunnelState.disconnected,
      MihomoTunnelState.error => TunnelState.error,
    };

    state = state.copyWith(
      state: mapped,
      currentServer: mihomoState.currentServer,
      error: mihomoState.error,
    );

    // Автоподключение при обрыве.
    if (mapped == TunnelState.disconnected && !_autoReconnecting) {
      _autoReconnecting = true;
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        _autoReconnecting = false;
        if (state.state == TunnelState.disconnected) {
          await autoConnect();
        }
      }));
    }
  }

  /// Импортирует профиль и сохраняет в ProfileRepository (sqflite).
  Future<VpnConfig?> importProfile(String input) async {
    VpnConfig? config;
    String? detectedType;

    // 1) WireGuard/AmneziaWG .conf
    if (WGConfigParser.looksLikeWireGuardConf(input)) {
      try {
        final wg = const WGConfigParser().parse(input);
        config = VpnConfig(
          remark: wg.name,
          protocol: ProfileProtocol.wireguard,
          xrayJson: '',
          profileType: ProfileType.awg,
          rawConfig: input,
          type: 'awg',
        );
        detectedType = 'awg';
      } on WGConfigParseException catch (e) {
        state = state.copyWith(error: 'WireGuard-конфиг: ${e.message}');
        return null;
      }
    }

    // 2) Clash/Mihomo YAML
    if (config == null && ClashYamlParser.looksLikeClashYaml(input)) {
      try {
        final clashConfigs = const ClashYamlParser().parse(input);
        if (clashConfigs.isNotEmpty) {
          config = clashConfigs.first;
          detectedType = 'clash';
          if (ClashYamlParser.isMasque(config)) {
            state = state.copyWith(
              error:
                  'MASQUE требует поддержку Sing-box. '
                  'Используйте другой протокол.',
            );
            return null;
          }
        }
      } on ClashYamlParseException catch (e) {
        state = state.copyWith(error: 'Clash YAML: ${e.message}');
        return null;
      }
    }

    // 3) Xray JSON с WireGuard outbound
    if (config == null && XrayJsonParser.looksLikeWireGuardXrayJson(input)) {
      try {
        config = const XrayJsonParser().parse(input);
        detectedType = 'xray';
      } on XrayJsonParseException catch (e) {
        state = state.copyWith(error: 'Xray JSON: ${e.message}');
        return null;
      }
    }

    // 4) vless://, hysteria2://, подписки, CIDR
    if (config == null) {
      try {
        config = const ProfileParser().parseOne(input);
        detectedType = config.protocol == ProfileProtocol.vless ? 'vless' : 'other';
      } on Object {
        config = _parseWithPlugin(input);
        detectedType = 'other';
      }
    }

    if (config == null) {
      state = state.copyWith(error: 'Импорт не удался: формат не распознан');
      return null;
    }

    // Сохраняем в ProfileRepository (sqflite)
    final entity = ProfileEntity(
      id: config.remark.hashCode.toString(),
      name: config.remark,
      rawConfig: input,
      type: detectedType ?? 'other',
      priority: 0,
      enabled: true,
    );
    await _profiles.saveProfile(entity);

    state = state.copyWith(remark: config.remark, clearError: true);
    return config;
  }

  VpnConfig? _parseWithPlugin(String input) {
    // Fallback: попробуем как sing-box JSON напрямую
    try {
      final decoded = jsonDecode(input) as Map<String, dynamic>?;
      if (decoded != null && decoded.containsKey('outbounds')) {
        return VpnConfig(
          remark: 'Mihomo JSON',
          protocol: ProfileProtocol.other,
          xrayJson: input,
          profileType: ProfileType.other,
          rawConfig: input,
          type: 'other',
        );
      }
    } on Object {
      // ignore
    }
    return null;
  }

  /// Восстанавливает последний активный профиль из репозитория.
  Future<VpnConfig?> restoreLast() async {
    final profiles = await _profiles.getAllProfiles();
    if (profiles.isEmpty) return null;
    final last = profiles.first;
    return VpnConfig(
      remark: last.name,
      protocol: ProfileProtocol.values.firstWhere(
        (p) => p.name == last.type,
        orElse: () => ProfileProtocol.other,
      ),
      xrayJson: last.rawConfig,
      profileType: ProfileType.values.firstWhere(
        (p) => p.name == last.type,
        orElse: () => ProfileType.other,
      ),
      rawConfig: last.rawConfig,
      type: last.type,
    );
  }

  /// Запускает туннель Mihomo по профилю.
  Future<void> connect(VpnConfig config) async {
    state = state.copyWith(state: TunnelState.connecting, clearError: true);

    appLog.info('VPN', 'Prepare: config=${config.remark}, type=${config.type}');

    try {
      appLog.info('VPN', 'Core Start: генерируем Mihomo JSON конфиг');

      final mihomoJson = MihomoService.generateMihomoConfig(
        rawConfig: config.rawConfig,
        configType: config.type,
        excludedApps: excludedAppsForMihomo,
      );

      appLog.info('VPN', 'Waiting for Tunnel: запуск Mihomo через MethodChannel');

      await _mihomo.start(mihomoJson);

      state = state.copyWith(
        state: TunnelState.connecting,
        remark: config.remark,
        config: config,
      );

      appLog.info('VPN', 'Connected: туннель установлен через ${config.remark}');

      // Показываем foreground service уведомление
      _controlChannel?.invokeMethod('show_notification', {
        'server': config.remark,
      });
    } on Object catch (e) {
      appLog.warn('VPN', 'Error: $e');
      state = state.copyWith(
        state: TunnelState.error,
        error: '$e',
      );
    }
  }

  /// Автоподключение: Mihomo сам выбирает лучший сервер через url-test.
  Future<void> autoConnect({String? subscription}) async {
    final prefs = await SharedPreferences.getInstance();
    final input = subscription ?? prefs.getString(_subscriptionKey) ?? '';

    state = state.copyWith(
      state: TunnelState.connecting,
      remark: 'Поиск лучшего сервера…',
      clearError: true,
    );

    List<VpnConfig> configs = <VpnConfig>[];

    if (input.startsWith('http://') || input.startsWith('https://')) {
      try {
        final resp = await http.Client()
            .get(Uri.parse(input))
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          configs = const ProfileParser().parseAll(resp.body);
        }
      } on Object {
        // ignore
      }
    } else if (input.isNotEmpty) {
      try {
        configs = const ProfileParser().parseAll(input);
      } on Object {
        // ignore
      }
    }

    if (configs.isEmpty) {
      final allProfiles = await _profiles.getAllProfiles();
      if (allProfiles.isNotEmpty) {
        configs = allProfiles.map((p) {
          return VpnConfig(
            remark: p.name,
            protocol: ProfileProtocol.values.firstWhere(
              (t) => t.name == p.type,
              orElse: () => ProfileProtocol.other,
            ),
            xrayJson: p.rawConfig,
            profileType: ProfileType.values.firstWhere(
              (t) => t.name == p.type,
              orElse: () => ProfileType.other,
            ),
            rawConfig: p.rawConfig,
            type: p.type,
          );
        }).toList(growable: false);
      }
    }

    if (configs.isEmpty) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Нет конфигураций. Загрузите Clash YAML или .conf.',
      );
      return;
    }

    // Mihomo url-test сам выберет лучший сервер.
    for (final c in configs) {
      final entity = ProfileEntity(
        id: c.remark.hashCode.toString(),
        name: c.remark,
        rawConfig: c.rawConfig,
        type: c.type,
        priority: configs.indexOf(c),
        enabled: true,
      );
      await _profiles.saveProfile(entity);
    }

    await connect(configs.first);
  }

  Future<void> setSubscription(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionKey, url);
  }

  Future<void> disconnect() async {
    try {
      await _mihomo.stop();
    } finally {
      state = state.copyWith(state: TunnelState.disconnected);
      // Скрываем foreground service уведомление
      _controlChannel?.invokeMethod('hide_notification', null);
    }
  }

  /// Ускорение: перезапускает url-test для поиска лучшего сервера.
  Future<void> accelerate() async {
    try {
      await _mihomo.accelerate();
      state = state.copyWith(
        state: TunnelState.connecting,
        remark: 'Поиск лучшего сервера…',
        clearError: true,
      );
    } on Object catch (e) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Ошибка ускорения: $e',
      );
    }
  }

  /// Жёсткий сброс: отключает VPN, очищает состояние, убивает нативный процесс.
  Future<void> hardReset() async {
    await disconnect();
    state = state.copyWith(
      state: TunnelState.disconnected,
      remark: '',
      config: null,
      currentServer: '',
      clearError: true,
    );
  }
}

final vpnControllerProvider =
    NotifierProvider<VpnController, VpnUiState>(VpnController.new);
