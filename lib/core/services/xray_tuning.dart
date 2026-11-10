import 'dart:convert';

import 'package:vpn_service/core/services/app_log.dart';

/// Клиентская оптимизация Xray-конфига перед запуском.
///
/// Применяется ко всем путям, которые отдают JSON в flutter_vless:
///  - включает TCP Fast Open и TCP_NODELAY (sockopt outbound'а);
///  - для VLESS Reality поверх TCP включает XTLS Vision
///    (`flow: xtls-rprx-vision`), если flow не задан явно;
///  - добавляет быстрый DNS (1.1.1.1 / 8.8.8.8) и `queryStrategy: UseIPv4`.
///
/// Fake-IP — механизм Mihomo/sing-box, в Xray его нет: его роль здесь
/// выполняет быстрый DNS + передача домена на удалённый сервер (Xray сам
/// резолвит имена на стороне прокси).
class XrayTuning {
  const XrayTuning();

  static const List<String> fastDns = <String>['1.1.1.1', '8.8.8.8'];
  static const String visionFlow = 'xtls-rprx-vision';

  /// Возвращает оптимизированный JSON. При любой ошибке — исходный текст.
  String apply(String xrayJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(xrayJson);
    } on Object {
      return xrayJson;
    }
    if (decoded is! Map<String, dynamic>) return xrayJson;

    try {
      _tuneOutbounds(decoded);
      _ensureDns(decoded);
      return jsonEncode(decoded);
    } on Object catch (e) {
      appLog.warn('XrayTuning', 'оптимизация пропущена: $e');
      return xrayJson;
    }
  }

  void _tuneOutbounds(Map<String, dynamic> map) {
    final outbounds = map['outbounds'];
    if (outbounds is! List) return;

    for (final raw in outbounds) {
      if (raw is! Map<String, dynamic>) continue;
      final protocol = raw['protocol'];
      if (protocol == 'blackhole' || protocol == 'dns') continue;

      final stream = _mapOrCreate(raw, 'streamSettings');

      // TCP Fast Open + TCP_NODELAY: меньше задержка на каждом соединении.
      final sockopt = _mapOrCreate(stream, 'sockopt');
      sockopt.putIfAbsent('tcpFastOpen', () => true);
      sockopt.putIfAbsent('tcpNoDelay', () => true);

      if (protocol == 'vless') {
        _ensureVision(raw, stream);
      }
    }
  }

  /// VLESS Reality + TCP без явного flow = XTLS Vision.
  ///
  /// Явно заданный flow (включая `none`) не перетирается.
  void _ensureVision(
    Map<String, dynamic> outbound,
    Map<String, dynamic> stream,
  ) {
    final security = stream['security']?.toString().toLowerCase();
    if (security != 'reality') return;
    final network = (stream['network'] ?? 'tcp').toString().toLowerCase();
    if (network != 'tcp' && network != 'raw') return;

    final settings = outbound['settings'];
    if (settings is! Map<String, dynamic>) return;
    final vnext = settings['vnext'];
    if (vnext is! List) return;

    for (final server in vnext) {
      if (server is! Map<String, dynamic>) continue;
      final users = server['users'];
      if (users is! List) continue;
      for (final user in users) {
        if (user is! Map<String, dynamic>) continue;
        final flow = user['flow']?.toString() ?? '';
        if (flow.isEmpty) user['flow'] = visionFlow;
      }
    }
  }

  /// Быстрый DNS, если конфиг не задаёт собственный.
  void _ensureDns(Map<String, dynamic> map) {
    final dns = _mapOrCreate(map, 'dns');
    final servers = dns['servers'];
    if (servers is! List || servers.isEmpty) {
      dns['servers'] = List<String>.of(fastDns);
    }
    dns.putIfAbsent('queryStrategy', () => 'UseIPv4');
  }

  /// Возвращает вложенный Map<String, dynamic>, создавая его при отсутствии.
  Map<String, dynamic> _mapOrCreate(
    Map<String, dynamic> parent,
    String key,
  ) {
    final value = parent[key];
    if (value is Map<String, dynamic>) return value;
    final created = <String, dynamic>{};
    parent[key] = created;
    return created;
  }
}
