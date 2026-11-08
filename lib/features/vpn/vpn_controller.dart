import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vpn_service/core/models/mihomo_config.dart';
import 'package:vpn_service/core/services/clash_yaml_parser.dart';
import 'package:vpn_service/core/services/mihomo_service.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/core/services/xray_json_parser.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

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
  bool _autoReconnecting = false;

  SplitTunnelMode _splitTunnelMode = SplitTunnelMode.allThroughVpn;
  Set<String> _selectedPackages = <String>{};

  @override
  VpnUiState build() {
    _statusSub?.cancel();
    _statusSub = _mihomo.stateStream.listen(_onMihomoStatus);
    ref.onDispose(() {
      _statusSub?.cancel();
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

    if (mounted) {
      setState(() {
        if (modeRaw != null) {
          _splitTunnelMode = SplitTunnelMode.values.firstWhere(
            (m) => m.index == int.tryParse(modeRaw) ?? 0,
            orElse: () => SplitTunnelMode.allThroughVpn,
          );
        }
        _selectedPackages = pkgsRaw.toSet();
      });
    }
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

  void _onMihomoStatus(MihomoUiState state) {
    final mapped = switch (state.state) {
      MihomoTunnelState.connected => TunnelState.connected,
      MihomoTunnelState.connecting => TunnelState.connecting,
      MihomoTunnelState.disconnected => TunnelState.disconnected,
      MihomoTunnelState.error => TunnelState.error,
    };

    _currentState = _currentState.copyWith(
      state: mapped,
      currentServer: state.currentServer,
      error: state.error,
    );
    state = _currentState;

    // Автоподключение при обрыве.
    if (state.state == MihomoTunnelState.disconnected &&
        _currentState.state == TunnelState.disconnected &&
        !_autoReconnecting) {
      _autoReconnecting = true;
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        _autoReconnecting = false;
        if (_currentState.state == TunnelState.disconnected) {
          await autoConnect();
        }
      }));
    }
  }

  VpnUiState _currentState = const VpnUiState();

  /// Импортирует профиль и сохраняет в ProfileRepository (sqflite).
  ///
  /// Порядок разбора:
  ///  1. WireGuard/AmneziaWG .conf (WGConfigParser) → type 'awg'
  ///  2. Clash/Mihomo YAML (ClashYamlParser) → type 'clash'
  ///  3. Xray JSON (XrayJsonParser) → type 'xray'
  ///  4. vless://, hysteria2://, подписки (ProfileParser) → type 'vless' / 'other'
  Future<VpnConfig?> importProfile(String input) async {
    VpnConfig? config;
    String? detectedType;

    // 1) WireGuard/AmneziaWG .conf
    if (WGConfigParser.looksLikeWireGuardConf(input)) {
      try {
        final wg = const WGConfigParser().parse(input);
        config = VpnConfig(
          remark: wg.name,
          profileType: ProfileType.awg,
          rawConfig: input,
          xrayJson: '', // Mihomo генерирует конфиг из rawConfig
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
          profileType: ProfileType.other,
          rawConfig: input,
          xrayJson: input,
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
      profileType: ProfileType.values.firstWhere(
        (p) => p.name == last.type,
        orElse: () => ProfileType.other,
      ),
      rawConfig: last.rawConfig,
      xrayJson: last.rawConfig,
      type: last.type,
    );
  }

  /// Запускает туннель Mihomo по профилю.
  Future<void> connect(VpnConfig config) async {
    _currentState = state.copyWith(state: TunnelState.connecting, clearError: true);
    state = _currentState;

    try {
      final mihomoJson = MihomoService.generateMihomoConfig(
        rawConfig: config.rawConfig,
        configType: config.type,
        excludedApps: excludedAppsForMihomo,
      );

      await _mihomo.start(mihomoJson);

      _currentState = _currentState.copyWith(
        state: TunnelState.connecting,
        remark: config.remark,
        config: config,
      );
      state = _currentState;
    } on Object catch (e) {
      _currentState = _currentState.copyWith(
        state: TunnelState.error,
        error: '$e',
      );
      state = _currentState;
    }
  }

  /// Автоподключение: Mihomo сам выбирает лучший сервер через url-test.
  Future<void> autoConnect({String? subscription}) async {
    final prefs = await SharedPreferences.getInstance();
    final input = subscription ?? prefs.getString(_subscriptionKey) ?? '';

    _currentState = state.copyWith(
      state: TunnelState.connecting,
      remark: 'Поиск лучшего сервера…',
      clearError: true,
    );
    state = _currentState;

    List<VpnConfig> configs = <VpnConfig>[];

    if (input.startsWith('http://') || input.startsWith('https://')) {
      // Подписка по URL
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
            profileType: ProfileType.values.firstWhere(
              (t) => t.name == p.type,
              orElse: () => ProfileType.other,
            ),
            rawConfig: p.rawConfig,
            xrayJson: p.rawConfig,
            type: p.type,
          );
        }).toList(growable: false);
      }
    }

    if (configs.isEmpty) {
      _currentState = state.copyWith(
        state: TunnelState.error,
        error: 'Нет конфигураций. Загрузите Clash YAML или .conf.',
      );
      state = _currentState;
      return;
    }

    // Mihomo url-test сам выберет лучший сервер. Сохраняем все профили
    // и подключаемся к первому (Mihomo внутренне переключит на лучший).
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
      _currentState = state.copyWith(state: TunnelState.disconnected);
      state = _currentState;
    }
  }
}

final vpnControllerProvider =
    NotifierProvider<VpnController, VpnUiState>(VpnController.new);
