import 'dart:convert';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';

/// Ошибки разбора WireGuard/AmneziaWG .conf.
class WGConfigParseException implements Exception {
  const WGConfigParseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Парсер `.conf`-файлов WireGuard и AmneziaWG (в т.ч. экспортов Cloudflare WARP
/// через AmneziaWG).
///
/// Формат — ini-подобный: секции `[Interface]`/`[Peer]`, пары `Key = value`.
/// Ключи AmneziaWG (`Jc`, `Jmin`, `Jmax`, `H1..H4`, `S1`, `S2`) сохраняются в
/// [WireGuardConfig.amnezia]: через Xray wireguard-outbound они не применяются,
/// но пригодятся при подключении нативного AmneziaWG-движка.
class WGConfigParser {
  const WGConfigParser();

  /// Ключи AmneziaWG вне стандартного набора WireGuard.
  static const Set<String> _amneziaKeys = <String>{
    'jc', 'jmin', 'jmax', 'h1', 'h2', 'h3', 'h4', 's1', 's2',
    'amneziajc', 'amneziajmin', 'amneziajmax',
    'amneziah1', 'amneziah2', 'amneziah3', 'amneziah4',
    'amnezias1', 'amnezias2',
    'extendedtiming', 'table',
  };

  /// Быстрая проверка, что текст похож на WireGuard-конфиг.
  static bool looksLikeWireGuardConf(String content) {
    final t = content.trim();
    return RegExp(r'\[\s*interface\s*\]', caseSensitive: false).hasMatch(t) &&
        RegExp(r'\[\s*peer\s*\]', caseSensitive: false).hasMatch(t) &&
        RegExp(r'^\s*PrivateKey\s*=', multiLine: true, caseSensitive: false)
            .hasMatch(t) &&
        RegExp(r'^\s*PublicKey\s*=', multiLine: true, caseSensitive: false)
            .hasMatch(t);
  }

  /// Разбирает .conf. [fallbackName] — имя профиля (обычно имя файла).
  WireGuardConfig parse(String content, {String fallbackName = 'AmneziaWG'}) {
    final text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (!looksLikeWireGuardConf(text)) {
      throw const WGConfigParseException(
        'Файл не похож на WireGuard-конфиг: нужны секции [Interface] с '
        'PrivateKey и [Peer] с PublicKey',
      );
    }

    var section = '';
    String? privateKey;
    final addresses = <String>[];
    final dns = <String>[];
    int? mtu;
    String? publicKey;
    String? presharedKey;
    String? endpointHost;
    int? endpointPort;
    List<String>? allowedIps;
    int? keepalive;
    final amnezia = <String, String>{};

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        continue;
      }
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      final value = line.substring(eq + 1).trim();
      if (value.isEmpty) continue;

      if (_amneziaKeys.contains(key)) {
        amnezia[key] = value;
        continue;
      }

      switch (section) {
        case 'interface':
          switch (key) {
            case 'privatekey':
              privateKey = value;
              break;
            case 'address':
              addresses.addAll(_splitList(value));
              break;
            case 'dns':
              dns.addAll(_splitList(value));
              break;
            case 'mtu':
              mtu = int.tryParse(value);
              break;
            default:
              break; // ListenPort и прочее для клиента-туннеля не нужны
          }
          break;

        case 'peer':
          switch (key) {
            case 'publickey':
              publicKey = value;
              break;
            case 'presharedkey':
              presharedKey = value;
              break;
            case 'endpoint':
              final parsed = _splitEndpoint(value);
              endpointHost = parsed.$1;
              endpointPort = parsed.$2;
              break;
            case 'allowedips':
              allowedIps = _splitList(value);
              break;
            case 'persistentkeepalive':
              keepalive = int.tryParse(value);
              break;
            default:
              break;
          }
          break;

        default:
          break;
      }
    }

    if (privateKey == null) {
      throw const WGConfigParseException('[Interface] без PrivateKey');
    }
    _validateKey(privateKey, 'PrivateKey');
    if (publicKey == null) {
      throw const WGConfigParseException('[Peer] без PublicKey');
    }
    _validateKey(publicKey, 'PublicKey');
    if (presharedKey != null) {
      _validateKey(presharedKey, 'PresharedKey');
    }
    if (endpointHost == null || endpointHost.isEmpty) {
      throw const WGConfigParseException(
        '[Peer] без Endpoint — неизвестен адрес сервера',
      );
    }
    if (endpointPort == null || endpointPort <= 0 || endpointPort > 65535) {
      throw const WGConfigParseException('Endpoint: некорректный порт');
    }
    if (addresses.isEmpty) {
      throw const WGConfigParseException(
        '[Interface] без Address — Xray не сможет поднять туннель',
      );
    }

    return WireGuardConfig(
      name: fallbackName,
      privateKey: privateKey,
      addresses: addresses,
      peerPublicKey: publicKey,
      peerPresharedKey: presharedKey,
      endpointHost: endpointHost,
      endpointPort: endpointPort,
      allowedIps: allowedIps?.isNotEmpty == true
          ? allowedIps!
          : const ['0.0.0.0/0', '::/0'],
      persistentKeepalive: keepalive ?? 25,
      dns: dns,
      mtu: mtu,
      amnezia: amnezia,
    );
  }

  /// Конвертация в профиль приложения: протокол wireguard, конфиг — Xray JSON.
  VpnConfig toVpnConfig(WireGuardConfig cfg) => VpnConfig(
        remark: cfg.name,
        protocol: ProfileProtocol.wireguard,
        xrayJson: cfg.toXrayJson(),
        stream: 'wireguard',
        security: cfg.hasAmnezia ? 'amnezia' : 'none',
        host: cfg.endpointHost,
      );

  /// Разбор и конвертация в один шаг.
  VpnConfig importConf(String content, {String fallbackName = 'AmneziaWG'}) =>
      toVpnConfig(parse(content, fallbackName: fallbackName));

  List<String> _splitList(String value) => value
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// `host:port` для IPv4/IPv6/домена (`[::1]:51820`, `1.2.3.4:51820`).
  (String, int?) _splitEndpoint(String value) {
    final v = value.trim();
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close > 0) {
        final host = v.substring(1, close);
        final rest = v.substring(close + 1);
        final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
        return (host, port);
      }
      return (v, null);
    }
    final last = v.lastIndexOf(':');
    if (last <= 0) return (v, null);
    // IPv6 без скобок (несколько ':') — порт не определить однозначно.
    if (v.indexOf(':') != last && v.contains('.')) {
      return (v.substring(0, last), int.tryParse(v.substring(last + 1)));
    }
    if (v.indexOf(':') != last) return (v, null);
    return (v.substring(0, last), int.tryParse(v.substring(last + 1)));
  }

  /// Ключ Curve25519 в WireGuard — base64 от 32 байт (44 символа с '=').
  void _validateKey(String key, String label) {
    final stripped = key.replaceAll('=', '');
    if (stripped.length != 43) {
      throw WGConfigParseException(
        '$label: ожидается 44 символа base64, получено ${key.length}',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9+/]{43}$').hasMatch(stripped)) {
      throw WGConfigParseException('$label: некорректные символы в ключе');
    }
    try {
      base64Decode('$stripped=');
    } on FormatException {
      throw WGConfigParseException('$label: не декодируется как base64');
    }
  }
}
