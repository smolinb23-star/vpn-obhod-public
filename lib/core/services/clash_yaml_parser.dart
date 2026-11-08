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

/**
 * Парсер Clash YAML конфигураций.
 *
 * Ожидаемая структура (для AmneziaWG):
 *   proxies:
 *     - name: "Амнезия"
 *       type: wireguard  # или amneziawg
 *       server: 1.2.3.4
 *       port: 51820
 *       private-key: <base64>
 *       public-key: <base64>
 *       amnezia-wg-option:
 *         Jc: "128"
 *         Jmin: "16"
 *         Jmax: "32"
 *         S1: "0"
 *         S2: "0"
 *         H1: "1"
 *         H2: "2"
 *         H3: "3"
 *         H4: "4"
 *         I1: "abc..."
 *         I2: "def..."
 *         I3: "ghi..."
 *         I4: "jkl..."
 *         I5: "mno..."
 *
 * Для MASQUE:
 *   proxies:
 *     - name: "Masque"
 *       type: masque
 *       server: example.com
 *       port: 443
 */
class ClashYamlParser {
  const ClashYamlParser();

  /// Быстрая проверка, что текст похож на Clash YAML.
  static bool looksLikeClashYaml(String content) {
    final t = content.trim();
    return t.startsWith('proxies:') ||
        RegExp(r'^proxies\s*:', multiLine: true).hasMatch(t);
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
          _masqueUnsupported: true,
        ));
        continue;
      }

      // AmneziaWG / WireGuard через Clash YAML
      if (type != 'wireguard' && type != 'amneziawg') {
        warn('$i: неизвестный тип "$type" — пропущен');
        continue;
      }

      final server = proxy['server']?.toString();
      final port = (proxy['port'] as num?)?.toInt();
      final privateKey = proxy['private-key']?.toString();
      final publicKey = proxy['public-key']?.toString();

      if (server == null || server.isEmpty) {
        warn('$i: нет server — пропущен');
        continue;
      }
      if (port == null || port <= 0 || port > 65535) {
        warn('$i: некорректный порт — пропущен');
        continue;
      }
      if (privateKey == null || privateKey.isEmpty) {
        warn('$i: нет private-key — пропущен');
        continue;
      }
      if (publicKey == null || publicKey.isEmpty) {
        warn('$i: нет public-key — пропущен');
        continue;
      }

      // amnezia-wg-option блок
      final amnezia = <String, String>{};
      final amneziaNode = proxy['amnezia-wg-option'];
      if (amneziaNode is YamlMap) {
        for (final entry in amneziaNode.entries) {
          final key = entry.key.toString();
          final value = entry.value.toString();
          amnezia[key] = value;
        }
      }

      // Address — для AmneziaWG обычно не обязателен в Clash, подставляем
      // локальный адрес из конфига или 10.0.0.2/32
      final address = proxy['address']?.toString() ?? '10.0.0.2/32';

      final allowedIps = proxy['allowed-ips']?.toString() ??
          proxy['allowedips']?.toString() ??
          '0.0.0.0/0, ::/0';

      final dns = proxy['dns']?.toString() ??
          proxy['dns-servers']?.toString() ??
          '';

      final mtu = (proxy['mtu'] as num?)?.toInt();

      final wgConfig = WireGuardConfig(
        name: name,
        privateKey: privateKey,
        addresses: _splitList(address),
        peerPublicKey: publicKey,
        endpointHost: server,
        endpointPort: port,
        allowedIps: _splitList(allowedIps),
        dns: _splitList(dns),
        mtu: mtu,
        amnezia: amnezia,
        warnings: List<String>.unmodifiable(warnings),
      );

      result.add(wgConfig.toVpnConfig());
    }

    if (result.isEmpty) {
      throw const ClashYamlParseException(
        'Не найдено ни одного подходящего прокси в YAML',
      );
    }

    emit('Разбор завершён: ${result.length} прокси, ${warnings.length} предупреждений');
    return result;
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
