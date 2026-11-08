import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Кольцевой буфер логов приложения (последние [maxLines] строк).
///
/// Используется для диагностики на устройстве без adb: парсер .conf,
/// Dart-слой AmneziaWG и нативный AwgBridge пишут сюда, а экран импорта
/// выгружает буфер + logcat в `logs.txt` через share sheet.
class AppLog {
  AppLog({this.maxLines = 500});

  final int maxLines;
  final ListQueue<String> _lines = ListQueue<String>();

  List<String> get lines => List<String>.unmodifiable(_lines);

  int get length => _lines.length;

  void add(String tag, String message) {
    final ts = DateTime.now().toIso8601String();
    final line = '$ts [$tag] $message';
    _lines.addLast(line);
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
    if (kDebugMode) {
      debugPrint(line);
    }
  }

  void info(String tag, String message) => add(tag, message);

  void warn(String tag, String message) => add(tag, 'WARN $message');

  void error(String tag, String message, [Object? error]) =>
      add(tag, 'ERROR $message${error == null ? '' : ': $error'}');

  /// Последние [limit] строк (по умолчанию весь буфер).
  List<String> tail([int? limit]) {
    final n = limit == null ? _lines.length : (limit < _lines.length ? limit : _lines.length);
    return _lines.skip(_lines.length - n).toList(growable: false);
  }

  String dump([int? limit]) => tail(limit).join('\n');

  void clear() => _lines.clear();
}

/// Глобальный лог приложения.
final AppLog appLog = AppLog();
