import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/services/app_log.dart';

/// Платформенный мост как провайдер (переопределяется в тестах).
final platformBridgeProvider =
    Provider<PlatformBridge>((ref) => PlatformBridge());

/// Сетевая информация устройства для network_key памяти побед.
class NetworkInfo {
  const NetworkInfo({this.ssid, this.operatorName, this.mccMnc, this.type});

  final String? ssid;
  final String? operatorName;
  final String? mccMnc;

  /// wifi / mobile / none.
  final String? type;

  static const NetworkInfo unknown = NetworkInfo();

  factory NetworkInfo.fromMap(Map<Object?, Object?> m) => NetworkInfo(
        ssid: m['ssid'] as String?,
        operatorName: m['operator'] as String?,
        mccMnc: m['mccMnc'] as String?,
        type: m['type'] as String?,
      );
}

/// Результат попытки форсировать LTE.
class LteResult {
  const LteResult({
    required this.ok,
    required this.message,
    this.needsPermission = false,
  });

  final bool ok;
  final String message;
  final bool needsPermission;

  factory LteResult.fromMap(Map<Object?, Object?> m) => LteResult(
        ok: m['ok'] == true,
        message: m['message']?.toString() ?? '',
        needsPermission: m['needsPermission'] == true,
      );
}

/// Мост к платформенным возможностям Android (не VPN-ядро):
/// сетевой ключ, форсирование LTE, foreground-сервис, dump logcat.
class PlatformBridge {
  PlatformBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'dev.local.vpnservice/platform';

  final MethodChannel _channel;

  Future<NetworkInfo> networkInfo() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
          'getNetworkInfo');
      if (map == null) return NetworkInfo.unknown;
      return NetworkInfo.fromMap(map);
    } on PlatformException catch (e) {
      appLog.warn('PlatformBridge', 'getNetworkInfo: ${e.message}');
      return NetworkInfo.unknown;
    } on MissingPluginException {
      return NetworkInfo.unknown;
    }
  }

  /// preferred_network_mode = 11 (LTE only) через WRITE_SECURE_SETTINGS.
  Future<LteResult> forceLte() async {
    try {
      final map =
          await _channel.invokeMethod<Map<Object?, Object?>>('forceLte');
      if (map == null) {
        return const LteResult(ok: false, message: 'Нет ответа от Android');
      }
      final result = LteResult.fromMap(map);
      appLog.info('PlatformBridge', 'forceLte → ${result.ok}: ${result.message}');
      return result;
    } on PlatformException catch (e) {
      appLog.error('PlatformBridge', 'forceLte', e);
      return LteResult(ok: false, message: e.message ?? '$e');
    } on MissingPluginException {
      return const LteResult(ok: false, message: 'Платформенный мост недоступен');
    }
  }

  /// Постоянное уведомление + START_STICKY: процесс не убивается в фоне.
  Future<void> startKeepAlive() async {
    try {
      await _channel.invokeMethod<void>('startKeepAlive');
      appLog.info('PlatformBridge', 'foreground keep-alive запущен');
    } on PlatformException catch (e) {
      appLog.error('PlatformBridge', 'startKeepAlive', e);
    } on MissingPluginException {
      // не Android/тесты
    }
  }

  Future<void> stopKeepAlive() async {
    try {
      await _channel.invokeMethod<void>('stopKeepAlive');
      appLog.info('PlatformBridge', 'foreground keep-alive остановлен');
    } on PlatformException catch (e) {
      appLog.error('PlatformBridge', 'stopKeepAlive', e);
    } on MissingPluginException {
      // не Android/тесты
    }
  }

  /// Последние строки logcat (только своего процесса, если возможно).
  Future<String> dumpLogcat({int lines = 500}) async {
    try {
      final text = await _channel.invokeMethod<String>(
        'dumpLogcat',
        <String, Object?>{'lines': lines},
      );
      return text ?? '';
    } on PlatformException catch (e) {
      debugPrint('PlatformBridge.dumpLogcat: ${e.message}');
      return '';
    } on MissingPluginException {
      return '';
    }
  }
}

/// Чистая логика network_key: SSID Wi-Fi или operator|mccmnc.
class NetworkKey {
  const NetworkKey._();

  static const String unknown = 'unknown';

  static String build(NetworkInfo info) {
    final ssid = info.ssid?.trim();
    if (ssid != null &&
        ssid.isNotEmpty &&
        ssid != '<unknown ssid>' &&
        ssid != 'unknown' &&
        ssid != '0x') {
      return ssid;
    }
    final operatorName = info.operatorName?.trim();
    final mccMnc = info.mccMnc?.trim();
    if ((operatorName != null && operatorName.isNotEmpty) ||
        (mccMnc != null && mccMnc.isNotEmpty)) {
      return '${operatorName ?? 'operator'}|${mccMnc ?? 'unknown'}';
    }
    return unknown;
  }
}
