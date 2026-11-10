import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/xray_tuning.dart';

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  const tuning = XrayTuning();

  test('добавляет TCP Fast Open и TCP_NODELAY в outbound', () {
    const input = '{"outbounds":[{"protocol":"vless",'
        '"streamSettings":{"network":"ws"}}]}';
    final map = _decode(tuning.apply(input));
    final outbound = (map['outbounds'] as List).first as Map<String, dynamic>;
    final stream = outbound['streamSettings'] as Map<String, dynamic>;
    final sockopt = stream['sockopt'] as Map<String, dynamic>;
    expect(sockopt['tcpFastOpen'], isTrue);
    expect(sockopt['tcpNoDelay'], isTrue);
  });

  test('включает XTLS Vision для VLESS Reality/TCP без flow', () {
    const input = '{"outbounds":[{"protocol":"vless",'
        '"settings":{"vnext":[{"users":[{"id":"u","encryption":"none"}]}]},'
        '"streamSettings":{"network":"tcp","security":"reality"}}]}';
    final map = _decode(tuning.apply(input));
    final outbound = (map['outbounds'] as List).first as Map<String, dynamic>;
    final vnext = ((outbound['settings'] as Map)['vnext'] as List).first
        as Map<String, dynamic>;
    final user = (vnext['users'] as List).first as Map<String, dynamic>;
    expect(user['flow'], XrayTuning.visionFlow);
  });

  test('не перетирает явно заданный flow', () {
    const input = '{"outbounds":[{"protocol":"vless",'
        '"settings":{"vnext":[{"users":[{"id":"u","flow":"none"}]}]},'
        '"streamSettings":{"network":"tcp","security":"reality"}}]}';
    final map = _decode(tuning.apply(input));
    final outbound = (map['outbounds'] as List).first as Map<String, dynamic>;
    final vnext = ((outbound['settings'] as Map)['vnext'] as List).first
        as Map<String, dynamic>;
    final user = (vnext['users'] as List).first as Map<String, dynamic>;
    expect(user['flow'], 'none');
  });

  test('добавляет быстрый DNS, если его нет', () {
    const input = '{"outbounds":[{"protocol":"freedom"}]}';
    final map = _decode(tuning.apply(input));
    final dns = map['dns'] as Map<String, dynamic>;
    expect(dns['servers'], XrayTuning.fastDns);
    expect(dns['queryStrategy'], 'UseIPv4');
  });

  test('не ломает конфиг без outbounds и невалидный JSON', () {
    expect(tuning.apply('not json'), 'not json');
    final map = _decode(tuning.apply('{"log":{}}'));
    expect(map['outbounds'], isNull);
  });
}
