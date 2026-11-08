import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';

/// Валидные 44-символьные ключи (канонический base64 от 32 байт).
const privKey = 'OoPQOygvr6vRHqDzqrSCteBjaa14F5VM9MCoz5LqBmw=';
const pubKey = 'ecPuWHYBo1WLxayEOHefrKY+2qEzTAv/f4t8KbMfd9g=';
const pskKey = 'cowoq1NXEhk0SeAHAuBn9XbB1CaknmXq8EotvTRosaw=';

const basicConf = '''
[Interface]
PrivateKey = $privKey
Address = 10.89.0.2/32
DNS = 10.89.0.1
MTU = 1420

[Peer]
PublicKey = $pubKey
PresharedKey = $pskKey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = warp.example.com:51820
PersistentKeepalive = 25
''';

const amneziaConf = '''
[Interface]
PrivateKey = $privKey
Address = 10.66.66.2/32
DNS = 8.8.8.8, 8.8.4.4
Jc = 6
Jmin = 40
Jmax = 1200
H1 = 1104220836
H2 = 2600550896
H3 = 3367297924
H4 = 1316139190
S1 = 1194
S2 = 1188

[Peer]
PublicKey = $pubKey
AllowedIPs = 0.0.0.0/0, ::/0, 10.66.66.0/24
Endpoint = 45.76.12.34:443
PersistentKeepalive = 25
''';

void main() {
  const parser = WGConfigParser();

  group('looksLikeWireGuardConf', () {
    test('распознаёт стандартный WG-конф', () {
      expect(WGConfigParser.looksLikeWireGuardConf(basicConf), isTrue);
    });

    test('распознаёт AmneziaWG-конф', () {
      expect(WGConfigParser.looksLikeWireGuardConf(amneziaConf), isTrue);
    });

    test('не распознаёт vless-ссылку', () {
      expect(
        WGConfigParser.looksLikeWireGuardConf(
            'vless://uuid@host:443?security=reality#x'),
        isFalse,
      );
    });

    test('не распознаёт конфиг без секций', () {
      expect(
        WGConfigParser.looksLikeWireGuardConf('PrivateKey = $privKey'),
        isFalse,
      );
    });
  });

  group('parse', () {
    test('базовый конфиг: все поля', () {
      final cfg = parser.parse(basicConf, fallbackName: 'warp');
      expect(cfg.name, 'warp');
      expect(cfg.privateKey, privKey);
      expect(cfg.peerPublicKey, pubKey);
      expect(cfg.peerPresharedKey, pskKey);
      expect(cfg.endpointHost, 'warp.example.com');
      expect(cfg.endpointPort, 51820);
      expect(cfg.addresses, ['10.89.0.2/32']);
      expect(cfg.allowedIps, ['0.0.0.0/0', '::/0']);
      expect(cfg.dns, ['10.89.0.1']);
      expect(cfg.mtu, 1420);
      expect(cfg.persistentKeepalive, 25);
      expect(cfg.hasAmnezia, isFalse);
    });

    test('Amnezia-расширения сохраняются', () {
      final cfg = parser.parse(amneziaConf);
      expect(cfg.hasAmnezia, isTrue);
      expect(cfg.amnezia['jc'], '6');
      expect(cfg.amnezia['jmin'], '40');
      expect(cfg.amnezia['jmax'], '1200');
      expect(cfg.amnezia['h1'], '1104220836');
      expect(cfg.amnezia['s1'], '1194');
      expect(cfg.amnezia['s2'], '1188');
    });

    test('IPv6-endpoint в скобках', () {
      final conf = basicConf.replaceFirst(
          'Endpoint = warp.example.com:51820', 'Endpoint = [2001:db8::1]:51820');
      final cfg = parser.parse(conf);
      expect(cfg.endpointHost, '2001:db8::1');
      expect(cfg.endpointPort, 51820);
    });

    test('CRLF и комментарии игнорируются', () {
      final conf = '# экспорт WARP\r\n${basicConf.replaceAll('\n', '\r\n')}\r\n';
      final cfg = parser.parse(conf);
      expect(cfg.privateKey, privKey);
      expect(cfg.endpointPort, 51820);
    });

    test('регистр ключей и секций не важен', () {
      final conf = '''
[interface]
privatekey = $privKey
address = 10.0.0.2/32

[peer]
publickey = $pubKey
endpoint = 1.2.3.4:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.privateKey, privKey);
      expect(cfg.allowedIps, ['0.0.0.0/0', '::/0']); // default
      expect(cfg.persistentKeepalive, 25); // default
    });

    test('без PrivateKey — ошибка', () {
      final conf = basicConf.replaceFirst(RegExp(r'PrivateKey = .*\n'), '');
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });

    test('без Endpoint — ошибка', () {
      final conf = basicConf.replaceFirst(RegExp(r'Endpoint = .*\n'), '');
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });

    test('без Address — ошибка (Xray не поднимет туннель)', () {
      final conf = basicConf.replaceFirst(RegExp(r'Address = .*\n'), '');
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });

    test('битый ключ — ошибка валидации', () {
      final conf = basicConf.replaceFirst(privKey, 'short-key');
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });

    test('некорректный порт — ошибка', () {
      final conf =
          basicConf.replaceFirst('warp.example.com:51820', 'warp.example.com:abc');
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });
  });

  group('toXrayJson', () {
    test('генерирует wireguard-outbound в формате Xray', () {
      final cfg = parser.parse(basicConf, fallbackName: 'warp');
      final json = jsonDecode(cfg.toXrayJson()) as Map<String, dynamic>;

      final outbounds = json['outbounds'] as List;
      expect(outbounds, hasLength(1));
      final out = outbounds.first as Map<String, dynamic>;
      expect(out['protocol'], 'wireguard');
      expect(out['tag'], 'proxy');

      final settings = out['settings'] as Map<String, dynamic>;
      expect(settings['secretKey'], privKey);
      expect(settings['address'], ['10.89.0.2/32']);
      expect(settings['remoteDNS'], ['10.89.0.1']);
      expect(settings['mtu'], 1420);

      final peer = (settings['peers'] as List).first as Map<String, dynamic>;
      expect(peer['publicKey'], pubKey);
      expect(peer['preSharedKey'], pskKey);
      expect(peer['endpoint'], 'warp.example.com:51820');
      expect(peer['allowedIPs'], ['0.0.0.0/0', '::/0']);
      expect(peer['keepAlive'], 25);
    });

    test('inbounds отсутствуют (VPN-режим flutter_vless)', () {
      final cfg = parser.parse(basicConf);
      final json = jsonDecode(cfg.toXrayJson()) as Map<String, dynamic>;
      expect(json.containsKey('inbounds'), isFalse);
    });
  });

  group('toVpnConfig', () {
    test('протокол wireguard, security отражает Amnezia', () {
      final plain = parser.toVpnConfig(parser.parse(basicConf));
      expect(plain.protocol, ProfileProtocol.wireguard);
      expect(plain.stream, 'wireguard');
      expect(plain.security, 'none');
      expect(plain.host, 'warp.example.com');

      final amn = parser.toVpnConfig(parser.parse(amneziaConf));
      expect(amn.security, 'amnezia');
    });

    test('importConf — полный путь от текста до профиля', () {
      final profile = parser.importConf(amneziaConf, fallbackName: 'warp-amn');
      expect(profile.remark, 'warp-amn');
      expect(profile.protocol, ProfileProtocol.wireguard);
      // JSON должен пережить round-trip через VpnConfig.fromJson
      final restored = VpnConfig.fromJson(
          jsonDecode(profile.toJsonString()) as Map<String, dynamic>);
      expect(restored.protocol, ProfileProtocol.wireguard);
      expect(restored.xrayJson, profile.xrayJson);
    });
  });
}
