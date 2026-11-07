import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/config_validator.dart';

void main() {
  const validator = ConfigValidator();

  test('валидный конфиг без inbounds проходит (VPN-режим)', () {
    const json = '{"outbounds":[{"protocol":"vless","settings":{}}]}';
    expect(validator.validate(json), isEmpty);
  });

  test('inbounds на 0.0.0.0 отклоняется', () {
    const json = '{"inbounds":[{"tag":"s","listen":"0.0.0.0","port":1080,'
        '"protocol":"socks","settings":{"auth":"password"}}],'
        '"outbounds":[{"protocol":"vless"}]}';
    expect(validator.validate(json), isNotEmpty);
  });

  test('SOCKS без auth отклоняется', () {
    const json = '{"inbounds":[{"tag":"s","listen":"127.0.0.1","port":1080,'
        '"protocol":"socks","settings":{}}],'
        '"outbounds":[{"protocol":"vless"}]}';
    final errors = validator.validate(json);
    expect(errors.any((e) => e.contains('auth')), isTrue);
  });

  test('SOCKS noauth отклоняется', () {
    const json = '{"inbounds":[{"tag":"s","listen":"127.0.0.1","port":1080,'
        '"protocol":"socks","settings":{"auth":"noauth"}}],'
        '"outbounds":[{"protocol":"vless"}]}';
    expect(validator.validate(json), isNotEmpty);
  });

  test('валидный loopback-SOCKS с password проходит', () {
    const json = '{"inbounds":[{"tag":"s","listen":"127.0.0.1","port":1080,'
        '"protocol":"socks","settings":{"auth":"password"}}],'
        '"outbounds":[{"protocol":"vless"}]}';
    expect(validator.validate(json), isEmpty);
  });

  test('пустой список outbounds отклоняется', () {
    const json = '{"outbounds":[]}';
    expect(validator.validate(json), isNotEmpty);
  });

  test('битый JSON отклоняется', () {
    expect(validator.validate('{oops'), isNotEmpty);
  });

  test('validateOrThrow бросает исключение', () {
    expect(
      () => validator.validateOrThrow('{"inbounds":[]}'),
      throwsA(isA<ConfigValidationException>()),
    );
  });
}
