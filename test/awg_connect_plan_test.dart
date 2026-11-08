import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/awg_connect_plan.dart';

const privKey = 'OoPQOygvr6vRHqDzqrSCteBjaa14F5VM9MCoz5LqBmw=';
const pubKey = 'ecPuWHYBo1WLxayEOHefrKY+2qEzTAv/f4t8KbMfd9g=';

String conf({String dns = 'DNS = 8.8.8.8', String endpoint = '1.2.3.4:51820'}) => '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32
$dns

[Peer]
PublicKey = $pubKey
Endpoint = $endpoint
''';

void main() {
  const parser = WGConfigParser();

  group('AwgConnectPlan', () {
    test('домен endpoint резолвится в IPv4 до туннеля', () async {
      final cfg = parser.parse(conf(endpoint: 'engage.cloudflareclient.com:2408'));
      final plan = await AwgConnectPlan.create(
        cfg,
        resolver: (host) async {
          expect(host, 'engage.cloudflareclient.com');
          return ['162.159.192.1', '2606:4700::1'];
        },
      );
      expect(plan.endpointResolved, isTrue);
      expect(plan.config.endpointHost, '162.159.192.1');
      expect(plan.config.endpointPort, 2408);
      expect(plan.notes.any((n) => n.contains('→ 162.159.192.1')), isTrue);
    });

    test('IP-endpoint не резолвится повторно', () async {
      final cfg = parser.parse(conf());
      var called = false;
      final plan = await AwgConnectPlan.create(
        cfg,
        resolver: (_) async {
          called = true;
          return ['9.9.9.9'];
        },
      );
      expect(called, isFalse);
      expect(plan.config.endpointHost, '1.2.3.4');
      expect(plan.endpointResolved, isFalse);
    });

    test('ошибка резолва не блокирует подключение', () async {
      final cfg = parser.parse(conf(endpoint: 'broken.example:51820'));
      final plan = await AwgConnectPlan.create(
        cfg,
        resolver: (_) async => throw StateError('dns down'),
      );
      expect(plan.config.endpointHost, 'broken.example');
      expect(plan.notes.any((n) => n.contains('резолв не удался')), isTrue);
    });

    test('пустой DNS заменяется на 1.1.1.1 / 1.0.0.1', () async {
      final cfg = parser.parse(conf(dns: ''));
      final plan = await AwgConnectPlan.create(cfg);
      expect(plan.dnsOverridden, isTrue);
      expect(plan.config.dns, AwgConnectPlan.defaultDns);
    });

    test('нерабочий DNS (0.0.0.0) заменяется', () async {
      final cfg = parser.parse(conf(dns: 'DNS = 0.0.0.0'));
      final plan = await AwgConnectPlan.create(cfg);
      expect(plan.config.dns, AwgConnectPlan.defaultDns);
    });

    test('валидный DNS сохраняется', () async {
      final cfg = parser.parse(conf(dns: 'DNS = 10.89.0.1, 1.1.1.1'));
      final plan = await AwgConnectPlan.create(cfg);
      expect(plan.dnsOverridden, isFalse);
      expect(plan.config.dns, ['10.89.0.1', '1.1.1.1']);
    });

    test('forceDefaultDns переопределяет даже валидный DNS', () async {
      final cfg = parser.parse(conf(dns: 'DNS = 8.8.8.8'));
      final plan =
          await AwgConnectPlan.create(cfg, forceDefaultDns: true);
      expect(plan.config.dns, AwgConnectPlan.defaultDns);
    });

    test('MTU из UI переопределяет .conf', () async {
      final cfg = parser.parse(conf());
      final plan = await AwgConnectPlan.create(cfg, mtu: 1420);
      expect(plan.mtu, 1420);
      expect(plan.config.mtu, 1420);
    });
  });
}
