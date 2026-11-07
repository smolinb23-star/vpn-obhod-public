import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/models/wireguard_config.dart';

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
  const AwgStatus({required this.up, this.rx = 0, this.tx = 0, this.version});

  final bool up;
  final int rx;
  final int tx;
  final String? version;

  static const AwgStatus down = AwgStatus(up: false);

  factory AwgStatus.fromMap(Map<Object?, Object?> m) => AwgStatus(
        up: m['state'] == 'up',
        rx: (m['rx'] as num?)?.toInt() ?? 0,
        tx: (m['tx'] as num?)?.toInt() ?? 0,
        version: m['version'] as String?,
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
    if (call.method == 'onStatus' && call.arguments is Map) {
      _statusCtrl.add(
          AwgStatus.fromMap(Map<Object?, Object?>.from(call.arguments as Map)));
    }
  }

  /// Разрешение VPN-туннеля (android VpnService.prepare). true — можноconnect.
  Future<bool> prepare() async {
    try {
      final ok = await _channel.invokeMethod<bool>('prepare');
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('AwgNativeService.prepare: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Поднимает туннель по разобранному .conf (полная обфускация AWG).
  Future<AwgStatus> connect(WireGuardConfig cfg) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'connect',
      _payloadFor(cfg),
    );
    if (result == null) return const AwgStatus(up: true);
    return AwgStatus.fromMap(result);
  }

  Future<AwgStatus> disconnect() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'disconnect');
    if (result == null) return AwgStatus.down;
    return AwgStatus.fromMap(result);
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
