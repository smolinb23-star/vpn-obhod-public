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
    this.attempts = const [],
    this.methodType,
  });

  final bool success;
  final String? methodName;
  final String? error;
  final String? publicIp;
  final List<MethodAttemptLog> attempts;
  final ConnectionMethodType? methodType;
}

/// Кандидат для подключения.
class ConnectionCandidate {
  const ConnectionCandidate({
    required this.id,
    required this.name,
    required this.type,
    this.awgConfig,
    this.vlessConfig,
    this.cdnConfig,
    this.cascadeConfig,
    this.cidrConfig,
  });

  final String id;
  final String name;
  final ConnectionMethodType type;

  final WireGuardConfig? awgConfig;
  final VpnConfig? vlessConfig;
  final VpnConfig? cdnConfig;
  final VpnConfig? cascadeConfig;
  final VpnConfig? cidrConfig;
}

/// Тип метода подключения.
enum ConnectionMethodType { amneziawg, vless, cdn, cascade, cidr }

/// Результат одной попытки проверки метода.
class MethodAttemptLog {
  const MethodAttemptLog({
    required this.methodName,
    required this.ok,
    this.error,
  });

  final String methodName;
  final bool ok;
  final String? error;
}

/// Оркестратор автоматического подключения.
///
/// Последовательно пробует методы с жёстким таймаутом на каждый.
/// Метод считается успешным только если HTTP-запрос на api.ipify.org
/// (и резервные эндпоинты) проходит и публичный IP изменился.
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

  // Таймаут на один метод (подключение + проверка IP).
  static const Duration _methodTimeout = Duration(seconds: 15);
  // Таймаут на один HTTP-запрос IP.
  static const Duration _ipCheckTimeout = Duration(seconds: 8);
  // Задержка после connect перед первой проверкой IP (Android обновляет таблицу маршрутизации).
  static const Duration _postConnectDelay = Duration(seconds: 2);
  // Интервал между повторными проверками IP.
  static const Duration _ipRetryInterval = Duration(seconds: 2);
  // Количество повторных проверок IP перед признаком неудачи.
  static const int _ipRetryCount = 2;

  /// Резервные эндпоинты для проверки IP (если api.ipify.org недоступен).
  static const List<String> _ipCheckUrls = [
    'http://cp.cloudflare.com/generate_204',
    'https://api.ipify.org',
    'https://ifconfig.me/ip',
  ];

  /// IP до подключения (запоминается перед началом перебора).
  String? _ipBefore;

  /// История попыток для отображения в UI.
  final List<MethodAttemptLog> _attemptLogs = [];

  /// Список кандидатов для подключения в порядке приоритета.
  Future<List<ConnectionCandidate>> _buildCandidates() async {
    final all = await _getAllSavedConfigsMap();
    final awgConfigs = <ConnectionCandidate>[];
    final vlessConfigs = <ConnectionCandidate>[];
    final cdnConfigs = <ConnectionCandidate>[];
    final cascadeConfigs = <ConnectionCandidate>[];
    final cidrConfigs = <ConnectionCandidate>[];

    all.forEach((id, value) {
      if (value is! Map) return;
      final typeIndex = value['type'] as int? ?? 0;
      final type = ConnectionMethodType.values.firstWhere(
        (t) => t.index == typeIndex,
        orElse: () => ConnectionMethodType.vless,
      );
      final name = value['name'] as String? ?? id;
      final data = value['data'] as Map? ?? {};

      switch (type) {
        case ConnectionMethodType.amneziawg:
          try {
            awgConfigs.add(ConnectionCandidate(
              id: id,
              name: name,
              type: type,
              awgConfig: WireGuardConfig.fromJson(Map<String, dynamic>.from(data)),
            ));
          } on Object {
            // ignore malformed
          }
          break;
        case ConnectionMethodType.vless:
          try {
            final vcfg = VpnConfig.fromJson(Map<String, dynamic>.from(data));
            // Определяем подтип VLESS для приоритизации
            final vtype = _classifyVlessConfig(vcfg);
            vlessConfigs.add(ConnectionCandidate(
              id: id,
              name: name,
              type: vtype,
              vlessConfig: vcfg,
            ));
          } on Object {
            // ignore malformed
          }
          break;
        case ConnectionMethodType.cdn:
          try {
            cdnConfigs.add(ConnectionCandidate(
              id: id,
              name: name,
              type: type,
              cdnConfig: VpnConfig.fromJson(Map<String, dynamic>.from(data)),
            ));
          } on Object {
            // ignore malformed
          }
          break;
        case ConnectionMethodType.cascade:
          try {
            cascadeConfigs.add(ConnectionCandidate(
              id: id,
              name: name,
              type: type,
              cascadeConfig: VpnConfig.fromJson(Map<String, dynamic>.from(data)),
            ));
          } on Object {
            // ignore malformed
          }
          break;
        case ConnectionMethodType.cidr:
          try {
            cidrConfigs.add(ConnectionCandidate(
              id: id,
              name: name,
              type: type,
              cidrConfig: VpnConfig.fromJson(Map<String, dynamic>.from(data)),
            ));
          } on Object {
            // ignore malformed
          }
          break;
      }
    });

    // Сортируем VLESS конфиги: Reality первыми, потом QUIC/XHTTP, потом простые
    vlessConfigs.sort((a, b) {
      final aPrio = _vlessTypePriority(a.type);
      final bPrio = _vlessTypePriority(b.type);
      return aPrio.compareTo(bPrio);
    });

    final result = <ConnectionCandidate>[];
    if (isMobile) {
      // На мобильной сети строго сначала VLESS Reality, потом CDN, потом каскад, потом AWG
      result.addAll(vlessConfigs);
      result.addAll(cdnConfigs);
      result.addAll(cascadeConfigs);
      result.addAll(awgConfigs);
    } else {
      // На Wi-Fi сначала AmneziaWG, потом CDN, потом каскад, потом VLESS
      result.addAll(awgConfigs);
      result.addAll(cdnConfigs);
      result.addAll(cascadeConfigs);
      result.addAll(vlessConfigs);
    }
    // CIDR-маршрутизация всегда в конце (дополнительный маршрут, не основной туннель)
    result.addAll(cidrConfigs);
    return result;
  }

  /// Возвращает приоритет типа VLESS конфига: Reality=0, CDN/XHTTP=1, plain=2
  int _vlessTypePriority(ConnectionMethodType type) {
    switch (type) {
      case ConnectionMethodType.vless:
        return 0; // VLESS Reality - самый высокий приоритет
      case ConnectionMethodType.cdn:
        return 1; // QUIC/XHTTP
      case ConnectionMethodType.amneziawg:
        return 2; // AmneziaWG - низкий приоритет на мобильных
      case ConnectionMethodType.cascade:
        return 3;
      case ConnectionMethodType.cidr:
        return 4;
    }
  }

  /// Определяет тип VLESS конфига: Reality=0, CDN/XHTTP=1, plain=2
  ConnectionMethodType _classifyVlessConfig(VpnConfig cfg) {
    if (cfg.stream == 'grpc') {
      return ConnectionMethodType.vless; // gRPC обычно используется с Reality
    }
    if (cfg.stream == 'xhttp' || cfg.stream == 'ws') {
      return ConnectionMethodType.cdn;
    }
    if (cfg.security == 'reality') {
      return ConnectionMethodType.vless; // VLESS Reality
    }
    return ConnectionMethodType.vless; // plain WLESS
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
    _attemptLogs.clear();

    if (candidates.isEmpty) {
      final msg = isMobile
          ? 'Нет сохранённых конфигураций. На мобильном интернете добавьте VLESS-конфиг (ссылку vless://).'
          : 'Нет сохранённых конфигураций. Добавьте их в «Управление конфигами».';
      return ConnectAttemptResult(
        success: false,
        error: msg,
      );
    }

    // На мобильной сети если нет VLESS/CDN конфига — сразу ошибка
    if (isMobile && !candidates.any((c) => c.type == ConnectionMethodType.vless || c.type == ConnectionMethodType.cdn)) {
      return const ConnectAttemptResult(
        success: false,
        error: 'На мобильном интернете требуется VLESS-конфиг. Добавьте ссылку vless:// в «Управление конфигами».',
      );
    }

    final info = await _platform.networkInfo();
    final networkType = info.type ?? 'unknown';
    appLog.info('ConnectionOrchestrator',
        'Сеть: $networkType, мобильная: $isMobile, кандидатов: ${candidates.length}');

    // Запоминаем IP до подключения.
    _ipBefore = await _fetchPublicIpWithRetries();
    appLog.info('ConnectionOrchestrator', 'IP до подключения: $_ipBefore');

    for (int i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      onStatus('Проверка ${candidate.name}… (${i + 1}/${candidates.length})');
      appLog.info('ConnectionOrchestrator', 'Пробуем метод: ${candidate.name} (${candidate.type})');

      final success = await _tryCandidate(candidate);
      if (success) {
        final ipAfter = await _fetchPublicIpWithRetries();
        appLog.info('ConnectionOrchestrator',
            'Успех: ${candidate.name}, IP: $_ipBefore → $ipAfter');
        return ConnectAttemptResult(
          success: true,
          methodName: candidate.name,
          publicIp: ipAfter,
          attempts: List.unmodifiable(_attemptLogs),
        );
      }

      appLog.info('ConnectionOrchestrator',
          'Неудача: ${candidate.name}, пробуем следующий');
    }

    // Все методы исчерпаны — формируем детальную ошибку с историей.
    final attemptDescriptions = _attemptLogs.map((a) {
      final status = a.ok ? 'OK' : 'Ошибка';
      final err = a.error != null ? ' (${a.error})' : '';
      return '[${a.methodName}] $status$err';
    }).join('\n');

    final errorText = isMobile
        ? 'Не удалось подключиться ни к одному методу на мобильном интернете.\n'
            'Попытки:\n$attemptDescriptions\n\n'
            'Добавьте рабочий VLESS-конфиг в «Управление конфигами».'
        : 'Не удалось подключиться ни к одному методу.\n'
            'Попытки:\n$attemptDescriptions';

    return ConnectAttemptResult(
      success: false,
      error: errorText,
      attempts: List.unmodifiable(_attemptLogs),
    );
  }

  /// Пробует одного кандидата с таймаутом [_methodTimeout].
  ///
  /// Возвращает true если подключение установлено и IP изменился.
  Future<bool> _tryCandidate(ConnectionCandidate candidate) async {
    // Полное отключение предыдущего метода перед началом.
    await _disconnectAll();
    await Future.delayed(const Duration(milliseconds: 500));

    final completer = Completer<bool>();
    Timer? timeoutTimer;

    appLog.info('ConnectionOrchestrator',
        'Таймаут метода установлен на ${_methodTimeout.inSeconds} секунд');

    timeoutTimer = Timer(_methodTimeout, () {
      if (!completer.isCompleted) {
        appLog.warn('ConnectionOrchestrator',
            'Таймаут метода ${candidate.name} (${_methodTimeout.inSeconds}с)');
        _disconnectCandidate(candidate);
        completer.complete(false);
      }
    });

    try {
      switch (candidate.type) {
        case ConnectionMethodType.amneziawg:
          if (candidate.awgConfig == null) {
            timeoutTimer.cancel();
            _recordAttempt(candidate.name, false, 'Нет конфига');
            return false;
          }
          await _awg.connect(candidate.awgConfig!);
          break;
        case ConnectionMethodType.vless:
        case ConnectionMethodType.cdn:
          if (candidate.vlessConfig == null) {
            timeoutTimer.cancel();
            _recordAttempt(candidate.name, false, 'Нет конфига');
            return false;
          }
          await _vpn.connect(candidate.vlessConfig!);
          break;
        case ConnectionMethodType.cascade:
        case ConnectionMethodType.cidr:
          // Mihomo обрабатывает все протоколы через url-test, отдельные методы не нужны
          timeoutTimer.cancel();
          _recordAttempt(candidate.name, false, 'Метод не поддерживается в Mihomo');
          return false;
      }

      // Ждём чтобы Android обновил таблицу маршрутизации и туннель стабилизировался.
      await Future.delayed(_postConnectDelay);

      // Проверяем IP с повторными попытками.
      final ipAfter = await _fetchPublicIpWithRetries();
      timeoutTimer.cancel();

      if (ipAfter == null) {
        // DNS/сетевая ошибка, но туннель может быть активен — не считаем сразу неудачей,
        // однако без подтверждения IP метод считаем непригодным.
        appLog.warn('ConnectionOrchestrator',
            'IP не получен для ${candidate.name}, отключаем');
        _disconnectCandidate(candidate);
        _recordAttempt(candidate.name, false, 'IP не получен');
        if (!completer.isCompleted) completer.complete(false);
        return false;
      }

      // Сравниваем с IP до подключения.
      final ipChanged = _ipBefore != null && ipAfter != _ipBefore;
      if (ipChanged && !completer.isCompleted) {
        _recordAttempt(candidate.name, true);
        completer.complete(true);
        return true;
      }

      // IP не изменился — туннель поднят, но трафик не идёт через него.
      appLog.info('ConnectionOrchestrator',
          'IP не изменился ($_ipBefore → $ipAfter) для ${candidate.name}, отключаем');
      _disconnectCandidate(candidate);
      _recordAttempt(candidate.name, false, 'IP не изменился');
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
    } on Exception catch (e) {
      timeoutTimer.cancel();
      // DNS/сетевая ошибка — не считаем метод нерабочим если туннель поднят,
      // но без проверки IP мы не можем подтвердить успех.
      appLog.warn('ConnectionOrchestrator', 'Исключение для ${candidate.name}: $e');
      _disconnectCandidate(candidate);
      _recordAttempt(candidate.name, false, e.toString());
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
    } on Object catch (e) {
      timeoutTimer.cancel();
      appLog.warn('ConnectionOrchestrator', 'Ошибка метода ${candidate.name}: $e');
      _disconnectCandidate(candidate);
      _recordAttempt(candidate.name, false, e.toString());
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
    }
  }

  /// Записывает результат попытки для отображения в UI.
  void _recordAttempt(String methodName, bool ok, [String? error]) {
    _attemptLogs.add(MethodAttemptLog(
      methodName: methodName,
      ok: ok,
      error: error,
    ));
  }

  /// Отключает все активные тунели.
  Future<void> _disconnectAll() async {
    await _vpn.disconnect();
    await _awg.disconnect();
  }

  /// Отключает кандидата.
  Future<void> _disconnectCandidate(ConnectionCandidate candidate) async {
    switch (candidate.type) {
      case ConnectionMethodType.amneziawg:
        try {
          await _awg.disconnect();
        } on Object {
          // ignore
        }
        break;
      case ConnectionMethodType.vless:
      case ConnectionMethodType.cdn:
      case ConnectionMethodType.cascade:
      case ConnectionMethodType.cidr:
        try {
          await _vpn.disconnect();
        } on Object {
          // ignore
        }
        break;
    }
  }

  /// Получает публичный IP с повторными попытками и резервными эндпоинтами.
  Future<String?> _fetchPublicIpWithRetries() async {
    for (int attempt = 0; attempt < _ipRetryCount; attempt++) {
      if (attempt > 0) {
        await Future.delayed(_ipRetryInterval);
      }
      for (final url in _ipCheckUrls) {
        try {
          final ip = await _fetchSingleIp(url);
          if (ip != null) return ip;
        } on Object {
          // пробуем следующий URL
        }
      }
    }
    return null;
  }

  /// Один HTTP-запрос к указанному эндпоинту.
  Future<String?> _fetchSingleIp(String url) async {
    final client = http.Client();
    try {
      final resp = await client.get(Uri.parse(url)).timeout(_ipCheckTimeout);
      if (resp.statusCode == 200 || resp.statusCode == 204) {
        final body = resp.body.trim();
        if (body.isNotEmpty && body.length < 64) return body;
      }
    } on Object {
      // ignore, пробуем следующий URL
    } finally {
      client.close();
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

  Future<void> saveCdnConfig(VpnConfig cfg, {String? name}) async {
    await saveConfig(
      id: name ?? cfg.remark,
      name: name ?? cfg.remark,
      type: ConnectionMethodType.cdn,
      data: cfg.toJson(),
    );
  }

  Future<void> saveCascadeConfig(VpnConfig cfg, {String? name}) async {
    await saveConfig(
      id: name ?? cfg.remark,
      name: name ?? cfg.remark,
      type: ConnectionMethodType.cascade,
      data: cfg.toJson(),
    );
  }

  Future<void> saveCidrConfig(VpnConfig cfg, {String? name}) async {
    await saveConfig(
      id: name ?? 'CIDR ${cfg.cidrList.length} диапазонов',
      name: name ?? 'CIDR ${cfg.cidrList.length} диапазонов',
      type: ConnectionMethodType.cidr,
      data: cfg.toJson(),
    );
  }
}

/// Провайдер ConnectionOrchestrator (параметр: isMobile).
final connectionOrchestratorProvider =
    Provider.family<ConnectionOrchestrator, bool>((ref, isMobile) {
  return ConnectionOrchestrator(ref: ref, isMobile: isMobile);
});
