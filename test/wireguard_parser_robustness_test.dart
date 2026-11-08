import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';

const privKey = 'OoPQOygvr6vRHqDzqrSCteBjaa14F5VM9MCoz5LqBmw=';
const pubKey = 'ecPuWHYBo1WLxayEOHefrKY+2qEzTAv/f4t8KbMfd9g=';

void main() {
  const parser = WGConfigParser();

  group('устойчивый разбор .conf', () {
    test('AmneziaJc / amneziajc / jc нормализуются в jc', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32
AmneziaJc = 5
amneziajmin = 30
JC = 7

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.amnezia['jc'], '7');
      expect(cfg.amnezia['jmin'], '30');
    });

    test('inline-комментарии и BOM не мешают', () {
      final conf = '\uFEFF[Interface]\n'
          'PrivateKey = $privKey # ключ\n'
          'Address = 10.0.0.2/32 ; WARP\n'
          '\n[Peer]\n'
          'PublicKey = $pubKey\n'
          'Endpoint = engage.cloudflareclient.com:2408\n';
      final cfg = parser.parse(conf);
      expect(cfg.privateKey, privKey);
      expect(cfg.addresses, ['10.0.0.2/32']);
      expect(cfg.endpointHost, 'engage.cloudflareclient.com');
    });

    test('ключ без padding и URL-safe алфавит принимаются', () {
      final unpadded = privKey.replaceAll('=', '');
      final conf = '''
[Interface]
PrivateKey = $unpadded
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.privateKey, privKey);
    });

    test('неизвестная секция — предупреждение, разбор продолжается', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[WireGuard]
Foo = bar

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.warnings.any((w) => w.contains('неизвестная секция')),
          isTrue);
      expect(cfg.privateKey, privKey);
    });

    test('несколько [Peer] — используется первый', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820

[Peer]
PublicKey = $pubKey
Endpoint = 5.6.7.8:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.endpointHost, '1.2.3.4');
      expect(cfg.warnings.any((w) => w.contains('несколько секций')), isTrue);
    });

    test('Endpoint без порта — 51820 + предупреждение', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
Endpoint = vpn.example.com
''';
      final cfg = parser.parse(conf);
      expect(cfg.endpointPort, 51820);
      expect(cfg.warnings.any((w) => w.contains('нет порта')), isTrue);
    });

    test('некорректный порт — ошибка', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
Endpoint = vpn.example.com:abc
''';
      expect(() => parser.parse(conf),
          throwsA(isA<WGConfigParseException>()));
    });

    test('лог не содержит приватных ключей', () {
      final log = <String>[];
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
PresharedKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      parser.parse(conf, logSink: log);
      final text = log.join('\n');
      expect(text, isNot(contains(privKey)));
      expect(text, isNot(contains(pubKey)));
      expect(text, contains('скрыто'));
      expect(text, contains('1.2.3.4:51820'));
    });

    test('неизвестный ключ — предупреждение, а не падение', () {
      final conf = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32
FancyOption = 42

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      final cfg = parser.parse(conf);
      expect(cfg.warnings.any((w) => w.contains('FancyOption')), isTrue);
    });
  });
}
