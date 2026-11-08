import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Модель приложения, полученная с нативной стороны через MethodChannel.
class InstalledApp {
  const InstalledApp({
    required this.name,
    required this.packageName,
    this.iconBase64,
  });

  final String name;
  final String packageName;
  final String? iconBase64;

  /// Декодированные байты иконки (PNG), если есть.
  Uint8List? get iconBytes {
    if (iconBase64 == null || iconBase64!.isEmpty) return null;
    try {
      return base64Decode(iconBase64!);
    } on FormatException {
      return null;
    }
  }

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
        name: json['name'] as String? ?? '',
        packageName: json['package'] as String? ?? '',
        iconBase64: json['icon'] as String?,
      );
}

/// Flutter-сторона MethodChannel для получения списка установленных приложений.
///
/// Канал: `dev.local.vpnservice/platform`, метод `getInstalledApps`.
/// Реализация на Kotlin: PlatformBridge.getInstalledApps() через PackageManager.
class AppListService {
  AppListService._();

  static final AppListService _instance = AppListService._();

  factory AppListService() => _instance;

  final MethodChannel _channel = const MethodChannel(
    'dev.local.vpnservice/platform',
  );

  /// Возвращает список установленных приложений (имя, пакет, base64-иконка).
  Future<List<InstalledApp>> getInstalledApps() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      final list = result ?? <dynamic>[];
      return list.cast<Map<dynamic, dynamic>>().map((e) {
        final map = e.cast<String, dynamic>();
        return InstalledApp.fromJson(map);
      }).toList(growable: false);
    } on PlatformException catch (e) {
      // Метод не реализован на нативной стороне — возвращаем пустой список.
      if (e.code == 'notImplemented') return <InstalledApp>[];
      rethrow;
    }
  }
}

/// Провайдер AppListService.
final appListServiceProvider = Provider<AppListService>((ref) {
  return AppListService();
});
