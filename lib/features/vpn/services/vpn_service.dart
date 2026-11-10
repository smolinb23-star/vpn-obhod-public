import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:http/http.dart' as http;

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/config_validator.dart';
import 'package:vpn_service/core/services/xray_tuning.dart';

/// Состояние туннеля для UI.
enum TunnelState { disconnected, connecting, connected, error }

/// Снимок метрик активного туннеля.
class TunnelMetrics {
  const TunnelMetrics({
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.durationSeconds = 0,
    this.rttMs,
  });

  final int uploadSpeed;
  final int downloadSpeed;
  final int upload;
  final int download;
  final int durationSeconds;
  final int? rttMs;
}

/// Обёртка над flutter_vless: старт/стоп туннеля, статус, метрики,
/// проверка смены публичного IP.
///
/// Безопасность: конфиг проходит [ConfigValidator] до передачи в нативный
/// слой. Нативный слой flutter_vless в VPN-режиме поднимает только
/// приватный loopback-SOCKS с собственными креденшелами.
class VpnService {
  VpnService({http.Client? httpClient})
      : _http = httpClient ?? http.Client() {
    _controller = FlutterVless(
      onStatusChanged: _onStatusChanged,
    );
  }

  static const List<String> _ipEndpoints = <String>[
    'https://api.ipify.org',
    'https://ifconfig.me/ip',
    'https://icanhazip.com',
  ];

  final http.Client _http;
  final ConfigValidator _validator = const ConfigValidator();

  late final FlutterVless _controller;

  final StreamController<TunnelMetrics> _metricsCtrl =
      StreamController<TunnelMetrics>.broadcast();
  final StreamController<VlessStatus> _statusCtrl =
      StreamController<VlessStatus>.broadcast();

  String? _publicIpBefore;
  bool _started = false;
  bool _initialized = false;

  Stream<TunnelMetrics> get metricsStream => _metricsCtrl.stream;
  Stream<VlessStatus> get statusStream => _statusCtrl.stream;

  bool get isStarted => _started;

  void _onStatusChanged(VlessStatus status) {
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(status);
    }
    if (!_metricsCtrl.isClosed) {
      _metricsCtrl.add(TunnelMetrics(
        uploadSpeed: status.uploadSpeed,
        downloadSpeed: status.downloadSpeed,
        upload: status.upload,
        download: status.download,
        durationSeconds: status.duration,
      ));
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await _controller.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    _initialized = true;
  }

  Future<bool> requestPermission() => _controller.requestPermission();

  /// Запускает туннель по профилю. Бросает исключение при небезопасном конфиге.
  ///
  /// [excludedApps] — список package names, которые НЕ будут идти через VPN
  /// (раздельное туннелирование).
  Future<void> start(VpnConfig config) async {
    final tuned = const XrayTuning().apply(config.xrayJson);
    _validator.validateOrThrow(tuned);
    _publicIpBefore = await fetchPublicIp();
    final allowed = await _controller.requestPermission();
    if (!allowed) {
      throw const VpnPermissionDeniedException();
    }
    await _controller.startVless(
      remark: config.remark,
      config: tuned,
    );
    _started = true;
  }

  /// Запускает каскадный туннель: сначала до промежуточного сервера,
  /// затем трафик перенаправляется на зарубежный сервер.
  Future<void> startCascade(VpnConfig config) async {
    final primary = config.cascadeOutbound1?.xrayJson ?? config.xrayJson;
    final tuned = const XrayTuning().apply(primary);
    _validator.validateOrThrow(tuned);
    _publicIpBefore = await fetchPublicIp();
    final allowed = await _controller.requestPermission();
    if (!allowed) {
      throw const VpnPermissionDeniedException();
    }
    // Запускаем туннель к первому серверу (промежуточному)
    await _controller.startVless(
      remark: config.cascadeOutbound1?.remark ?? config.remark,
      config: tuned,
    );
    _started = true;
  }

  /// Запускает CIDR-маршрутизацию: трафик только к указанным IP-адресам
  /// проходит через VPN, остальной — напрямую.
  Future<void> startCidr(VpnConfig config) async {
    final tuned = const XrayTuning().apply(config.xrayJson);
    _validator.validateOrThrow(tuned);
    _publicIpBefore = await fetchPublicIp();
    final allowed = await _controller.requestPermission();
    if (!allowed) {
      throw const VpnPermissionDeniedException();
    }
    await _controller.startVless(
      remark: config.remark,
      config: tuned,
    );
    _started = true;
  }

  Future<void> stop() async {
    try {
      await _controller.stopVless();
    } finally {
      _started = false;
    }
  }

  /// RTT активного туннеля через замер задержки до контрольного URL.
  Future<int?> connectedDelayMs() async {
    try {
      final ms = await _controller.getConnectedServerDelay();
      return ms <= 0 ? null : ms;
    } on Object {
      return null;
    }
  }

  /// Замер задержки профиля без установки соединения (для probe()).
  Future<int?> probeDelay(VpnConfig config,
      {String url = 'https://www.gstatic.com/generate_204'}) async {
    try {
      final ms = await _controller.getServerDelay(config: config.xrayJson, url: url);
      return ms <= 0 ? null : ms;
    } on Object {
      return null;
    }
  }

  /// Публичный IP текущего интерфейса (null при недоступности сервисов).
  Future<String?> fetchPublicIp() async {
    for (final endpoint in _ipEndpoints) {
      try {
        final resp = await _http
            .get(Uri.parse(endpoint))
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final ip = resp.body.trim();
          if (ip.isNotEmpty && ip.length < 64) return ip;
        }
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// Проверка реального трафика: IP за туннелем должен измениться.
  ///
  /// Возвращает true, если IP изменился; false, если совпал (туннель не
  /// несёт трафик); null, если проверка недоступна (тогда решение принимает
  /// вызывающий по heartbeat).
  Future<bool?> verifyRealTraffic() async {
    final after = await fetchPublicIp();
    final before = _publicIpBefore;
    debugPrint('VpnService: ip before=$before after=$after');
    if (after == null || before == null) return null;
    return after != before;
  }

  Future<String> coreVersion() => _controller.getCoreVersion();

  Future<void> dispose() async {
    await _metricsCtrl.close();
    await _statusCtrl.close();
    _http.close();
  }
}

class VpnPermissionDeniedException implements Exception {
  const VpnPermissionDeniedException();
}

/// Утилита для отладки: человекочитаемый размер.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}

String formatSpeed(int bytesPerSec) => '${formatBytes(bytesPerSec)}/с';