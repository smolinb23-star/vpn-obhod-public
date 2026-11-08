import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';

/// Формирует `logs.txt` из Dart-лога и logcat (AwgBridge + AmneziaWG)
/// и отдаёт его в share sheet.
class LogExportService {
  LogExportService({PlatformBridge? platform})
      : _platform = platform ?? PlatformBridge();

  final PlatformBridge _platform;

  static const int maxLines = 500;

  Future<File> buildLogFile() async {
    final native = await _platform.dumpLogcat(lines: maxLines);
    final dartLines = appLog.tail(maxLines);

    final buffer = StringBuffer()
      ..writeln('VPN Obhod — диагностический лог')
      ..writeln('Время: ${DateTime.now().toIso8601String()}')
      ..writeln('Устройство: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Dart-строк: ${dartLines.length}')
      ..writeln('=' * 60)
      ..writeln('--- Dart / парсер / AmneziaWG bridge ---');

    // Суммарно не больше maxLines: приоритет у свежих нативных строк,
    // Dart-лог обрезаем при необходимости.
    final nativeLines = native
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList(growable: false);
    final dartBudget = nativeLines.isEmpty
        ? maxLines
        : (maxLines - nativeLines.length).clamp(0, maxLines).toInt();
    final dartTail = dartLines.length > dartBudget
        ? dartLines.sublist(dartLines.length - dartBudget)
        : dartLines;
    for (final line in dartTail) {
      buffer.writeln(line);
    }

    if (nativeLines.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('--- Android logcat (процесс приложения) ---');
      for (final line in nativeLines) {
        buffer.writeln(line);
      }
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}logs.txt');
    await file.writeAsString(buffer.toString());
    appLog.info('LogExport', 'logs.txt: ${file.path}');
    return file;
  }

  Future<void> share() async {
    final file = await buildLogFile();
    await Share.shareXFiles(
      <XFile>[XFile(file.path, mimeType: 'text/plain')],
      subject: 'VPN Obhod logs',
      text: 'Диагностика VPN Obhod (AwgBridge + AmneziaWG + парсер)',
    );
  }
}
