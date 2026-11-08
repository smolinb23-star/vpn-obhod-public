import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:http/http.dart' as http;

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Провайдер сервиса туннеля.
final vpnServiceProvider = Provider<VpnService>((ref) {
  final service = VpnService();
  ref.onDispose(service.dispose);
  return service;
});

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

/// Состояние подключения для UI.
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
  });

  final TunnelState state;
  final TunnelMetrics metrics;
  final String remark;
  final String? error;
  final String? ipBefore;
  final String? ipAfter;
  final VpnConfig? config;

  VpnUiState copyWith({
    TunnelState? state,
    TunnelMetrics? metrics,
    String? remark,
    String? error,
    bool clearError = false,
    String? ipBefore,
    String? ipAfter,
    VpnConfig? config,
  }) {
    return VpnUiState(
      state: state ?? this.state,
      metrics: metrics ?? this.metrics,
      remark: remark ?? this.remark,
      error: clearError ? null : (error ?? this.error),
      ipBefore: ipBefore ?? this.ipBefore,
      ipAfter: ipAfter ?? this.ipAfter,
      config: config ?? this.config,
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
final selectedAppsProvider =
    StateProvider<Set<String>>((ref) => <String>{});

class VpnController extends Notifier<VpnUiState> {
  static const _lastProfileKey = 'last_profile';
  static const _subscriptionKey = 'subscription_url';
  static const _splitTunnelModeKey = 'split_tunnel_mode';
  static const _selectedAppsKey = 'split_tunnel_selected_apps';

  VpnService get _service => ref.read(vpnServiceProvider);
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  StreamSubscription? _statusSub;
  bool _autoReconnecting = false;

  /// Режим раздельного туннелирования (загружается из secure storage).
  SplitTunnelMode _splitTunnelMode = SplitTunnelMode.allThroughVpn;

  /// Набор package names, исключённых из VPN (для режима exceptSelected)
  /// или выбранных для VPN (для режима onlySelected).
  Set<String> _selectedPackages = <String>{};

  @override
  VpnUiState build() {
    _statusSub?.cancel();
    _statusSub = _service.statusStream.listen(_onStatus);
    ref.onDispose(() => _statusSub?.cancel());
    // Загружаем настройки раздельного туннелирования при инициализации.
    _loadSplitTunnelSettings();
    return const VpnUiState();
  }

  /// Загружает настройки раздельного туннелирования из безопасного хранилища.
  Future<void> _loadSplitTunnelSettings() async {
    final storage = ref.read(secureStorageProvider);
    final modeRaw = await storage.read(key: _splitTunnelModeKey);
    final pkgsRaw = await storage.read(key: _selectedAppsKey);

    if (modeRaw != null) {
      try {
        _splitTunnelMode = SplitTunnelMode.values.firstWhere(
          (m) => m.index == int.parse(modeRaw),
          orElse: () => SplitTunnelMode.allThroughVpn,
        );
      } on Object {
        // ignore
      }
    }
    if (pkgsRaw != null && pkgsRaw.isNotEmpty) {
      _selectedPackages = pkgsRaw.split(',').toSet();
    }
  }

  /// Сохраняет настройки раздельного туннелирования.
  Future<void> _saveSplitTunnelSettings() async {
    final storage = ref.read(secureStorageProvider);
    await storage.write(key: _splitTunnelModeKey, value: _splitTunnelMode.index.toString());
    await storage.write(
      key: _selectedAppsKey,
      value: _selectedPackages.join(','),
    );
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

  /// Возвращает список package names, которые должны быть исключены из VPN
  /// (т.е. НЕ пойдут через туннель).
  List<String> get excludedAppsForVpnService {
    switch (_splitTunnelMode) {
      case SplitTunnelMode.allThroughVpn:
        return <String>[];
      case SplitTunnelMode.onlySelected:
        // Только выбранные через VPN → все остальные исключаем.
        // Для полного списка приложений нужна информация из device_apps,
        // но здесь у нас только выбранные. Возвращаем пустой список -
        // приложения из выбранного списка будут идти через VPN,
        // остальные - нет (логика обрабатывается на UI уровне).
        return <String>[];
      case SplitTunnelMode.exceptSelected:
        return _selectedPackages.toList();
    }
  }

  /// Возвращает список package names, которые ДОЛЖНЫ идти через VPN
  /// (для режима onlySelected).
  List<String> get includedAppsForVpnService {
    switch (_splitTunnelMode) {
      case SplitTunnelMode.allThroughVpn:
        return <String>[];
      case SplitTunnelMode.onlySelected:
        return _selectedPackages.toList();
      case SplitTunnelMode.exceptSelected:
        return <String>[];
    }
  }

  void _onStatus(VlessStatus status) {
    final mapped = switch (status.connectionState) {
      VlessConnectionState.connected => TunnelState.connected,
      VlessConnectionState.connecting => TunnelState.connecting,
      VlessConnectionState.disconnecting => TunnelState.connecting,
      VlessConnectionState.disconnected => TunnelState.disconnected,
      VlessConnectionState.unknown => null,
    };
    if (mapped != null) {
      state = state.copyWith(state: mapped);
    }
    // Тихий fallback: если соединение оборвалось — перезапускаем автопоиск.
    if (status.connectionState == VlessConnectionState.disconnected &&
        state.state == TunnelState.disconnected &&
        !_autoReconnecting) {
      _autoReconnecting = true;
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        _autoReconnecting = false;
        if (state.state == TunnelState.disconnected) {
          await autoConnect();
        }
      }));
    }
  }

  /// Импортирует профиль (ссылка/JSON/подписка) и запоминает его.
  ///
  /// Основной путь — чистый Dart-парсер [ProfileParser]; при неподдерживаемом
  /// формате используется fallback `FlutterVless.parse()` (подписки, Clash
  /// YAML, sing-box JSON, экзотические протоколы).
  Future<VpnConfig?> importProfile(String input) async {
    VpnConfig? config;
    // WireGuard/AmneziaWG .conf, вставленный как текст.
    if (WGConfigParser.looksLikeWireGuardConf(input)) {
      try {
        config = const WGConfigParser().importConf(input);
      } on WGConfigParseException catch (e) {
        state = state.copyWith(error: 'WireGuard-конфиг: ${e.message}');
        return null;
      }
    }
    if (config == null) {
      try {
        config = const ProfileParser().parseOne(input);
      } on Object {
        config = _parseWithPlugin(input);
      }
    }
    if (config == null) {
      state = state.copyWith(error: 'Импорт не удался: формат не распознан');
      return null;
    }
    await _storage.write(key: _lastProfileKey, value: config.toJsonString());
    state = state.copyWith(remark: config.remark, clearError: true);
    return config;
  }

  /// Сохраняет уже разобранный профиль (например, из .conf-импорта)
  /// без повторного парсинга.
  Future<void> saveProfile(VpnConfig config) async {
    await _storage.write(key: _lastProfileKey, value: config.toJsonString());
    state = state.copyWith(remark: config.remark, clearError: true);
  }

  VpnConfig? _parseWithPlugin(String input) {
    try {
      final parsed = FlutterVless.parse(input);
      return VpnConfig(
        remark: parsed.remark,
        protocol: ProfileProtocol.other,
        xrayJson: parsed.getFullConfiguration(),
      );
    } on Object {
      return null;
    }
  }

  Future<VpnConfig?> restoreLast() async {
    final raw = await _storage.read(key: _lastProfileKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return VpnConfig.fromJson(decoded);
      }
    } on Object {
      // повреждённое хранилище — молча игнорируем
    }
    return null;
  }

  /// Запускает туннель по профилю. Бросает исключение при небезопасном конфиге.
  Future<void> connect(VpnConfig config) async {
    state = state.copyWith(state: TunnelState.connecting, clearError: true);
    try {
      await _service.initialize();
      // CONNECTED может наступить сразу после start(), подписываемся заранее.
      final connected = Completer<void>();
      late final StreamSubscription<VlessStatus> sub;
      sub = _service.statusStream.listen((s) {
        if (s.connectionState == VlessConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        }
      });
      try {
        await _service.start(config, excludedApps: excludedAppsForVpnService);
        state = state.copyWith(
          state: TunnelState.connecting,
          remark: config.remark,
          config: config,
        );
        // Проверка реального трафика после установления соединения.
        unawaited(_verifyTraffic(connected).whenComplete(sub.cancel));
      } catch (_) {
        await sub.cancel();
        rethrow;
      }
    } on Object catch (e) {
      state = state.copyWith(state: TunnelState.error, error: '$e');
    }
  }

  /// Запускает каскадный туннель: сначала до российского сервера, затем
  /// трафик перенаправляется на зарубежный сервер через первый туннель.
  Future<void> connectCascade(VpnConfig config) async {
    state = state.copyWith(state: TunnelState.connecting, clearError: true);
    try {
      await _service.initialize();

      // Сначала подключаемся к промежуточному серверу (Россия)
      final outbound1 = config.cascadeOutbound1;
      if (outbound1 == null) {
        throw Exception('Каскадный конфиг без промежуточного сервера');
      }

      await _service.startCascade(config);

      state = state.copyWith(
        state: TunnelState.connecting,
        remark:
            '${config.remark} (каскад: ${outbound1.remark} → ${config.cascadeOutbound2?.remark ?? 'цель'})',
        config: config,
      );

      // Проверка реального трафика после установления соединения.
      unawaited(_verifyTraffic(Completer<void>()..complete()).whenComplete(() {}));
    } on Object catch (e) {
      state = state.copyWith(state: TunnelState.error, error: '$e');
    }
  }

  /// Запускает CIDR-маршрутизацию: трафик только к указанным IP-адресам
  /// проходит через VPN, остальной — напрямую.
  Future<void> connectCidr(VpnConfig config) async {
    state = state.copyWith(state: TunnelState.connecting, clearError: true);
    try {
      await _service.initialize();

      // Для CIDR-маршрутизации поднимаем туннель с чёрной дырой (blackhole)
      // и настраиваем правила маршрутизации для указанных CIDR
      await _service.startCidr(config);

      state = state.copyWith(
        state: TunnelState.connecting,
        remark: config.remark,
        config: config,
      );

      // Проверка реального трафика
      unawaited(_verifyTraffic(Completer<void>()..complete()).whenComplete(() {}));
    } on Object catch (e) {
      state = state.copyWith(state: TunnelState.error, error: '$e');
    }
  }

  Future<void> autoConnect({String? subscription}) async {
    final input = subscription ??
        await _storage.read(key: _subscriptionKey) ??
        '';
    state = state.copyWith(
      state: TunnelState.connecting,
      remark: 'Поиск сервера…',
      clearError: true,
    );

    List<VpnConfig> configs = <VpnConfig>[];
    if (input.startsWith('http://') || input.startsWith('https://')) {
      final client = http.Client();
      try {
        final resp = await client
            .get(Uri.parse(input))
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          configs = const ProfileParser().parseAll(resp.body);
        }
      } on Object {
        // ignore
      } finally {
        client.close();
      }
    } else if (input.isNotEmpty) {
      try {
        configs = const ProfileParser().parseAll(input);
      } on Object {
        // ignore
      }
    }

    if (configs.isEmpty) {
      final last = await restoreLast();
      if (last != null) configs = <VpnConfig>[last];
    }

    if (configs.isEmpty) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Нет конфигураций. Вставьте подписку или конфиг.',
      );
      return;
    }

    // Probe: замеряем задержку, отбрасываем недоступные. Общий таймаут 15 с.
    List<(VpnConfig, int?)> probed;
    try {
      probed = await Future.wait(
        configs.map((c) async {
          final delay = await _service.probeDelay(c);
          return (c, delay);
        }),
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось найти рабочий сервер за 15 с. '
            'Проверьте конфиг или смените сеть (на мобильном интернете '
            'AmneziaWG может блокироваться).',
      );
      return;
    }

    final viable = probed.where((p) => p.$2 != null).toList()
      ..sort((a, b) => a.$2!.compareTo(b.$2!));

    if (viable.isEmpty) {
      for (final c in configs) {
        try {
          await connect(c);
          if (state.state == TunnelState.connected) return;
        } on Object {
          continue;
        }
      }
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось найти рабочий сервер. Проверьте конфиг или '
            'смените сеть (на мобильном интернете AmneziaWG может '
            'блокироваться).',
      );
      return;
    }

    for (final entry in viable) {
      try {
        await connect(entry.$1);
        if (state.state == TunnelState.connected) return;
      } on Object {
        continue;
      }
    }
    if (state.state != TunnelState.connected) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось подключиться ни к одному серверу. Проверьте '
            'конфиг или смените сеть (на мобильном интернете AmneziaWG '
            'может блокироваться).',
      );
    }
  }

  Future<void> setSubscription(String url) async {
    await _storage.write(key: _subscriptionKey, value: url);
  }

  Future<void> _verifyTraffic(Completer<void> connected) async {
    try {
      await connected.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      state = state.copyWith(
        error: 'Таймаут подключения: состояние CONNECTED не достигнуто',
      );
      return;
    }
    final changed = await _service.verifyRealTraffic();
    final after = await _service.fetchPublicIp();
    state = state.copyWith(ipAfter: after);
    if (changed == false) {
      state = state.copyWith(
        error: 'Handshake прошёл, но IP не изменился — метод отклонён',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await _service.stop();
    } finally {
      state = state.copyWith(state: TunnelState.disconnected);
    }
  }
}

final vpnControllerProvider =
    NotifierProvider<VpnController, VpnUiState>(VpnController.new);
