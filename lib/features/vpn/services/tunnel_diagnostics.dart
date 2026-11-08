import 'dart:io';

import 'package:http/http.dart' as http;

/// Результат ICMP/TCP-проверки.
class PingResult {
  const PingResult({
    required this.ok,
    this.rttMs,
    this.output = '',
    this.error,
    this.tcpFallback = false,
  });

  final bool ok;
  final int? rttMs;
  final String output;
  final String? error;

  /// true — ICMP не прошёл, но TCP :443 доступен (часто ICMP фильтруют).
  final bool tcpFallback;
}

/// Результат HTTP-запроса внутри туннеля.
class HttpProbeResult {
  const HttpProbeResult({
    required this.ok,
    required this.elapsedMs,
    this.statusCode,
    this.body,
    this.error,
  });

  final bool ok;
  final int elapsedMs;
  final int? statusCode;
  final String? body;
  final String? error;
}

/// Проверки, которые выполняются с устройства уже внутри VPN-туннеля.
class TunnelDiagnostics {
  const TunnelDiagnostics._();

  /// ping с fallback на TCP :443: на Android ICMP часто фильтруется.
  static Future<PingResult> ping(
    String host, {
    int count = 3,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final buffer = StringBuffer();
    try {
      final args = Platform.isWindows
          ? <String>['-n', '$count', '-w', '2000', host]
          : <String>['-c', '$count', '-W', '2', host];
      final proc = await Process.run('ping', args).timeout(timeout);
      final stdout = proc.stdout.toString();
      final stderr = proc.stderr.toString();
      buffer.write(stdout);
      if (stderr.trim().isNotEmpty) buffer.write('\n$stderr');
      if (proc.exitCode == 0) {
        return PingResult(
          ok: true,
          rttMs: parsePingRttMs(stdout),
          output: buffer.toString().trim(),
        );
      }
    } on Object catch (e) {
      buffer.writeln('ping: $e');
    }

    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, 443, timeout: timeout);
      sw.stop();
      socket.destroy();
      final prefix = buffer.toString().trim();
      return PingResult(
        ok: true,
        rttMs: sw.elapsedMilliseconds,
        tcpFallback: true,
        output: <String>[
          if (prefix.isNotEmpty) prefix,
          'TCP $host:443 OK за ${sw.elapsedMilliseconds} мс '
              '(ICMP недоступен — это нормально)',
        ].join('\n'),
      );
    } on Object catch (e) {
      sw.stop();
      return PingResult(
        ok: false,
        output: buffer.toString().trim(),
        error: 'ping и TCP $host:443 не прошли: $e',
      );
    }
  }

  /// HTTP GET внутри туннеля (по умолчанию — api.ipify.org).
  static Future<HttpProbeResult> httpGet(
    String url, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    final client = http.Client();
    try {
      final resp = await client.get(Uri.parse(url)).timeout(timeout);
      sw.stop();
      final body = resp.body.trim();
      return HttpProbeResult(
        ok: resp.statusCode >= 200 && resp.statusCode < 400,
        statusCode: resp.statusCode,
        body: body.length > 500 ? body.substring(0, 500) : body,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } on Object catch (e) {
      sw.stop();
      return HttpProbeResult(
        ok: false,
        elapsedMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    } finally {
      client.close();
    }
  }

  /// Извлекает средний RTT из вывода ping (Linux/Android/Windows).
  static int? parsePingRttMs(String output) {
    // Linux/Android: rtt min/avg/max/mdev = 8.1/8.2/8.3/0.1 ms
    final unix = RegExp(r'=\s*[\d.]+/([\d.]+)/').firstMatch(output);
    if (unix != null) {
      return double.tryParse(unix.group(1)!)?.round();
    }
    // Windows: Average = 10ms / Среднее = 10мс
    final win =
        RegExp(r'(?:Average|Среднее)\s*=\s*(\d+)', caseSensitive: false)
            .firstMatch(output);
    if (win != null) return int.tryParse(win.group(1)!);
    // Отдельная строка: time=10.2 ms
    final time = RegExp(r'time[=<]([\d.]+)\s*ms', caseSensitive: false)
        .firstMatch(output);
    if (time != null) return double.tryParse(time.group(1)!)?.round();
    return null;
  }
}
