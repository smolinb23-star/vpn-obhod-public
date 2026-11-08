import 'dart:convert';

import 'package:vpn_service/core/models/vpn_config.dart';

/// Ошибки импорта профиля.
class ConfigParseException implements Exception {
  const ConfigParseException(this.message);
  final String message;

  @override
  String toString() => 'ConfigParseException: $message';
}

/// Чистый Dart-парсер share-ссылок в Xray JSON.
///
/// Поддерживает vless://, hysteria2://, hy2:// и raw Xray JSON. Остальные
/// протоколы и форматы (trojan, vmess, ss, Clash YAML, sing-box JSON,
/// подписки с заголовками) обрабатываются fallback-путём
/// FlutterVless.parse()/parseMany() на слое сервиса.
class ProfileParser {
  const ProfileParser();

  List<VpnConfig> parseAll(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ConfigParseException('Пустой ввод');
    }

    // Raw Xray JSON
    if (trimmed.startsWith('{')) {
      return <VpnConfig>[_fromXrayJson(trimmed)];
    }

    // Base64-подписка (несколько ссылок по строкам)
    if (_looksLikeSubscription(trimmed)) {
      return _parseSubscription(trimmed);
    }

    // CIDR-список (только диапазоны IP, без протокола) - маршрутизация через VPN
    if (_looksLikeCidrList(trimmed)) {
      return <VpnConfig>[_parseCidrList(trimmed)];
    }

    return _parseLines(trimmed.split(RegExp(r'\s+')));
  }

  VpnConfig parseOne(String input) {
    final list = parseAll(input);
    if (list.isEmpty) {
      throw const ConfigParseException('Не найдено ни одного профиля');
    }
    return list.first;
  }

  List<VpnConfig> _parseSubscription(String payload) {
    // Формат: base64(ссылки, разделённые \n)
    try {
      final decoded = utf8.decode(base64Decode(payload.replaceAll(
        RegExp(r'\s'),
        '',
      )));
      return _parseLines(decoded.split(RegExp(r'[\r\n]+')));
    } on FormatException {
      throw const ConfigParseException('Не удалось декодировать подписку');
    }
  }

  bool _looksLikeSubscription(String s) {
    if (s.contains('://')) return false;
    return RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(s) && s.length > 64;
  }

  /// Проверяет, является ли текст списком CIDR-диапазонов (IP/маска, по одной в строке).
  bool _looksLikeCidrList(String s) {
    final lines = s.split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return false;
    // Каждая строка должна быть CIDR: IP/маска
    final cidrRegex = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$');
    return lines.every((l) => cidrRegex.hasMatch(l.trim()));
  }

  /// Парсит список CIDR-диапазонов в конфиг для маршрутизации через VPN.
  VpnConfig _parseCidrList(String input) {
    final cidrs = input
        .split(RegExp(r'[\r\n]+'))
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim())
        .toList(growable: false);

    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'blackhole',
          'settings': <String, dynamic>{},
        },
      ],
      'routing': <String, dynamic>{
        'rules': <dynamic>[
          for (final cidr in cidrs)
            <String, dynamic>{
              'type': 'field',
              'ip': [cidr],
              'outboundTag': 'proxy',
            },
        ],
      },
    };

    return VpnConfig(
      remark: 'CIDR маршрутизация (${cidrs.length} диапазонов)',
      protocol: ProfileProtocol.other,
      xrayJson: jsonEncode(config),
      stream: '',
      security: '',
      host: '',
      cdnFronted: false,
      streamPath: '',
      streamHost: '',
      cascadeType: CascadeType.none,
      cidrList: cidrs,
    );
  }

  List<VpnConfig> _parseLines(List<String> lines) {
    final result = <VpnConfig>[];
    for (final line in lines) {
      final link = line.trim();
      if (link.isEmpty) continue;
      try {
        result.add(_parseLink(link));
      } on ConfigParseException {
        // Пропускаем неподдерживаемые ссылки, как это делает parseMany().
        continue;
      }
    }
    if (result.isEmpty) {
      throw const ConfigParseException('Ни одна ссылка не распознана');
    }
    return result;
  }

  VpnConfig _parseLink(String link) {
    if (link.startsWith('vless://')) return _parseVless(link);
    if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
      return _parseHysteria2(link);
    }
    throw ConfigParseException('Неподдерживаемый протокол: ${link.split(':').first}');
  }

  // vless://uuid@host:port?params#remark
  VpnConfig _parseVless(String link) {
    final Uri uri;
    try {
      uri = Uri.parse(link);
    } on FormatException {
      throw const ConfigParseException('Некорректная vless-ссылка');
    }
    final uuid = uri.userInfo;
    final host = uri.host;
    final port = uri.port;
    if (uuid.isEmpty || host.isEmpty || port <= 0) {
      throw const ConfigParseException('vless: не хватает uuid/host/port');
    }

    final q = uri.queryParameters;
    final encryption = q['encryption'] ?? 'none';
    final flow = q['flow'] ?? '';
    final security = q['security'] ?? 'none';
    final type = q['type'] ?? 'tcp';
    final sni = q['sni'] ?? q['peer'] ?? '';
    final publicKey = q['pbk'] ?? '';
    final sid = q['sid'] ?? '';
    final fingerprint = q['fp'] ?? 'chrome';
    final alpn = q['alpn'] ?? '';
    final hostHeader = q['host'] ?? '';
    final path = q['path'] ?? '/';

    final streamSettings = <String, dynamic>{
      'network': type,
      'security': security,
    };

    if (security == 'reality') {
      streamSettings['realitySettings'] = <String, dynamic>{
        'serverName': sni,
        'fingerprint': fingerprint,
        'publicKey': publicKey,
        if (sid.isNotEmpty) 'shortId': sid,
      };
    } else if (security == 'tls') {
      streamSettings['tlsSettings'] = <String, dynamic>{
        if (sni.isNotEmpty) 'serverName': sni,
        if (alpn.isNotEmpty) 'alpn': alpn.split(','),
      };
    }

    if (type == 'xhttp' || type == 'ws') {
      streamSettings[type] = <String, dynamic>{
        'path': path,
        if (hostHeader.isNotEmpty) 'host': hostHeader,
        if (type == 'xhttp' && q['mode'] != null) 'mode': q['mode'],
      };
    } else if (type == 'grpc') {
      streamSettings['grpcSettings'] = <String, dynamic>{
        'serviceName': q['serviceName'] ?? q['mode'] ?? 'x',
        if (q['multiMode'] != null) 'multiMode': q['multiMode'],
      };
    }

    // Inbounds намеренно отсутствуют: в VPN-режиме flutter_vless сам
    // поднимает приватный loopback-SOCKS со свежими нативными креденшелами.
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': <String, dynamic>{
            'vnext': <dynamic>[
              <String, dynamic>{
                'address': host,
                'port': port,
                'users': <dynamic>[
                  <String, dynamic>{
                    'id': uuid,
                    'encryption': encryption,
                    if (flow.isNotEmpty) 'flow': flow,
                  },
                ],
              },
            ],
          },
          'streamSettings': streamSettings,
        },
      ],
    };

    final cdnFronted = _isCdnFronted(type, hostHeader, sni, host);

    return VpnConfig(
      remark: uri.fragment.isEmpty ? 'VLESS $host' : Uri.decodeComponent(uri.fragment),
      protocol: ProfileProtocol.vless,
      xrayJson: jsonEncode(config),
      stream: type,
      security: security,
      host: hostHeader.isNotEmpty ? hostHeader : sni,
      cdnFronted: cdnFronted,
      streamPath: path,
      streamHost: hostHeader,
      cascadeType: CascadeType.none,
    );
  }

  // hysteria2://uuid@host:port?params#remark
  VpnConfig _parseHysteria2(String link) {
    final normalized = link.replaceFirst('hy2://', 'hysteria2://');
    final Uri uri;
    try {
      uri = Uri.parse(normalized);
    } on FormatException {
      throw const ConfigParseException('Некорректная hysteria2-ссылка');
    }
    final password = uri.userInfo;
    final host = uri.host;
    final port = uri.port;
    if (password.isEmpty || host.isEmpty || port <= 0) {
      throw const ConfigParseException('hysteria2: не хватает password/host/port');
    }

    final q = uri.queryParameters;
    final sni = q['sni'] ?? q['peer'] ?? '';

    // Конфиг Hysteria2 для Xray-рантайма flutter_vless.
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'hysteria2',
          'settings': <String, dynamic>{
            'servers': <dynamic>[
              <String, dynamic>{
                'address': host,
                'port': port,
                'password': password,
              },
            ],
          },
          'streamSettings': <String, dynamic>{
            'network': 'raw',
            'security': 'quic',
            'quicSettings': <String, dynamic>{
              'security': 'none',
              'key': '',
              'alpn': <dynamic>['h3'],
            },
            if (sni.isNotEmpty)
              'tlsSettings': <String, dynamic>{'serverName': sni},
          },
        },
      ],
    };

    return VpnConfig(
      remark: uri.fragment.isEmpty ? 'Hysteria2 $host' : Uri.decodeComponent(uri.fragment),
      protocol: ProfileProtocol.hysteria2,
      xrayJson: jsonEncode(config),
      stream: 'quic',
      security: 'tls',
      host: sni,
    );
  }

  VpnConfig _fromXrayJson(String raw) {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(_stripJsonComments(raw)) as Map<String, dynamic>;
    } on Object {
      throw const ConfigParseException('Некорректный Xray JSON');
    }
    final outbounds = map['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      throw const ConfigParseException('Xray JSON без outbounds');
    }
    final first = outbounds.first as Map<String, dynamic>;
    final protocol = switch (first['protocol']) {
      'vless' => ProfileProtocol.vless,
      'vmess' => ProfileProtocol.vmess,
      'trojan' => ProfileProtocol.trojan,
      'shadowsocks' => ProfileProtocol.shadowsocks,
      'hysteria2' => ProfileProtocol.hysteria2,
      'socks' => ProfileProtocol.socks,
      _ => ProfileProtocol.other,
    };

    final stream = first['streamSettings'] as Map<String, dynamic>? ?? const {};
    return VpnConfig(
      remark: 'JSON ${first['protocol'] ?? '?'}',
      protocol: protocol,
      xrayJson: jsonEncode(map),
      stream: stream['network'] as String? ?? '',
      security: stream['security'] as String? ?? '',
    );
  }

  bool _isCdnFronted(String type, String hostHeader, String sni, String server) {
    // Фронт считается CDN-обходом, если заголовок/SNI отличается от IP-адреса сервера
    // и транспорт веб-типа (xhttp/ws/grpc).
    if (!const ['xhttp', 'ws', 'grpc'].contains(type)) return false;
    final front = hostHeader.isNotEmpty ? hostHeader : sni;
    if (front.isEmpty) return false;
    return front != server;
  }

  String _stripJsonComments(String s) {
    // Xray-стиль: допускаем // комментарии в начале строк.
    return s
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^\s*//.*$'), ''))
        .join('\n');
  }
}
