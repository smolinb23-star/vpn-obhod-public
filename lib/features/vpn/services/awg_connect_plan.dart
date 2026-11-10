import 'dart:io';

import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';

/// План подключения нативного AmneziaWG: что именно уйдёт в нативный слой.
///
/// Решает три частые причины «rx/tx растут, но трафика нет»:
///  - Endpoint задан доменом → резолвим в IPv4 до поднятия туннеля;
///  - DNS не задан/некорректен → подставляем 1.1.1.1, 1.0.0.1;
///  - MTU из UI (1180/1200/1240/1280) переопределяет значение из .conf.
class AwgConnectPlan {
  const AwgConnectPlan({
    required this.config,
    required this.notes,
    required this.dnsOverridden,
    required this.endpointResolved,
    required this.mtu,
  });

  /// Эффективный конфиг: endpoint уже IP, DNS и MTU переопределены.
  final WireGuardConfig config;
  final List<String> notes;
  final bool dnsOverridden;
  final bool endpointResolved;
  final int mtu;

  static const List<String> defaultDns = <String>[
    '1.1.1.1',
    '1.0.0.1',
    '8.8.8.8',
  ];
  static const int defaultMtu = 1280;

  /// Строит план. [resolver] инъектируется в тестах.
  static Future<AwgConnectPlan> create(
    WireGuardConfig cfg, {
    int mtu = defaultMtu,
    bool forceDefaultDns = false,
    Future<List<String>> Function(String host)? resolver,
  }) async {
    final notes = <String>[];

    var host = cfg.endpointHost;
    var endpointResolved = false;
    if (!isIpLiteral(host)) {
      try {
        final ips = await (resolver ?? _lookup)(host);
        if (ips.isNotEmpty) {
          host = ips.first;
          endpointResolved = true;
          notes.add('Endpoint ${cfg.endpointHost} → $host');
        } else {
          notes.add('Endpoint ${cfg.endpointHost} не разрешился — '
              'передаю домен, резолв сделает нативный слой');
        }
      } on Object catch (e) {
        notes.add('Endpoint ${cfg.endpointHost}: резолв не удался ($e) — '
            'передаю домен');
      }
    } else {
      notes.add('Endpoint уже IP: $host');
    }

    var dns = List<String>.of(cfg.dns);
    var dnsOverridden = false;
    final usable = dns.where(isUsableDns).toList(growable: false);
    if (forceDefaultDns) {
      dns = List<String>.of(defaultDns);
      dnsOverridden = true;
      notes.add('DNS принудительно переопределён: ${defaultDns.join(', ')}');
    } else if (dns.isEmpty || usable.isEmpty) {
      dns = List<String>.of(defaultDns);
      dnsOverridden = true;
      notes.add(dns.isEmpty
          ? 'DNS в .conf отсутствует — подставлен ${defaultDns.join(', ')}'
          : 'DNS в .conf некорректен (${cfg.dns.join(', ')}) — '
              'подставлен ${defaultDns.join(', ')}');
    } else if (usable.length != dns.length) {
      notes.add('Некорректные DNS отброшены: '
          '${dns.where((d) => !isUsableDns(d)).join(', ')}');
      dns = List<String>.of(usable);
    } else {
      notes.add('DNS из .conf: ${dns.join(', ')}');
    }

    final effectiveMtu = mtu > 0 ? mtu : defaultMtu;
    notes.add('MTU: $effectiveMtu');

    final effective = cfg.copyWith(
      endpointHost: host,
      dns: dns,
      mtu: effectiveMtu,
    );

    for (final note in notes) {
      appLog.info('AwgConnectPlan', note);
    }

    return AwgConnectPlan(
      config: effective,
      notes: List<String>.unmodifiable(notes),
      dnsOverridden: dnsOverridden,
      endpointResolved: endpointResolved,
      mtu: effectiveMtu,
    );
  }

  static Future<List<String>> _lookup(String host) async {
    final found = await InternetAddress.lookup(host)
        .timeout(const Duration(seconds: 5));
    final v4 = found
        .where((a) => a.type == InternetAddressType.IPv4)
        .map((a) => a.address)
        .toList(growable: false);
    if (v4.isNotEmpty) return v4;
    return found.map((a) => a.address).toList(growable: false);
  }

  static bool isIpLiteral(String value) => InternetAddress.tryParse(value) != null;

  /// DNS пригоден: валидный IP, не 0.0.0.0 и не loopback.
  static bool isUsableDns(String value) {
    final addr = InternetAddress.tryParse(value.trim());
    if (addr == null) return false;
    if (addr.isLoopback) return false;
    if (addr.address == '0.0.0.0' || addr.address == '::') return false;
    return true;
  }
}
