import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/awg_native_service.dart';

const privKey = 'OoPQOygvr6vRHqDzqrSCteBjaa14F5VM9MCoz5LqBmw=';
const pubKey = 'ecPuWHYBo1WLxayEOHefrKY+2qEzTAv/f4t8KbMfd9g=';

const amneziaConf = '''
[Interface]
PrivateKey = $privKey
Address = 10.66.66.2/32
DNS = 8.8.8.8
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
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 45.76.12.34:443
PersistentKeepalive = 25
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.local.vpnservice/awg');
  final calls = <MethodCall>[];
  Map<String, Object?>? connectReply;
  Object? connectError;

  setUp(() {
    calls.clear();
    connectReply = {'state': 'up', 'rx': 0, 'tx': 0, 'version': 'awg-1.0'};
    connectError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'prepare':
          return true;
        case 'connect':
          if (connectError != null) {
            throw PlatformException(code: 'connect', message: '$connectError');
          }
          return connectReply;
        case 'disconnect':
          return {'state': 'down'};
        case 'getStatus':
          return {'state': 'up', 'rx': 100, 'tx': 50};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('AwgNativeService payload', () {
    test('содержит все поля и amnezia-параметры', () {
      const parser = WGConfigParser();
      final cfg = parser.parse(amneziaConf, fallbackName: 'warp');
      final payload = AwgNativeService.payloadFor(cfg);

      expect(payload['privateKey'], privKey);
      expect(payload['publicKey'], pubKey);
      expect(payload['endpoint'], '45.76.12.34:443');
      expect(payload['addresses'], ['10.66.66.2/32']);
      expect(payload['allowedIps'], ['0.0.0.0/0', '::/0']);
      expect(payload['keepalive'], 25);
      expect(payload['dns'], ['8.8.8.8']);

      final amn = payload['amnezia'] as Map<String, String>;
      expect(amn['jc'], '6');
      expect(amn['jmin'], '40');
      expect(amn['jmax'], '1200');
      expect(amn['h1'], '1104220836');
      expect(amn['h2'], '2600550896');
      expect(amn['h3'], '3367297924');
      expect(amn['h4'], '1316139190');
      expect(amn['s1'], '1194');
      expect(amn['s2'], '1188');
    });

    test('connect() передаёт payload в MethodChannel', () async {
      const parser = WGConfigParser();
      final cfg = parser.parse(amneziaConf, fallbackName: 'warp');
      final service = AwgNativeService();
      addTearDown(service.dispose);

      final status = await service.connect(cfg);

      expect(status.up, isTrue);
      final connect = calls.firstWhere((c) => c.method == 'connect');
      // StandardMessageCodec декодирует в Map<Object?, Object?>
      final args = Map<Object?, Object?>.from(connect.arguments as Map);
      expect(args['privateKey'], privKey);
      expect(args['name'], 'warp');
      final amn = Map<Object?, Object?>.from(args['amnezia'] as Map);
      expect(amn['jc'], '6', reason: 'обфускация должна дойти до нативного слоя');
      expect(amn['h4'], '1316139190');
    });

    test('prepare() возвращает true при выданном разрешении', () async {
      final service = AwgNativeService();
      addTearDown(service.dispose);
      expect(await service.prepare(), isTrue);
      expect(calls.first.method, 'prepare');
    });

    test('getStatus() читает rx/tx', () async {
      final service = AwgNativeService();
      addTearDown(service.dispose);
      final st = await service.getStatus();
      expect(st.up, isTrue);
      expect(st.rx, 100);
      expect(st.tx, 50);
    });

    test('disconnect() переводит статус в down', () async {
      final service = AwgNativeService();
      addTearDown(service.dispose);
      final st = await service.disconnect();
      expect(st.up, isFalse);
    });

    test('connect() пробрасывает нативную ошибку', () async {
      connectError = 'DNS_RESOLUTION_FAILURE';
      const parser = WGConfigParser();
      final cfg = parser.parse(amneziaConf);
      final service = AwgNativeService();
      addTearDown(service.dispose);

      await expectLater(service.connect(cfg),
          throwsA(isA<PlatformException>()));
    });

    test('plain WG без amnezia — ключ amnezia отсутствует', () {
      const plain = '''
[Interface]
PrivateKey = $privKey
Address = 10.0.0.2/32

[Peer]
PublicKey = $pubKey
Endpoint = 1.2.3.4:51820
''';
      const parser = WGConfigParser();
      final cfg = parser.parse(plain);
      final payload = AwgNativeService.payloadFor(cfg);
      expect(payload.containsKey('amnezia'), isFalse);
      expect(cfg.hasAmnezia, isFalse);
    });

    test('AwgStatus читает пакеты, handshake и endpoint (диагностика)', () {
      final status = AwgStatus.fromMap(<Object?, Object?>{
        'state': 'up',
        'rx': 1024,
        'tx': 2048,
        'rxPackets': 11,
        'txPackets': 22,
        'lastHandshake': 1700000000000,
        'endpoint': '162.159.192.1:2408',
        'version': 'awg-2.3.7',
      });
      expect(status.up, isTrue);
      expect(status.rxPackets, 11);
      expect(status.txPackets, 22);
      expect(status.lastHandshakeMs, 1700000000000);
      expect(status.endpoint, '162.159.192.1:2408');
    });
  });
}
