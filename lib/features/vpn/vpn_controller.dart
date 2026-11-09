import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/clash_yaml_parser.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/core/services/xray_json_parser.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Безопасное хранилище (flutter_secure_storage).
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

/// Состояние подключения VPN для UI.
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
    this.profileId,
  });

  final TunnelState state;
  final TunnelMetrics metrics;
  final String remark;
  final String? error;
  final String? ipBefore;
  final String? ipAfter;
  final VpnConfig? config;
  final String currentServer;

  /// id профиля, по которому поднят туннель (для подсветки в списке).
  final String? profileId;

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
    String? profileId,
    bool clearProfileId = false,
    bool clearIpAfter = false,
  }) {
    return VpnUiState(
      state: state ?? this.state,
      metrics: metrics ?? this.metrics,
      remark: remark ?? this.remark,
      error: clearError ? null : (error ?? this.error),
      ipBefore: ipBefore ?? this.ipBefore,
      ipAfter: clearIpAfter ? null : (ipAfter ?? this.ipAfter),
      config: config ?? this.config,
      currentServer: currentServer ?? this.currentServer,
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
    );
  }
}

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
final selectedAppsProvider = StateProvider<Set<String>>((ref) => <String>{});

/// Центральный контроллер подключения.
///
/// Реальные движки:
///  - `awg` / `clash` (WireGuard/AmneziaWG) → нативный AwgBridge (VpnService +
///    GoBackend, честный TUN);
///  - `vless` / `xray` / прочие → flutter_vless (нативный Xray VpnService).
///
/// MihomoBridge больше не используется: он не поднимал VpnService/TUN.
class VpnController extends Notifier<VpnUiState> {
  static const _subscriptionKey = 'subscription_url';
  static const _splitTunnelModeKey = 'split_tunnel_mode';
  static const _selectedAppsKey = 'split_tunnel_selected_apps';

  /// Жёсткий лимит ожидания установки туннеля.
  static const Duration connectTimeout = Duration(seconds: 15);

  ProfileRepository get _profiles => ref.read(profileRepositoryProvider);
  PlatformBridge get _platform => ref.read(platformBridgeProvider);

  MethodChannel? _controlChannel;
  VpnService? _xray;
  VpnConfig? _lastXrayConfig;
  StreamSubscription<VlessStatus>? _xrayStatusSub;
  bool _stopping = false;

  SplitTunnelMode _splitTunnelMode = SplitTunnelMode.allThroughVpn;
  Set<String> _selectedPackages = <String>{};

  @override
  VpnUiState build() {
    // Статус нативного AWG-туннеля → состояние UI.
    ref.listen<AwgSessionState>(awgSessionProvider, _onAwgState);

    // Канал для команд из уведомления foreground service (Ускорить / Остановить).
    _controlChannel = const MethodChannel('dev.local.vpnservice/vpn_control');
    _controlChannel!.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'disconnect':
        case 'stop':
          await forceResetVpn();
          return null;
        case 'accelerate':
          await accelerate();
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });

    ref.onDispose(() {
      _xrayStatusSub?.cancel();
      _controlChannel?.setMethodCallHandler(null);
      unawaited(_xray?.dispose());
    });
    _loadSplitTunnelSettings();
    return const VpnUiState();
  }

  // --- Настройки раздельного туннелирования ---

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

  Future<void> _saveSplitTunnelSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_splitTunnelModeKey, _splitTunnelMode.index.toString());
    await prefs.setStringList(_selectedAppsKey, _selectedPackages.toList());
  }

  Future<void> toggleApp(String packageName) async {
    if (_selectedPackages.contains(packageName)) {
      _selectedPackages.remove(packageName);
    } else {
      _selectedPackages.add(packageName);
    }
    await _saveSplitTunnelSettings();
  }

  /// Список приложений, исключаемых из туннеля.
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

  // --- Реальное состояние ---

  void _onAwgState(AwgSessionState? previous, AwgSessionState next) {
    state = state.copyWith(
      metrics: TunnelMetrics(
        uploadSpeed: next.txSpeed,
        downloadSpeed: next.rxSpeed,
        rttMs: next.rttMs,
      ),
      ipBefore: next.ipBefore,
      ipAfter: next.publicIp,
    );

    if (state.state == TunnelState.connected) {
      final wasUp = previous?.phase == AwgPhase.up;
      if (next.phase == AwgPhase.error) {
        state = state.copyWith(
          state: TunnelState.error,
          error: next.error ?? 'Туннель отключился',
        );
        unawaited(_hideNotification());
      } else if (wasUp && next.phase == AwgPhase.idle) {
        state = state.copyWith(
          state: TunnelState.disconnected,
          currentServer: '',
        );
        unawaited(_hideNotification());
      }
    }
  }

  // --- Импорт профилей ---

  /// Импортирует профиль(и) и сохраняет в ProfileRepository.
  ///
  /// Clash YAML с несколькими WireGuard-прокси сохраняется как отдельный
  /// профиль на каждый сервер — так в UI появляется выбор страны.
  Future<VpnConfig?> importProfile(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      state = state.copyWith(error: 'Пустой конфиг');
      return null;
    }

    VpnConfig? first;

    // 1) WireGuard/AmneziaWG .conf
    if (WGConfigParser.looksLikeWireGuardConf(text)) {
      try {
        final wg = const WGConfigParser().parse(text);
        await _saveEntity(
          id: _idFor('awg', wg.name),
          name: wg.name,
          raw: text,
          type: 'awg',
          priority: 0,
        );
        first = VpnConfig(
          remark: wg.name,
          protocol: ProfileProtocol.wireguard,
          xrayJson: wg.toXrayJson(),
          profileType: ProfileType.awg,
          rawConfig: text,
          type: 'awg',
        );
      } on WGConfigParseException catch (e) {
        state = state.copyWith(error: 'WireGuard-конфиг: ${e.message}');
        return null;
      }
    }

    // 2) Clash/Mihomo YAML — каждый WireGuard-прокси отдельным профилем.
    if (first == null && ClashYamlParser.looksLikeClashYaml(text)) {
      try {
        final list = const ClashYamlParser().parseWireGuardConfigs(text);
        if (list.isEmpty) {
          state = state.copyWith(
            error: 'В Clash YAML нет wireguard/amneziawg-прокси. '
                'Для VLESS добавьте vless:// ссылку.',
          );
          return null;
        }
        for (var i = 0; i < list.length; i++) {
          final wg = list[i];
          final perServer = ClashYamlParser.proxyYamlByName(text, wg.name) ?? text;
          await _saveEntity(
            id: _idFor('clash', wg.name),
            name: wg.name,
            raw: perServer,
            type: 'clash',
            priority: i,
          );
          first ??= VpnConfig(
            remark: wg.name,
            protocol: ProfileProtocol.wireguard,
            xrayJson: wg.toXrayJson(),
            profileType: ProfileType.clash,
            rawConfig: perServer,
            type: 'clash',
          );
        }
      } on ClashYamlParseException catch (e) {
        state = state.copyWith(error: 'Clash YAML: ${e.message}');
        return null;
      }
    }

    // 3) Xray JSON с WireGuard outbound
    if (first == null && XrayJsonParser.looksLikeWireGuardXrayJson(text)) {
      try {
        final cfg = const XrayJsonParser().parse(text);
        await _saveEntity(
          id: _idFor('xray', cfg.remark),
          name: cfg.remark,
          raw: text,
          type: 'xray',
          priority: 0,
        );
        first = cfg;
      } on XrayJsonParseException catch (e) {
        state = state.copyWith(error: 'Xray JSON: ${e.message}');
        return null;
      }
    }

    // 4) vless://, hysteria2://, подписки и пр.
    if (first == null) {
      VpnConfig? cfg;
      try {
        cfg = const ProfileParser().parseOne(text);
      } on Object {
        cfg = _parseWithPlugin(text);
      }
      if (cfg != null) {
        final type = cfg.protocol == ProfileProtocol.vless ? 'vless' : 'other';
        await _saveEntity(
          id: _idFor(type, cfg.remark),
          name: cfg.remark,
          raw: text,
          type: type,
          priority: 0,
        );
        first = cfg;
      }
    }

    if (first == null) {
      state = state.copyWith(error: 'Импорт не удался: формат не распознан');
      return null;
    }

    state = state.copyWith(remark: first.remark, clearError: true);
    return first;
  }

  Future<void> _saveEntity({
    required String id,
    required String name,
    required String raw,
    required String type,
    required int priority,
  }) async {
    // Стабильный id: тип + имя (без hashCode — он нестабилен между запусками).
    await _profiles.saveProfile(ProfileEntity(
      id: id,
      name: name,
      rawConfig: raw,
      type: type,
      priority: priority,
      enabled: true,
    ));
  }

  static String _idFor(String type, String name) {
    final hash = base64Url
        .encode(utf8.encode('$type|$name'))
        .replaceAll('=', '')
        .substring(0, 12);
    return '$type-$hash';
  }

  VpnConfig? _parseWithPlugin(String input) {
    try {
      final decoded = jsonDecode(input) as Map<String, dynamic>?;
      if (decoded != null && decoded.containsKey('outbounds')) {
        return VpnConfig(
          remark: (decoded['remarks'] ?? 'sing-box JSON').toString(),
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
    return _configFromEntity(profiles.first);
  }

  VpnConfig _configFromEntity(ProfileEntity profile) {
    return VpnConfig(
      remark: profile.name,
      protocol: _protocolForType(profile.type),
      xrayJson: profile.rawConfig,
      profileType: ProfileType.values.firstWhere(
        (p) => p.name == profile.type,
        orElse: () => ProfileType.other,
      ),
      rawConfig: profile.rawConfig,
      type: profile.type,
    );
  }

  static ProfileProtocol _protocolForType(String type) {
    switch (type) {
      case 'awg':
      case 'clash':
        return ProfileProtocol.wireguard;
      case 'vless':
        return ProfileProtocol.vless;
      default:
        return ProfileProtocol.values.firstWhere(
          (p) => p.name == type,
          orElse: () => ProfileProtocol.other,
        );
    }
  }

  // --- Подключение ---

  /// Подключает сохранённый профиль (выбранный пользователем сервер).
  Future<void> connectProfile(ProfileEntity profile) async {
    await connect(_configFromEntity(profile), profileId: profile.id);
  }

  /// Запускает туннель по профилю.
  Future<void> connect(VpnConfig config, {String? profileId}) async {
    if (state.state == TunnelState.connecting) {
      appLog.warn('VPN', 'connect: уже идёт подключение — игнорирую');
      return;
    }

    await _stopEngines(hideNotification: false);

    state = state.copyWith(
      state: TunnelState.connecting,
      remark: config.remark,
      config: config,
      currentServer: config.remark,
      profileId: profileId,
      clearError: true,
    );

    appLog.info(
      'VPN',
      'Prepare: config=${config.remark}, type=${config.type}, '
          'raw=${config.rawConfig.length} bytes',
    );

    if (await _platform.isVpnActive()) {
      appLog.warn(
        'VPN',
        'Обнаружен активный VPN другого приложения. Android разрешает только '
            'один VPN-туннель — он будет заменён нашим.',
      );
    }

    try {
      if (_usesWireGuard(config)) {
        final wg = _wireGuardFrom(config);
        if (wg == null) {
          throw const VpnConnectException(
            'Не удалось разобрать WireGuard-конфиг: проверьте private-key, '
            'public-key, server и port.',
          );
        }
        await _connectAwg(wg);
      } else {
        await _connectXray(config);
      }

      state = state.copyWith(
        state: TunnelState.connected,
        remark: config.remark,
        currentServer: config.remark,
        clearError: true,
      );
      appLog.info('VPN', 'Connected: туннель поднят через ${config.remark}');
      unawaited(_showNotification(config.remark));
      unawaited(_verifyTraffic());
    } on TimeoutException {
      appLog.warn('VPN', 'Error: таймаут ${connectTimeout.inSeconds} с');
      await _stopEngines(hideNotification: false);
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось перехватить трафик: таймаут '
            '${connectTimeout.inSeconds} с. Туннель не поднялся. '
            'Проверьте, что другой VPN выключен, и повторите.',
      );
    } on Object catch (e) {
      appLog.warn('VPN', 'Error: $e');
      await _stopEngines(hideNotification: false);
      state = state.copyWith(
        state: TunnelState.error,
        error: _humanError(e),
      );
    }
  }

  bool _usesWireGuard(VpnConfig config) {
    final type = config.type.toLowerCase();
    if (type == 'awg' || type == 'clash') return true;
    if (WGConfigParser.looksLikeWireGuardConf(config.rawConfig)) return true;
    try {
      final m = jsonDecode(config.xrayJson) as Map<String, dynamic>;
      final outbounds = m['outbounds'] as List<dynamic>?;
      if (outbounds == null) return false;
      for (final ob in outbounds) {
        if (ob is Map && ob['protocol'] == 'wireguard') return true;
      }
    } on Object {
      // ignore
    }
    return false;
  }

  WireGuardConfig? _wireGuardFrom(VpnConfig config) {
    final raw = config.rawConfig.trim();

    if (WGConfigParser.looksLikeWireGuardConf(raw)) {
      return const WGConfigParser().parse(raw);
    }

    if (ClashYamlParser.looksLikeClashYaml(raw)) {
      final list = const ClashYamlParser().parseWireGuardConfigs(raw);
      if (list.isEmpty) return null;
      return list.firstWhere(
        (c) => c.name == config.remark,
        orElse: () => list.first,
      );
    }

    return _wireGuardFromXrayJson(config.xrayJson, config.remark);
  }

  WireGuardConfig? _wireGuardFromXrayJson(String jsonStr, String name) {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final outbounds = map['outbounds'] as List<dynamic>?;
      if (outbounds == null) return null;
      Map<dynamic, dynamic>? settings;
      for (final ob in outbounds) {
        if (ob is Map && ob['protocol'] == 'wireguard') {
          settings = ob['settings'] as Map<dynamic, dynamic>?;
          break;
        }
      }
      if (settings == null) return null;

      final peers = settings['peers'] as List<dynamic>?;
      final peer = peers?.isNotEmpty == true ? peers!.first as Map : null;
      final endpoint = peer?['endpoint']?.toString() ?? '';
      final colon = endpoint.lastIndexOf(':');
      final host = colon > 0 ? endpoint.substring(0, colon) : endpoint;
      final port = colon > 0 ? int.tryParse(endpoint.substring(colon + 1)) : null;
      final addresses = (settings['address'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false);
      final dns = (settings['remoteDNS'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false);
      final allowedIps = (peer?['allowedIPs'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false);
      final privateKey = settings['secretKey']?.toString() ?? '';
      final publicKey = peer?['publicKey']?.toString() ?? '';
      if (privateKey.isEmpty ||
          publicKey.isEmpty ||
          host.isEmpty ||
          port == null) {
        return null;
      }
      return WireGuardConfig(
        name: name.isEmpty ? 'WireGuard' : name,
        privateKey: privateKey,
        addresses: addresses.isEmpty
            ? const <String>['172.16.0.2/32']
            : addresses,
        peerPublicKey: publicKey,
        peerPresharedKey: peer?['preSharedKey']?.toString(),
        endpointHost: host,
        endpointPort: port,
        allowedIps:
            allowedIps.isEmpty ? const <String>['0.0.0.0/0', '::/0'] : allowedIps,
        dns: dns,
        mtu: (settings['mtu'] as num?)?.toInt(),
      );
    } on Object catch (e) {
      appLog.warn('VPN', 'wireguard xray json: $e');
      return null;
    }
  }

  Future<void> _connectAwg(WireGuardConfig wg) async {
    appLog.info('VPN', 'Core Start: нативный AmneziaWG');
    final notifier = ref.read(awgSessionProvider.notifier);

    await notifier.connect(wg).timeout(connectTimeout);

    final session = ref.read(awgSessionProvider);
    if (!session.up) {
      throw VpnConnectException(
        session.error ??
            'Нативный слой не поднял TUN. Проверьте ключи и endpoint.',
      );
    }

    appLog.info(
      'VPN',
      'Waiting for Tunnel → UP: ${wg.name}, endpoint=${session.endpoint}, '
          'dns=${session.dns.join(",")}, mtu=${session.mtu}',
    );
    state = state.copyWith(
      ipBefore: session.ipBefore,
      ipAfter: session.publicIp,
    );
  }

  Future<void> _connectXray(VpnConfig config) async {
    appLog.info('VPN', 'Core Start: flutter_vless (Xray VpnService)');
    final service = VpnService();
    _xray = service;
    _lastXrayConfig = config;
    _xrayStatusSub?.cancel();
    _xrayStatusSub = service.statusStream.listen((status) {
      if (state.state != TunnelState.connected) return;
      if (status.connectionState == VlessConnectionState.disconnected) {
        state = state.copyWith(
          state: TunnelState.error,
          error: 'Xray-туннель отключился',
        );
        unawaited(_hideNotification());
      }
    });

    await service.initialize().timeout(connectTimeout);
    final ok = await service.requestPermission();
    if (!ok) {
      throw const VpnConnectException(
        'Разрешение VPN не предоставлено — подтвердите диалог Android.',
      );
    }
    await service.start(config).timeout(connectTimeout);
    appLog.info('VPN', 'Waiting for Tunnel → Xray started');
  }

  Future<void> _verifyTraffic() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (state.state != TunnelState.connected) return;
    if (_xray != null) {
      final changed = await _xray!.verifyRealTraffic();
      if (changed == false) {
        appLog.warn('VPN', 'IP не изменился после подключения Xray');
      }
      return;
    }
    final awg = ref.read(awgSessionProvider.notifier);
    final before = state.ipBefore;
    final after = await awg.checkIp();
    if (after != null && before != null && after == before) {
      appLog.warn('VPN', 'IP не изменился после подключения AWG: $after');
    }
  }

  /// Ручной выбор «лучшего» сервера: первый включённый профиль.
  Future<void> autoConnect() async {
    final profiles = await _profiles.getAllProfiles();
    final usable = profiles.where((p) => p.enabled).toList(growable: false);
    if (usable.isEmpty) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Нет конфигураций. Загрузите Clash YAML или .conf.',
      );
      return;
    }
    await connectProfile(usable.first);
  }

  Future<void> setSubscription(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionKey, url);
  }

  // --- Отключение ---

  Future<void> disconnect() async {
    await _stopEngines(hideNotification: true);
    state = state.copyWith(
      state: TunnelState.disconnected,
      currentServer: '',
      clearError: true,
    );
  }

  Future<void> _stopEngines({required bool hideNotification}) async {
    if (_stopping) return;
    _stopping = true;
    try {
      await ref.read(awgSessionProvider.notifier).disconnect();

      final xray = _xray;
      _xray = null;
      _lastXrayConfig = null;
      await _xrayStatusSub?.cancel();
      _xrayStatusSub = null;
      if (xray != null) {
        try {
          await xray.stop();
        } on Object catch (e) {
          appLog.warn('VPN', 'xray stop: $e');
        }
        await xray.dispose();
      }

      await _platform.stopKeepAlive();
      if (hideNotification) await _hideNotification();
    } finally {
      _stopping = false;
    }
  }

  /// Ускорение: переподключение к тому же серверу (свежий handshake).
  Future<void> accelerate() async {
    final cfg = _xray != null ? _lastXrayConfig : state.config;
    if (cfg == null) {
      appLog.warn('VPN', 'accelerate: нет активного конфига');
      return;
    }
    appLog.info('VPN', 'accelerate: переподключение ${cfg.remark}');
    await connect(cfg, profileId: state.profileId);
  }

  /// Полная остановка, привязанная к красной кнопке и действию уведомления.
  Future<void> forceResetVpn() async {
    state = state.copyWith(state: TunnelState.connecting);
    await _stopEngines(hideNotification: true);
    state = state.copyWith(
      state: TunnelState.disconnected,
      remark: '',
      config: null,
      currentServer: '',
      clearProfileId: true,
      ipAfter: null,
      clearIpAfter: true,
      clearError: true,
    );
  }

  /// Совместимость со старым именем.
  Future<void> hardReset() => forceResetVpn();

  Future<void> _showNotification(String server) async {
    try {
      await _platform.startKeepAlive(server: server);
    } on Object catch (e) {
      appLog.warn('VPN', 'show_notification: $e');
    }
  }

  Future<void> _hideNotification() async {
    try {
      await _platform.stopKeepAlive();
    } on Object catch (e) {
      appLog.warn('VPN', 'hide_notification: $e');
    }
  }

  String _humanError(Object e) {
    final text = e.toString();
    if (text.contains('VPN permission') || text.contains('permission')) {
      return 'Разрешение VPN не предоставлено — подтвердите диалог Android.';
    }
    if (text.contains('TUN') || text.contains('establish')) {
      return 'Не удалось перехватить трафик: система отклонила TUN-интерфейс. '
          'Выключите другой VPN и повторите.';
    }
    return text.replaceFirst('Exception: ', '');
  }
}

class VpnConnectException implements Exception {
  const VpnConnectException(this.message);
  final String message;

  @override
  String toString() => message;
}

final vpnControllerProvider =
    NotifierProvider<VpnController, VpnUiState>(VpnController.new);
