import 'dart:convert';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';

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
/// но нативный движок AmneziaWG использует их полностью.
///
/// Устойчивость:
///  - регистр секций/ключей не важен (`i1`/`I1`, `jc`/`Jc`, `AmneziaJc`);
///  - inline-комментарии (`Address = 10.0.0.2/32 # WARP`) отбрасываются;
///  - неизвестные секции/ключи не роняют разбор — попадают в warnings;
///  - base64-ключи нормализуются (пробелы, отсутствующий padding, URL-safe);
///  - каждая строка логируется с маскированием секретов.
class WGConfigParser {
  const WGConfigParser();

  /// Ключи AmneziaWG вне стандартного набора WireGuard.
  static const Set<String> _amneziaKeys = <String>{
    'jc', 'jmin', 'jmax', 'h1', 'h2', 'h3', 'h4', 's1', 's2',
    'i1', 'i2', 'i3', 'i4', 'i5', 'j1', 'j2', 'j3',
    'itimes', 'extendedtiming', 'table',
    'contentpaddingaddition', 'rekeyaftertime', 'rejectaftertime', 'maxhandshakeattempts',
  };

  static const Set<String> _knownSections = <String>{'interface', 'peer'};

  /// Быстрая проверка, что текст похож на WireGuard-конфиг.
  static bool looksLikeWireGuardConf(String content) {
    final t = content.replaceFirst('\uFEFF', '').trim();
    return RegExp(r'\[\s*interface\s*\]', caseSensitive: false).hasMatch(t) &&
        RegExp(r'\[\s*peer\s*\]', caseSensitive: false).hasMatch(t) &&
        RegExp(r'^\s*PrivateKey\s*=', multiLine: true, caseSensitive: false)
            .hasMatch(t) &&
        RegExp(r'^\s*PublicKey\s*=', multiLine: true, caseSensitive: false)
            .hasMatch(t);
  }

  /// Разбирает .conf. [fallbackName] — имя профиля (обычно имя файла).
  ///
  /// [logSink] получает подробный построчный лог (для показа в UI).
  WireGuardConfig parse(
    String content, {
    String fallbackName = 'AmneziaWG',
    List<String>? logSink,
  }) {
    final log = <String>[];
    final warnings = <String>[];

    void emit(String message) {
      log.add(message);
      logSink?.add(message);
      appLog.info('WGConfigParser', message);
    }

    void warn(String message) {
      warnings.add(message);
      emit('WARN $message');
    }

    var text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    if (!looksLikeWireGuardConf(text)) {
      throw const WGConfigParseException(
        'Файл не похож на WireGuard-конфиг: нужны секции [Interface] с '
        'PrivateKey и [Peer] с PublicKey',
      );
    }

    emit('Старт разбора, имя профиля: $fallbackName');

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
    var peerSections = 0;

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final lineNo = i + 1;
      final rawLine = lines[i];
      var line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('#') || line.startsWith(';')) {
        emit('$lineNo: комментарий пропущен');
        continue;
      }

      // Inline-комментарии: `Address = 10.0.0.2/32 # WARP`.
      final inline = RegExp(r'\s[#;].*$').firstMatch(line);
      if (inline != null) {
        line = line.substring(0, inline.start).trim();
        if (line.isEmpty) continue;
      }

      if (line.startsWith('[')) {
        if (!line.endsWith(']')) {
          warn('строка $lineNo: секция без закрывающей скобки — пропущена');
          continue;
        }
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        if (section == 'peer') peerSections++;
        if (!_knownSections.contains(section)) {
          warn('строка $lineNo: неизвестная секция [$section] — игнорируется');
        } else {
          emit('$lineNo: секция [$section]');
        }
        continue;
      }

      final eq = line.indexOf('=');
      if (eq <= 0) {
        warn('строка $lineNo: нет пары Key = value — пропущена');
        continue;
      }
      final rawKey = line.substring(0, eq).trim();
      final key = rawKey.toLowerCase();
      var value = line.substring(eq + 1).trim();
      // Убираем обрамляющие кавычки (некоторые экспортёры добавляют).
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1).trim();
      }
      if (value.isEmpty) {
        warn('строка $lineNo: пустое значение $rawKey — пропущено');
        continue;
      }

      emit('$lineNo: [$section] ${_maskForLog(rawKey, key, value)}');

      if (section.isEmpty) {
        warn('строка $lineNo: ключ $rawKey вне секции — пропущен');
        continue;
      }
      if (!_knownSections.contains(section)) {
        continue; // уже предупредили о секции
      }

      final amneziaKey = _canonicalAmneziaKey(key);
      if (amneziaKey != null) {
        if (amnezia.containsKey(amneziaKey)) {
          warn('строка $lineNo: дубликат Amnezia-ключа $amneziaKey — '
              'использовано последнее значение');
        }
        amnezia[amneziaKey] = value;
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
              final parsed = int.tryParse(value);
              if (parsed == null || parsed < 576 || parsed > 9000) {
                warn('строка $lineNo: некорректный MTU "$value" — игнорируется');
              } else {
                mtu = parsed;
              }
              break;
            case 'listenport':
              emit('$lineNo: ListenPort для клиента не нужен — игнорируется');
              break;
            default:
              warn('строка $lineNo: неизвестный ключ Interface.$rawKey — '
                  'игнорируется');
              break;
          }
          break;

        case 'peer':
          if (peerSections > 1) {
            warn('строка $lineNo: несколько секций [Peer] — используется '
                'первая, остальные игнорируются');
            break;
          }
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
              if (endpointPort == null) {
                final lastColon = value.lastIndexOf(':');
                final portPart =
                    lastColon >= 0 ? value.substring(lastColon + 1).trim() : '';
                final unbracketedIpv6 =
                    !value.startsWith('[') && value.split(':').length > 2;
                if (!unbracketedIpv6 &&
                    portPart.isNotEmpty &&
                    int.tryParse(portPart) == null) {
                  throw WGConfigParseException(
                      'Endpoint: некорректный порт "$portPart"');
                }
                warn('строка $lineNo: в Endpoint нет порта — использую 51820');
                endpointPort = 51820;
              }
              break;
            case 'allowedips':
              allowedIps = _splitList(value);
              break;
            case 'persistentkeepalive':
              final parsed = int.tryParse(value);
              if (parsed == null || parsed < 0) {
                warn('строка $lineNo: некорректный PersistentKeepalive '
                    '"$value" — игнорируется');
              } else {
                keepalive = parsed;
              }
              break;
            default:
              warn('строка $lineNo: неизвестный ключ Peer.$rawKey — '
                  'игнорируется');
              break;
          }
          break;
      }
    }

    if (privateKey == null) {
      throw const WGConfigParseException('[Interface] без PrivateKey');
    }
    privateKey = _normalizeKey(privateKey, 'PrivateKey', warn);
    if (publicKey == null) {
      throw const WGConfigParseException('[Peer] без PublicKey');
    }
    publicKey = _normalizeKey(publicKey, 'PublicKey', warn);
    if (presharedKey != null) {
      presharedKey = _normalizeKey(presharedKey, 'PresharedKey', warn);
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
        '[Interface] без Address — туннель не сможет подняться',
      );
    }
    if (dns.isEmpty) {
      warn('DNS не задан — будет подставлен 1.1.1.1 / 1.0.0.1');
    }
    if (allowedIps == null || allowedIps.isEmpty) {
      warn('AllowedIPs не задан — использую 0.0.0.0/0, ::/0');
    }

    emit('Разбор завершён: ${addresses.length} address, '
        '${amnezia.length} Amnezia-параметров, ${warnings.length} предупреждений');

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
      warnings: List<String>.unmodifiable(warnings),
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

  /// Amnezia-ключ в каноническом нижнем регистре (`AmneziaJc` → `jc`).
  String? _canonicalAmneziaKey(String key) {
    var k = key;
    if (k.startsWith('amnezia') && k.length > 7) {
      k = k.substring(7);
    }
    return _amneziaKeys.contains(k) ? k : null;
  }

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

  /// Нормализует base64-ключ Curve25519 (32 байта) и валидирует его.
  ///
  /// Принимает канонический base64 с `=`/без, с пробелами внутри,
  /// URL-safe алфавит (`-`/`_`) — всё приводится к стандартному виду.
  String _normalizeKey(String raw, String label, void Function(String) warn) {
    var key = raw.replaceAll(RegExp(r'\s+'), '');
    if (key.contains('-') || key.contains('_')) {
      key = key.replaceAll('-', '+').replaceAll('_', '/');
      warn('$label: URL-safe base64 нормализован в стандартный');
    }
    key = key.replaceAll('=', '');
    if (key.length != 43) {
      throw WGConfigParseException(
        '$label: ожидается 44 символа base64 (32 байта), '
        'получено ${raw.length}',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9+/]{43}$').hasMatch(key)) {
      throw WGConfigParseException('$label: некорректные символы в ключе');
    }
    try {
      final bytes = base64Decode('$key=');
      if (bytes.length != 32) {
        throw WGConfigParseException(
            '$label: после декодирования ${bytes.length} байт вместо 32');
      }
    } on FormatException {
      throw WGConfigParseException('$label: не декодируется как base64');
    }
    return '$key=';
  }

  /// Секреты не должны попадать в экспортируемый лог.
  String _maskForLog(String rawKey, String lowerKey, String value) {
    if (lowerKey.contains('privatekey') ||
        lowerKey.contains('presharedkey') ||
        lowerKey.contains('publickey')) {
      return '$rawKey = <${value.length} симв.> (скрыто)';
    }
    return '$rawKey = $value';
  }
}
