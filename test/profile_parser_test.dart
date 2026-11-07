import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/models/vpn_config.dart';

void main() {
  const parser = ProfileParser();

  group('ProfileParser.parseOne — VLESS', () {
    test('vless reality + xhttp', () {
      final link = 'vless://11111111-2222-3333-4444-555555555555'
          '@45.61.100.5:443'
          '?encryption=none&flow=xtls-rprx-vision&security=reality'
          '&sni=www.microsoft.com&pbk=abcPubKey&sid=deadbeef&fp=chrome'
          '&type=xhttp&path=%2Fdownload&mode=auto#Мой%20сервер';
      final config = parser.parseOne(link);

      expect(config.protocol, ProfileProtocol.vless);
      expect(config.remark, 'Мой сервер');
      expect(config.security, 'reality');
      expect(config.stream, 'xhttp');
      expect(config.cdnFronted, isTrue); // фронт sni != IP сервера

      final map = config.xrayMap;
      final outbound =
          (map['outbounds'] as List).first as Map<String, dynamic>;
      expect(outbound['protocol'], 'vless');
      final vnext =
          ((outbound['settings'] as Map)['vnext'] as List).first
              as Map<String, dynamic>;
      expect(vnext['address'], '45.61.100.5');
      expect(vnext['port'], 443);
      final user = (vnext['users'] as List).first as Map<String, dynamic>;
      expect(user['id'], '11111111-2222-3333-4444-555555555555');
      expect(user['flow'], 'xtls-rprx-vision');

      final stream = outbound['streamSettings'] as Map<String, dynamic>;
      expect(stream['network'], 'xhttp');
      expect(stream['security'], 'reality');
      final reality = stream['realitySettings'] as Map<String, dynamic>;
      expect(reality['serverName'], 'www.microsoft.com');
      expect(reality['publicKey'], 'abcPubKey');
      expect(reality['shortId'], 'deadbeef');
      expect((stream['xhttp'] as Map)['path'], '/download');
    });

    test('vless без remark — генерируется имя', () {
      final link = 'vless://uuid1@1.2.3.4:8443?security=tls&sni=example.com';
      final config = parser.parseOne(link);
      expect(config.remark, contains('1.2.3.4'));
    });

    test('vless ws с host-заголовком', () {
      final link = 'vless://u@1.2.3.4:443?security=tls&type=ws'
          '&path=%2Fws&host=cdn.example.net&sni=cdn.example.net';
      final config = parser.parseOne(link);
      expect(config.stream, 'ws');
      expect(config.cdnFronted, isTrue);
    });
  });

  group('ProfileParser — Hysteria2', () {
    test('hysteria2:// разбирается', () {
      final link = 'hysteria2://secr3tPassword@203.0.113.7:443'
          '?sni=hidden.example.org&insecure=1#Hy2';
      final config = parser.parseOne(link);
      expect(config.protocol, ProfileProtocol.hysteria2);
      expect(config.remark, 'Hy2');
      final map = config.xrayMap;
      final outbound =
          (map['outbounds'] as List).first as Map<String, dynamic>;
      expect(outbound['protocol'], 'hysteria2');
    });

    test('hy2:// (короткая схема) разбирается', () {
      final link = 'hy2://pass@host.example:8443#quick';
      final config = parser.parseOne(link);
      expect(config.protocol, ProfileProtocol.hysteria2);
    });
  });

  group('ProfileParser — форматы', () {
    test('raw Xray JSON принимается', () {
      const json = '{"log":{},"outbounds":[{"tag":"proxy",'
          '"protocol":"vless","settings":{}}]}';
      final config = parser.parseOne(json);
      expect(config.protocol, ProfileProtocol.vless);
    });

    test('base64-подписка с несколькими ссылками', () {
      final lines = [
        'vless://u1@1.1.1.1:443?security=reality&pbk=k#A',
        'vless://u2@2.2.2.2:443?security=reality&pbk=k#B',
      ].join('\n');
      final sub = base64Encode(utf8.encode(lines));
      final all = parser.parseAll(sub);
      expect(all.length, 2);
      expect(all[0].remark, 'A');
      expect(all[1].remark, 'B');
    });

    test('неподдерживаемые ссылки пропускаются, если есть валидные', () {
      final input = 'trojan://x@1.1.1.1:443\nvless://u@2.2.2.2:443';
      final all = parser.parseAll(input);
      expect(all.length, 1);
    });

    test('пустой ввод — исключение', () {
      expect(() => parser.parseOne(''), throwsA(isA<ConfigParseException>()));
    });
  });
}
