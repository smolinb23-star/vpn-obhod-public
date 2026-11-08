import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Результат попытки подключения через один метод.
class ConnectAttemptResult {
  const ConnectAttemptResult({
    required this.success,
    this.methodName,
    this.error,
    this.publicIp,
  });

  final bool success;
  final String? methodName;
  final String? error;
  final String? publicIp;
}

/// Кандидат для подключения.
class ConnectionCandidate {
  const ConnectionCandidate({
    required this.id,
    required this.name,
    required this.type,
    this.awgConfig,
    this.vlessConfig,
  });

  final String id;
  final String name;
  final ConnectionMethodType type;

  final WireGuardConfig? awgConfig;
  final VpnConfig? vlessConfig;
}

/// Тип метода подключения.
enum ConnectionMethodType { amneziawg, vless }

/// Оркестратор автоматического подключения.
///
/// Последовательно пробует методы с жёстким таймаутом на каждый.
/// Метод считается успешным только если HTTP-запрос на api.ipify.org
/// проходит быстрее 3 секунд и публичный IP изменился.
class ConnectionOrchestrator {
  ConnectionOrchestrator({
    required this.ref,
    required this.isMobile,
  });

  final Ref ref;
  final bool isMobile;

  AwgSessionController get _awg => ref.read(awgSessionProvider.notifier);
  VpnController get _vpn => ref.read(vpnControllerProvider.notifier);
  PlatformBridge get _platform => ref.read(platformBridgeProvider);

  static const Duration _methodTimeout = Duration(seconds: 5);
  static const Duration _ipCheckTimeout = Duration(seconds: 3);
  static const String _ipCheckUrl = 'https://api.ipify.org';

  /// IP до подключения (запоминается перед началом перебора).
  String? _ipBefore;

  /// Сохранённые конфиги в flutter_secure_storage:
  //  - 'saved_configs' — JSON Map: id -> {type, name, data}

  /// Список кандидатов для подключения в порядке приоритета.
  Future<List<ConnectionCandidate>> _buildCandidates() async {
    final all = await _getAllSavedConfigsMap();
    final awgConfigs = <ConnectionCandidate>[];
    final vlessConfigs = <ConnectionCandidate>[];

    all.forEach((id, value) {
      if (value is! Map) return;
      final typeIndex = value['type'] as int? ?? 0;
      final type = typeIndex == 0
          ? ConnectionMethodType.amneziawg
          : ConnectionMethodType.vless;
      final name = value['name'] as String? ?? id;
      final data = value['data'] as Map? ?? {};

      if (type == ConnectionMethodType.amneziawg) {
        try {
          awgConfigs.add(ConnectionCandidate(
            id: id,
            name: name,
            type: type,
            awgConfig: WireGuardConfig.fromJson(
                Map<String, dynamic>.from(data)),
          ));
        } on Object {
          // ignore malformed
        }
      } else {
        try {
          vlessConfigs.add(ConnectionCandidate(
            id: id,
            name: name,
            type: type,
            vlessConfig: VpnConfig.fromJson(
                Map<String, dynamic>.from(data)),
          ));
        } on Object {
          // ignore malformed
        }
      }
    });

    final result = <ConnectionCandidate>[];
    if (isMobile) {
      result.addAll(vlessConfigs);
      result.addAll(awgConfigs);
    } else {
      result.addAll(awgConfigs);
      result.addAll(vlessConfigs);
    }
    return result;
  }

  Future<Map<String, dynamic>> _getAllSavedConfigsMap() async {
    final storage = ref.read(secureStorageProvider);
    final raw = await storage.read(key: 'saved_configs');
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on Object {
      return <String, dynamic>{};
    }
  }

  Future<void> _saveConfigsMap(Map<String, dynamic> map) async {
    final storage = ref.read(secureStorageProvider);
    await storage.write(key: 'saved_configs', value: jsonEncode(map));
  }

  /// Автоматическое подключение: перебирает методы пока не найдёт рабочий.
  Future<ConnectAttemptResult> autoConnect({
    required void Function(String status) onStatus,
  }) async {
    final candidates = await _buildCandidates();
    if (candidates.isEmpty) {
      return const ConnectAttemptResult(
        success: false,
        error: 'Нет сохранённых конфигураций. Добавьте их в «Управление конфигами».',
      );
    }

    final info = await _platform.networkInfo();
    final networkType = info.type ?? 'unknown';
    appLog.info('ConnectionOrchestrator',
        'Сеть: $networkType, мобильная: $isMobile, кандидатов: ${candidates.length}');

    // Запоминаем IP до подключения
    _ipBefore = await _fetchPublicIp().timeout(_ipCheckTimeout);
    appLog.info('ConnectionOrchestrator', 'IP до подключения: $_ipBefore');

    for (final candidate in candidates) {
      onStatus('Проверка ${candidate.name}…');
      appLog.info('ConnectionOrchestrator', 'Пробуем метод: ${candidate.name} (${candidate.type})');

      final success = await _tryCandidate(candidate);
      if (success) {
        final ipAfter = await _fetchPublicIp().timeout(_ipCheckTimeout);
        appLog.info('ConnectionOrchestrator',
            'Успех: ${candidate.name}, IP: $_ipBefore → $ipAfter');
        return ConnectAttemptResult(
          success: true,
          methodName: candidate.name,
          publicIp: ipAfter,
        );
      }

      appLog.info('ConnectionOrchestrator',
          'Неудача: ${candidate.name}, пробуем следующий');
    }

    return const ConnectAttemptResult(
      success: false,
      error: 'Не удалось подключиться ни к одному методу. Проверьте конфиги или смените сеть.',
    );
  }

  /// Пробует один кандидата с таймаутом [_methodTimeout].
  Future<bool> _tryCandidate(ConnectionCandidate candidate) async {
    final completer = Completer<bool>();
    Timer? timeoutTimer;

    timeoutTimer = Timer(_methodTimeout, () {
      if (!completer.isCompleted) {
        appLog.warn('ConnectionOrchestrator', 'Таймаут метода ${candidate.name}');
        _disconnectCandidate(candidate);
        completer.complete(false);
      }
    });

    try {
      switch (candidate.type) {
        case ConnectionMethodType.amneziawg:
          if (candidate.awgConfig == null) {
            timeoutTimer.cancel();
            return false;
          }
          await _awg.connect(candidate.awgConfig!);
          break;
        case ConnectionMethodType.vless:
          if (candidate.vlessConfig == null) {
            timeoutTimer.cancel();
            return false;
          }
          await _vpn.connect(candidate.vlessConfig!);
          break;
      }

      // Подождем немного чтобы туннель установился
      await Future.delayed(const Duration(seconds: 1));

      // Проверяем: HTTP-запрос к api.ipify.org < 3с И IP изменился
      final ipAfter = await _fetchPublicIp().timeout(_ipCheckTimeout);
      timeoutTimer.cancel();

      if (ipAfter == null) {
        _disconnectCandidate(candidate);
        if (!completer.isCompleted) completer.complete(false);
        return false;
      }

      // Сравниваем с IP до подключения
      final ipChanged = _ipBefore != null && ipAfter != _ipBefore;
      if (ipChanged && !completer.isCompleted) {
        completer.complete(true);
        return true;
      }

      // IP не изменился — отключаем и пробуем следующий
      _disconnectCandidate(candidate);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
    } on Object catch (e) {
      timeoutTimer.cancel();
      appLog.warn('ConnectionOrchestrator', 'Ошибка метода ${candidate.name}: $e');
      _disconnectCandidate(candidate);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
    }
  }

  Future<void> _disconnectCandidate(ConnectionCandidate candidate) async {
    switch (candidate.type) {
      case ConnectionMethodType.amneziawg:
        await _awg.disconnect();
        break;
      case ConnectionMethodType.vless:
        await _vpn.disconnect();
        break;
    }
  }

  Future<String?> _fetchPublicIp() async {
    try {
      final client = http.Client();
      try {
        final resp = await client
            .get(Uri.parse(_ipCheckUrl))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final ip = resp.body.trim();
          if (ip.isNotEmpty && ip.length < 64) return ip;
        }
      } finally {
        client.close();
      }
    } on Object {
      // ignore
    }
    return null;
  }

  // ===== Сохранение/загрузка конфигов =====

  Future<List<Map<String, dynamic>>> getAllSavedConfigs() async {
    final map = await _getAllSavedConfigsMap();
    final list = <Map<String, dynamic>>[];
    map.forEach((id, value) {
      if (value is Map) {
        list.add(Map<String, dynamic>.from(value)..['id'] = id);
      }
    });
    return list;
  }

  Future<void> saveConfig({
    required String id,
    required String name,
    required ConnectionMethodType type,
    required Map<String, dynamic> data,
  }) async {
    final map = await _getAllSavedConfigsMap();
    map[id] = {
      'id': id,
      'name': name,
      'type': type.index,
      'data': data,
    };
    await _saveConfigsMap(map);
  }

  Future<void> deleteConfig(String id) async {
    final map = await _getAllSavedConfigsMap();
    map.remove(id);
    await _saveConfigsMap(map);
  }

  Future<void> saveAwgConfig(WireGuardConfig cfg, {String? name}) async {
    await saveConfig(
      id: name ?? cfg.name,
      name: name ?? cfg.name,
      type: ConnectionMethodType.amneziawg,
      data: cfg.toJson(),
    );
  }

  Future<void> saveVlessConfig(VpnConfig cfg, {String? name}) async {
    await saveConfig(
      id: name ?? cfg.remark,
      name: name ?? cfg.remark,
      type: ConnectionMethodType.vless,
      data: cfg.toJson(),
    );
  }
}

/// Провайдер ConnectionOrchestrator (параметр: isMobile).
final connectionOrchestratorProvider =
    Provider.family<ConnectionOrchestrator, bool>((ref, isMobile) {
  return ConnectionOrchestrator(ref: ref, isMobile: isMobile);
});
