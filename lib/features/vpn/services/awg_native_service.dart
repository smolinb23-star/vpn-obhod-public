import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/features/vpn/services/awg_connect_plan.dart';

/// Глобальный экземпляр нативного AWG-сервиса (один MethodChannel на приложение).
final awgNativeServiceProvider = Provider<AwgNativeService>((ref) {
  final service = AwgNativeService();
  ref.onDispose(service.dispose);
  return service;
});

/// Статус нативного AmneziaWG-туннеля (стрим из AwgBridge).
final awgStatusProvider = StreamProvider<AwgStatus>((ref) {
  return ref.watch(awgNativeServiceProvider).statusStream;
});

/// Состояние нативного AmneziaWG-туннеля.
class AwgStatus {
  const AwgStatus({
    required this.up,
    this.rx = 0,
    this.tx = 0,
    this.rxPackets,
    this.txPackets,
    this.lastHandshakeMs,
    this.version,
    this.endpoint,
    this.error,
  });

  final bool up;

  /// Байты, принятые/переданные нативным GoBackend.
  final int rx;
  final int tx;

  /// Пакеты из /proc/net/dev (null — счётчик недоступен на устройстве).
  final int? rxPackets;
  final int? txPackets;

  /// Время последнего handshake (epoch ms), null — ещё не было.
  final int? lastHandshakeMs;
  final String? version;
  final String? endpoint;
  final String? error;

  static const AwgStatus down = AwgStatus(up: false);

  factory AwgStatus.fromMap(Map<Object?, Object?> m) => AwgStatus(
        up: m['state'] == 'up',
        rx: (m['rx'] as num?)?.toInt() ?? 0,
        tx: (m['tx'] as num?)?.toInt() ?? 0,
        rxPackets: (m['rxPackets'] as num?)?.toInt(),
        txPackets: (m['txPackets'] as num?)?.toInt(),
        lastHandshakeMs: (m['lastHandshake'] as num?)?.toInt(),
        version: m['version'] as String?,
        endpoint: m['endpoint'] as String?,
        error: m['error'] as String?,
      );
}

/// Клиент MethodChannel к нативному движку AmneziaWG (AwgBridge.kt).
///
/// Отличия от Xray-пути: туннель поднимает org.amnezia.awg GoBackend с
/// параметрами обфускации handshake (Jc/Jmin/Jmax, S1/S2, H1..H4) —
/// именно они дают обход DPI, который не даёт plain WireGuard.
class AwgNativeService {
  AwgNativeService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String _channelName = 'dev.local.vpnservice/awg';

  final MethodChannel _channel;
  final StreamController<AwgStatus> _statusCtrl =
      StreamController<AwgStatus>.broadcast();

  Stream<AwgStatus> get statusStream => _statusCtrl.stream;

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onStatus':
        if (call.arguments is Map) {
          _statusCtrl.add(AwgStatus.fromMap(
              Map<Object?, Object?>.from(call.arguments as Map)));
        }
        break;
      case 'onLog':
        if (call.arguments is Map) {
          final m = Map<Object?, Object?>.from(call.arguments as Map);
          appLog.info('AwgBridge', '${m['message'] ?? m}');
        }
        break;
    }
  }

  /// Разрешение VPN-туннеля (android VpnService.prepare). true — можно connect.
  Future<bool> prepare() async {
    try {
      final ok = await _channel.invokeMethod<bool>('prepare');
      appLog.info('AwgNativeService', 'prepare → $ok');
      return ok ?? false;
    } on PlatformException catch (e) {
      appLog.error('AwgNativeService', 'prepare', e);
      return false;
    } on MissingPluginException {
      appLog.error('AwgNativeService', 'prepare: нативный мост не найден');
      return false;
    }
  }

  /// Поднимает туннель по разобранному .conf (полная обфускация AWG).
  ///
  /// Перед вызовом строится [AwgConnectPlan]: резолв домена endpoint,
  /// DNS-override, MTU из UI.
  Future<AwgStatus> connect(
    WireGuardConfig cfg, {
    int mtu = AwgConnectPlan.defaultMtu,
    bool forceDefaultDns = false,
    Future<List<String>> Function(String host)? resolver,
  }) async {
    final plan = await AwgConnectPlan.create(
      cfg,
      mtu: mtu,
      forceDefaultDns: forceDefaultDns,
      resolver: resolver,
    );
    return connectPlan(plan);
  }

  /// Поднимает туннель по готовому плану (endpoint уже IP, DNS/MTU заданы).
  Future<AwgStatus> connectPlan(AwgConnectPlan plan) async {
    final payload = plan.config.toNativePayload();
    appLog.info(
      'AwgNativeService',
      'connect: ${plan.config.name} endpoint=${plan.config.endpointHost}:'
          '${plan.config.endpointPort} mtu=${plan.config.mtu} '
          'dns=${plan.config.dns.join(",")} '
          'amnezia=${plan.config.amnezia.keys.join(",")}',
    );
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'connect',
        payload,
      );
      final status =
          result == null ? const AwgStatus(up: true) : AwgStatus.fromMap(result);
      appLog.info('AwgNativeService', 'connect → up=${status.up} '
          'rx=${status.rx} tx=${status.tx}');
      return status;
    } on PlatformException catch (e) {
      appLog.error('AwgNativeService', 'connect: ${e.message}', e);
      rethrow;
    }
  }

  Future<AwgStatus> disconnect() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
          'disconnect');
      final status =
          result == null ? AwgStatus.down : AwgStatus.fromMap(result);
      appLog.info('AwgNativeService', 'disconnect → up=${status.up}');
      return status;
    } on PlatformException catch (e) {
      appLog.error('AwgNativeService', 'disconnect', e);
      return AwgStatus.down;
    }
  }

  Future<AwgStatus> getStatus() async {
    try {
      final result =
          await _channel.invokeMethod<Map<Object?, Object?>>('getStatus');
      if (result == null) return AwgStatus.down;
      return AwgStatus.fromMap(result);
    } on PlatformException {
      return AwgStatus.down;
    } on MissingPluginException {
      return AwgStatus.down;
    }
  }

  /// Payload для нативного слоя. Ключи Amnezia передаются как есть
  /// (jc/jmin/...), канонизацию имён (Jc/Jmin/...) делает Kotlin-мост.
  static Map<String, Object?> _payloadFor(WireGuardConfig cfg) =>
      cfg.toNativePayload();

  /// Для тестов: тот же payload под публичным именем.
  @visibleForTesting
  static Map<String, Object?> payloadFor(WireGuardConfig cfg) =>
      _payloadFor(cfg);

  void dispose() {
    _channel.setMethodCallHandler(null);
    _statusCtrl.close();
  }
}
