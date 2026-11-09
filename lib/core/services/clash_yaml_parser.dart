import 'dart:convert';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:yaml/yaml.dart';

/// Ошибки разбора Clash YAML.
class ClashYamlParseException implements Exception {
  const ClashYamlParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Парсер Clash YAML конфигураций.
///
/// Ожидаемая структура (для AmneziaWG):
///   proxies:
///     - name: "Амнезия"
///       type: wireguard  # или amneziawg
///       server: 1.2.3.4
///       port: 51820
///       private-key: <base64>
///       public-key: <base64>
///       amnezia-wg-option:
///         Jc: "128"
///         Jmin: "16"
///         Jmax: "32"
///         S1: "0"
///         S2: "0"
///         H1: "1"
///         H2: "2"
///         H3: "3"
///         H4: "4"
///         I1: "abc..."
///         I2: "def..."
///         I3: "ghi..."
///         I4: "jkl..."
///         I5: "mno..."
///
/// Для MASQUE:
///   proxies:
///     - name: "Masque"
///       type: masque
///       server: example.com
///       port: 443
class ClashYamlParser {
  const ClashYamlParser();

  /// Быстрая проверка, что текст похож на Clash YAML.
  static bool looksLikeClashYaml(String content) {
    final t = content.trim();
    return t.startsWith('proxies:') ||
        RegExp(r'^proxies\s*:', multiLine: true).hasMatch(t) ||
        (t.startsWith('{') && t.contains('"proxies"'));
  }

  /// Разбирает Clash YAML и возвращает список VpnConfig.
  ///
  /// Для AmneziaWG-прокси (type wireguard/amneziawg с private-key/public-key)
  /// конвертирует в WireGuardConfig → VpnConfig (wireguard протокол).
  /// Для type: masque возвращает конфиг с пометкой, что требуется Sing-box.
  List<VpnConfig> parse(String content) {
    final log = <String>[];
    final warnings = <String>[];

    void emit(String message) {
      log.add(message);
      appLog.info('ClashYamlParser', message);
    }

    void warn(String message) {
      warnings.add(message);
      emit('WARN $message');
    }

    final yaml = loadYaml(content) as YamlMap?;
    if (yaml == null) {
      throw const ClashYamlParseException('Не удалось разобрать YAML');
    }

    final proxiesNode = yaml['proxies'];
    if (proxiesNode == null || proxiesNode is! YamlList) {
      throw const ClashYamlParseException('YAML без секции proxies');
    }

    final result = <VpnConfig>[];
    for (var i = 0; i < proxiesNode.length; i++) {
      final proxy = proxiesNode[i];
      if (proxy is! YamlMap) continue;

      final type = (proxy['type'] ?? '').toString().toLowerCase();
      final name = (proxy['name'] ?? 'Proxy $i').toString();

      emit('$i: тип=$type, имя=$name');

      if (type == 'masque') {
        result.add(VpnConfig(
          remark: name,
          protocol: ProfileProtocol.other,
          xrayJson: jsonEncode(<String, dynamic>{
            'log': <String, dynamic>{'loglevel': 'warning'},
            'outbounds': <dynamic>[
              <String, dynamic>{
                'tag': 'proxy',
                'protocol': 'masque',
                'settings': <String, dynamic>{
                  'server': proxy['server'] ?? '',
                  'port': (proxy['port'] as num?)?.toInt() ?? 443,
                },
              },
            ],
          }),
          stream: '',
          security: '',
          host: proxy['server']?.toString() ?? '',
        ));
        continue;
      }

      // AmneziaWG / WireGuard через Clash YAML
      if (type != 'wireguard' && type != 'amneziawg') {
        warn('$i: неизвестный тип "$type" — пропущен');
        continue;
      }

      final wg = _toWireGuard(proxy, i, warn);
      if (wg == null) continue;

      result.add(VpnConfig(
        remark: wg.name,
        protocol: ProfileProtocol.wireguard,
        xrayJson: wg.toXrayJson(),
        stream: 'wireguard',
        security: 'none',
        host: wg.endpointHost,
      ));
    }

    if (result.isEmpty) {
      throw const ClashYamlParseException(
        'Не найдено ни одного подходящего прокси в YAML. '
        'Поддерживаются wireguard/amneziawg; для VLESS добавьте vless:// ссылку.',
      );
    }

    emit('Разбор завершён: ${result.length} прокси, ${warnings.length} предупреждений');
    return result;
  }

  /// Возвращает все WireGuard/AmneziaWG-прокси Clash YAML как [WireGuardConfig].
  ///
  /// Используется реальным путём подключения (нативный AwgBridge). Для
  /// wireguard без `address` подставляется WARP-адрес 172.16.0.2/32.
  List<WireGuardConfig> parseWireGuardConfigs(String content) {
    final yaml = loadYaml(content) as YamlMap?;
    if (yaml == null) {
      throw const ClashYamlParseException('Не удалось разобрать YAML');
    }
    final proxiesNode = yaml['proxies'];
    if (proxiesNode == null || proxiesNode is! YamlList) {
      throw const ClashYamlParseException('YAML без секции proxies');
    }

    final result = <WireGuardConfig>[];
    for (var i = 0; i < proxiesNode.length; i++) {
      final proxy = proxiesNode[i];
      if (proxy is! YamlMap) continue;
      final type = (proxy['type'] ?? '').toString().toLowerCase();
      if (type != 'wireguard' && type != 'amneziawg') continue;
      final wg = _toWireGuard(proxy, i, (m) => appLog.warn('ClashYamlParser', m));
      if (wg != null) result.add(wg);
    }
    return result;
  }

  /// Минимальный YAML (JSON) только с одним прокси по имени.
  ///
  /// Нужен, чтобы сохранять каждый сервер Clash как отдельный профиль,
  /// не теряя привязку к имени/флагу страны.
  static String? proxyYamlByName(String content, String name) {
    final yaml = loadYaml(content) as YamlMap?;
    final proxiesNode = yaml?['proxies'];
    if (proxiesNode is! YamlList) return null;
    for (final proxy in proxiesNode) {
      if (proxy is! YamlMap) continue;
      if ((proxy['name'] ?? '').toString() != name) continue;
      return jsonEncode(<String, dynamic>{
        'proxies': <dynamic>[_deepMap(proxy)],
      });
    }
    return null;
  }

  WireGuardConfig? _toWireGuard(
    YamlMap proxy,
    int i,
    void Function(String) warn,
  ) {
    final server = proxy['server']?.toString();
    final port = (proxy['port'] as num?)?.toInt();
    final privateKey = proxy['private-key']?.toString() ??
        proxy['privatekey']?.toString() ??
        proxy['private_key']?.toString();
    final publicKey = proxy['public-key']?.toString() ??
        proxy['publickey']?.toString() ??
        proxy['public_key']?.toString();

    if (server == null || server.isEmpty) {
      warn('$i: нет server — пропущен');
      return null;
    }
    if (port == null || port <= 0 || port > 65535) {
      warn('$i: некорректный порт — пропущен');
      return null;
    }
    if (privateKey == null || privateKey.isEmpty) {
      warn('$i: нет private-key — пропущен');
      return null;
    }
    if (publicKey == null || publicKey.isEmpty) {
      warn('$i: нет public-key — пропущен');
      return null;
    }

    // amnezia-wg-option блок
    final amnezia = <String, String>{};
    final amneziaNode = proxy['amnezia-wg-option'];
    if (amneziaNode is YamlMap) {
      for (final entry in amneziaNode.entries) {
        amnezia[entry.key.toString()] = entry.value.toString();
      }
    }

    // Address: Clash использует ip/ipv6, некоторые сборки — address.
    final addresses = <String>[];
    for (final key in const ['address', 'ip', 'ipv6']) {
      final raw = proxy[key]?.toString();
      if (raw == null || raw.isEmpty) continue;
      addresses.addAll(_splitList(raw));
    }
    if (addresses.isEmpty) {
      addresses.add('172.16.0.2/32');
    }

    final allowedIps = _splitList(
      proxy['allowed-ips']?.toString() ?? proxy['allowedips']?.toString(),
    );
    final dns = _splitList(
      proxy['dns']?.toString() ?? proxy['dns-servers']?.toString(),
    );
    final mtu = (proxy['mtu'] as num?)?.toInt();
    final psk = proxy['psk']?.toString() ??
        proxy['pre-shared-key']?.toString() ??
        proxy['preshared-key']?.toString();

    return WireGuardConfig(
      name: (proxy['name'] ?? 'Proxy $i').toString(),
      privateKey: privateKey,
      addresses: addresses,
      peerPublicKey: publicKey,
      peerPresharedKey: (psk == null || psk.isEmpty) ? null : psk,
      endpointHost: server,
      endpointPort: port,
      allowedIps: allowedIps.isEmpty
          ? const <String>['0.0.0.0/0', '::/0']
          : allowedIps,
      dns: dns,
      mtu: (mtu != null && mtu > 0) ? mtu : null,
      amnezia: amnezia,
    );
  }

  static Map<String, dynamic> _deepMap(YamlMap map) {
    final out = <String, dynamic>{};
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is YamlMap) {
        out[entry.key.toString()] = _deepMap(value);
      } else if (value is YamlList) {
        out[entry.key.toString()] = value
            .map((e) => e is YamlMap ? _deepMap(e) : e)
            .toList(growable: false);
      } else {
        out[entry.key.toString()] = value;
      }
    }
    return out;
  }

  List<String> _splitList(String? value) {
    if (value == null || value.isEmpty) return <String>[];
    return value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// Проверяет, является ли VpnConfig маскарад-конфигом (требует Sing-box).
  static bool isMasque(VpnConfig config) {
    try {
      final map = config.xrayMap;
      final outbounds = map['outbounds'] as List<dynamic>?;
      if (outbounds == null || outbounds.isEmpty) return false;
      final first = outbounds.first as Map<String, dynamic>?;
      return first?['protocol'] == 'masque';
    } on Object {
      return false;
    }
  }
}
