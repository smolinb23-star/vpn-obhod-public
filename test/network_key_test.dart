import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';

void main() {
  group('NetworkKey', () {
    test('SSID имеет приоритет', () {
      expect(
        NetworkKey.build(const NetworkInfo(
          ssid: 'HomeWiFi',
          operatorName: 'MTS',
          mccMnc: '25001',
        )),
        'HomeWiFi',
      );
    });

    test('operator|mccmnc при отсутствии SSID', () {
      expect(
        NetworkKey.build(const NetworkInfo(
          ssid: '<unknown ssid>',
          operatorName: 'MTS',
          mccMnc: '25001',
        )),
        'MTS|25001',
      );
    });

    test('unknown, если данных нет', () {
      expect(NetworkKey.build(NetworkInfo.unknown), NetworkKey.unknown);
    });
  });

  group('NetworkInfo', () {
    test('парсит map из MethodChannel', () {
      final info = NetworkInfo.fromMap(<Object?, Object?>{
        'ssid': 'Cafe',
        'operator': 'Beeline',
        'mccMnc': '25099',
        'type': 'wifi',
      });
      expect(info.ssid, 'Cafe');
      expect(info.type, 'wifi');
    });
  });
}
