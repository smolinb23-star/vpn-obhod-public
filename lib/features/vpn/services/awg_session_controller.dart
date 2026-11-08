import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/features/bypass/bypass_method.dart';
import 'package:vpn_service/features/bypass/bypass_providers.dart';
import 'package:vpn_service/features/vpn/services/awg_connect_plan.dart';
import 'package:vpn_service/features/vpn/services/awg_native_service.dart';
import 'package:vpn_service/features/vpn/services/health_monitor.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Фаза нативного AWG-туннеля.
enum AwgPhase { idle, connecting, up, error }

/// Состояние экрана/панели AmneziaWG.
@immutable
class AwgSessionState {
  const AwgSessionState({
    this.phase = AwgPhase.idle,
    this.status = AwgStatus.down,
    this.configName,
    this.publicIp,
    this.ipBefore,
    this.error,
    this.mtu = AwgConnectPlan.defaultMtu,
    this.forceDefaultDns = false,
    this.rxSpeed = 0,
    this.txSpeed = 0,
    this.health = TunnelHealth.unknown,
    this.rttMs,
    this.lossRatio,
    this.notes = const [],
    this.reconnectAttempts = 0,
    this.lastHandshakeMs,
  });

  final AwgPhase phase;
  final AwgStatus status;
  final String? configName;
  final String? publicIp;

  /// Публичный IP до подключения (чтобы видеть смену).
  final String? ipBefore;
  final String? error;
  final int mtu;
  final bool forceDefaultDns;
  final int rxSpeed;
  final int txSpeed;
  final TunnelHealth health;
  final int? rttMs;
  final double? lossRatio;
  final List<String> notes;
  final int reconnectAttempts;
  final int? lastHandshakeMs;

  bool get up => phase == AwgPhase.up && status.up;
  bool get connecting => phase == AwgPhase.connecting;

  AwgSessionState copyWith({
    AwgPhase? phase,
    AwgStatus? status,
    String? configName,
    String? publicIp,
    bool clearPublicIp = false,
    String? ipBefore,
    String? error,
    bool clearError = false,
    int? mtu,
    bool? forceDefaultDns,
    int? rxSpeed,
    int? txSpeed,
    TunnelHealth? health,
    int? rttMs,
    double? lossRatio,
    List<String>? notes,
    int? reconnectAttempts,
    int? lastHandshakeMs,
  }) =>
      AwgSessionState(
        phase: phase ?? this.phase,
        status: status ?? this.status,
        configName: configName ?? this.configName,
        publicIp: clearPublicIp ? null : (publicIp ?? this.publicIp),
        ipBefore: ipBefore ?? this.ipBefore,
        error: clearError ? null : (error ?? this.error),
        mtu: mtu ?? this.mtu,
        forceDefaultDns: forceDefaultDns ?? this.forceDefaultDns,
        rxSpeed: rxSpeed ?? this.rxSpeed,
        txSpeed: txSpeed ?? this.txSpeed,
        health: health ?? this.health,
        rttMs: rttMs ?? this.rttMs,
        lossRatio: lossRatio ?? this.lossRatio,
        notes: notes ?? this.notes,
        reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
        lastHandshakeMs: lastHandshakeMs ?? this.lastHandshakeMs,
      );
}

final awgSessionProvider =
    NotifierProvider<AwgSessionController, AwgSessionState>(
        AwgSessionController.new);

/// Управление нативным AmneziaWG: подключение, счётчики rx/tx, проверка IP,
/// health-цикл 15 с, авто-реконнект и foreground keep-alive.
class AwgSessionController extends Notifier<AwgSessionState> {
  static const String _lastConfKey = 'last_awg_conf';
  static const String _mtuKey = 'awg_mtu';
  static const String _dnsKey = 'awg_force_dns';
  static const String _ipEndpoint = 'https://api.ipify.org';

  static const int maxReconnectAttempts = 3;

  AwgNativeService get _awg => ref.read(awgNativeServiceProvider);
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);
  PlatformBridge get _platform => ref.read(platformBridgeProvider);

  final http.Client _http = http.Client();
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  Timer? _pollTimer;
  Timer? _reconnectTimer;
  HealthMonitor? _health;
  WireGuardConfig? _lastConfig;
  bool _manualDisconnect = false;
  bool _reconnectScheduled = false;
  bool _connecting = false;
  int _lastRx = 0;
  int _lastTx = 0;
  DateTime _lastPollAt = DateTime.now();
  bool _winRecorded = false;

  @override
  AwgSessionState build() {
    final statusSub = _awg.statusStream.listen(_onNativeStatus);
    _subs.add(statusSub);
    ref.onDispose(() {
      _pollTimer?.cancel();
      _reconnectTimer?.cancel();
      _health?.dispose();
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _http.close();
    });
    unawaited(_restoreSettings());
    return const AwgSessionState();
  }

  // --- Публичные действия ---

  /// Подключает нативный AmneziaWG. Ошибки попадают в state.error и в лог.
  Future<void> connect(WireGuardConfig cfg, {bool isReconnect = false}) async {
    if (_connecting) return;
    _connecting = true;
    _manualDisconnect = false;
    _winRecorded = false;
    _reconnectScheduled = false;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _pollTimer = null;
    _health?.stop();
    state = state.copyWith(
      phase: AwgPhase.connecting,
      configName: cfg.name,
      clearError: true,
      notes: const [],
      reconnectAttempts: isReconnect ? state.reconnectAttempts : 0,
    );
    appLog.info('AwgSession', 'connect: ${cfg.name}');
    _lastConfig = cfg;

    try {
      // Исходный IP — до поднятия туннеля.
      if (state.ipBefore == null) {
        final before = await checkIp();
        if (before != null) {
          state = state.copyWith(ipBefore: before);
        }
      }

      final prepared = await _awg.prepare();
      if (!prepared) {
        _fail('Разрешение VPN не предоставлено — подтвердите диалог Android '
            '«Установить VPN-подключение?»');
        return;
      }

      final plan = await AwgConnectPlan.create(
        cfg,
        mtu: state.mtu,
        forceDefaultDns: state.forceDefaultDns,
      );
      state = state.copyWith(notes: plan.notes);

      final status = await _awg.connectPlan(plan);
      if (!status.up) {
        _fail('Нативный слой вернул состояние down '
            '${status.error ?? ''}'.trim());
        return;
      }

      _lastConfig = plan.config;
      await _persistLastConfig(plan.config);
      state = state.copyWith(
        phase: AwgPhase.up,
        status: status,
        lastHandshakeMs: status.lastHandshakeMs,
        clearError: true,
      );
      _startPolling();
      _startHealth();
      await _platform.startKeepAlive();

      // Проверка смены IP после handshake (не блокирует UI).
      unawaited(_verifyIpAfterConnect());
    } on Object catch (e, st) {
      appLog.error('AwgSession', 'connect failed', e);
      debugPrint('$st');
      _fail('Подключение не удалось: $e');
      await _platform.stopKeepAlive();
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectScheduled = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _health?.stop();
    await _awg.disconnect();
    await _platform.stopKeepAlive();
    state = state.copyWith(
      phase: AwgPhase.idle,
      status: AwgStatus.down,
      rxSpeed: 0,
      txSpeed: 0,
      health: TunnelHealth.unknown,
      reconnectAttempts: 0,
      clearError: true,
    );
  }

  /// Проверяет публичный IP (api.ipify.org). Возвращает null при недоступности.
  Future<String?> checkIp() async {
    try {
      final resp = await _http
          .get(Uri.parse(_ipEndpoint))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        appLog.warn('AwgSession', 'checkIp: HTTP ${resp.statusCode}');
        return null;
      }
      final ip = resp.body.trim();
      if (ip.isEmpty || ip.length > 64) return null;
      appLog.info('AwgSession', 'публичный IP: $ip');
      state = state.copyWith(publicIp: ip);
      return ip;
    } on Object catch (e) {
      appLog.warn('AwgSession', 'checkIp: $e');
      return null;
    }
  }

  Future<void> setMtu(int mtu) async {
    state = state.copyWith(mtu: mtu);
    appLog.info('AwgSession', 'MTU → $mtu');
    await _writeSetting(_mtuKey, '$mtu');
  }

  Future<void> setForceDefaultDns(bool value) async {
    state = state.copyWith(forceDefaultDns: value);
    appLog.info('AwgSession', 'forceDefaultDns → $value');
    await _writeSetting(_dnsKey, '$value');
  }

  Future<WireGuardConfig?> restoreLastConfig() async {
    if (_lastConfig != null) return _lastConfig;
    try {
      final raw = await _storage.read(key: _lastConfKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final cfg = WireGuardConfig.fromJson(decoded);
        _lastConfig = cfg;
        return cfg;
      }
    } on Object catch (e) {
      appLog.warn('AwgSession', 'restoreLastConfig: $e');
    }
    return null;
  }

  // --- Внутреннее ---

  void _fail(String message) {
    appLog.error('AwgSession', message);
    state = state.copyWith(phase: AwgPhase.error, error: message);
  }

  void _onNativeStatus(AwgStatus status) {
    final wasUp = state.up;
    state = state.copyWith(
      status: status,
      lastHandshakeMs: status.lastHandshakeMs ?? state.lastHandshakeMs,
      phase: status.up
          ? AwgPhase.up
          : (wasUp ? AwgPhase.error : state.phase),
    );
    if (!status.up && wasUp && !_manualDisconnect) {
      appLog.warn('AwgSession', 'туннель неожиданно упал — авто-реконнект');
      _scheduleReconnect();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _lastRx = state.status.rx;
    _lastTx = state.status.tx;
    _lastPollAt = DateTime.now();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final status = await _awg.getStatus();
    final now = DateTime.now();
    final seconds = now.difference(_lastPollAt).inMilliseconds / 1000.0;
    var rxSpeed = 0;
    var txSpeed = 0;
    if (seconds > 0) {
      rxSpeed = ((status.rx - _lastRx) / seconds).round();
      txSpeed = ((status.tx - _lastTx) / seconds).round();
    }
    _lastRx = status.rx;
    _lastTx = status.tx;
    _lastPollAt = now;

    final wasUp = state.up;
    state = state.copyWith(
      status: status,
      rxSpeed: rxSpeed < 0 ? 0 : rxSpeed,
      txSpeed: txSpeed < 0 ? 0 : txSpeed,
      lastHandshakeMs: status.lastHandshakeMs ?? state.lastHandshakeMs,
      phase: status.up
          ? AwgPhase.up
          : (wasUp && !_manualDisconnect ? AwgPhase.error : state.phase),
    );

    if (!status.up && wasUp && !_manualDisconnect) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _scheduleReconnect();
    }
  }

  void _startHealth() {
    _health?.dispose();
    final monitor = HealthMonitor(sampler: _sampleHealth);
    _health = monitor;
    _subs.add(monitor.stream.listen((sample) {
      state = state.copyWith(
        health: sample.state,
        rttMs: sample.rttMs,
        lossRatio: sample.lossRatio,
      );
      if (sample.state == TunnelHealth.dead && !_manualDisconnect) {
        appLog.warn('AwgSession', 'health: DEAD → авто-реконнект');
        _scheduleReconnect();
      }
    }));
    monitor.start();
  }

  /// 4 параллельных запроса через туннель: RTT + доля потерь.
  Future<MethodHealth> _sampleHealth() async {
    const probes = 4;
    var ok = 0;
    var totalRtt = 0;
    final results = await Future.wait(
      List<Future<int?>>.generate(probes, (_) async {
        final sw = Stopwatch()..start();
        try {
          final resp = await _http
              .head(Uri.parse('https://www.gstatic.com/generate_204'))
              .timeout(const Duration(seconds: 4));
          sw.stop();
          if (resp.statusCode == 204 || resp.statusCode == 200) {
            return sw.elapsedMilliseconds;
          }
          return null;
        } on Object {
          return null;
        }
      }),
    );
    for (final rtt in results) {
      if (rtt != null) {
        ok++;
        totalRtt += rtt;
      }
    }
    final loss = (probes - ok) / probes;
    return MethodHealth(
      alive: ok > 0,
      rttMs: ok == 0 ? 0 : totalRtt ~/ ok,
      lossRatio: loss,
    );
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _reconnectScheduled) return;
    final attempts = state.reconnectAttempts;
    if (attempts >= maxReconnectAttempts) {
      appLog.error('AwgSession', 'авто-реконнект: лимит $attempts попыток');
      _fail('Туннель упал, авто-реконнект исчерпал $attempts попыток');
      return;
    }
    _reconnectScheduled = true;
    final delay = Duration(seconds: 3 * (attempts + 1));
    appLog.info('AwgSession', 'авто-реконнект через ${delay.inSeconds} с '
        '(попытка ${attempts + 1}/$maxReconnectAttempts)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      _reconnectScheduled = false;
      final cfg = _lastConfig ?? await restoreLastConfig();
      if (cfg == null) {
        _fail('Авто-реконнект: нет сохранённого .conf');
        return;
      }
      state = state.copyWith(
        reconnectAttempts: attempts + 1,
        clearError: true,
      );
      await connect(cfg, isReconnect: true);
    });
  }

  Future<void> _verifyIpAfterConnect() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!state.up) return;
    final after = await checkIp();
    if (after == null) return;
    final before = state.ipBefore;
    if (before != null && after != before) {
      appLog.info('AwgSession', 'IP изменился: $before → $after');
      await _recordWin();
    } else if (before != null) {
      appLog.warn('AwgSession', 'IP не изменился ($after) — трафик может не '
          'идти через туннель');
    }
  }

  Future<void> _recordWin() async {
    if (_winRecorded) return;
    _winRecorded = true;
    try {
      final info = await _platform.networkInfo();
      final key = NetworkKey.build(info);
      await ref
          .read(winsRepositoryProvider)
          .recordWin('amneziawg', key);
      appLog.info('AwgSession', 'победа amneziawg записана для сети $key');
    } on Object catch (e) {
      appLog.warn('AwgSession', 'recordWin: $e');
    }
  }

  Future<void> _restoreSettings() async {
    try {
      final mtuRaw = await _storage.read(key: _mtuKey);
      final dnsRaw = await _storage.read(key: _dnsKey);
      final mtu = int.tryParse(mtuRaw ?? '');
      final cfg = await restoreLastConfig();
      state = state.copyWith(
        mtu: (mtu == 1280 || mtu == 1380 || mtu == 1420)
            ? mtu
            : AwgConnectPlan.defaultMtu,
        forceDefaultDns: dnsRaw == 'true',
        configName: cfg?.name,
      );
    } on Object catch (e) {
      appLog.warn('AwgSession', 'restoreSettings: $e');
    }
  }

  Future<void> _persistLastConfig(WireGuardConfig cfg) async {
    try {
      await _storage.write(key: _lastConfKey, value: jsonEncode(cfg.toJson()));
    } on Object catch (e) {
      appLog.warn('AwgSession', 'persistLastConfig: $e');
    }
  }

  Future<void> _writeSetting(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on Object catch (e) {
      appLog.warn('AwgSession', 'writeSetting $key: $e');
    }
  }
}
