import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/features/vpn/services/awg_i1_presets.dart';

void main() {
  group('AwgI1Preset', () {
    test('все пресеты проходят валидацию', () {
      for (final preset in AwgI1Preset.all) {
        expect(AwgI1Preset.validate(preset.value), isNull,
            reason: preset.label);
      }
    });

    test('пустая строка допустима', () {
      expect(AwgI1Preset.validate(''), isNull);
    });

    test('отбрасывает нечётный hex', () {
      expect(AwgI1Preset.validate('<b 0x123>'), isNotNull);
    });

    test('отбрасывает неизвестный тег', () {
      expect(AwgI1Preset.validate('<foo>'), isNotNull);
    });

    test('отбрасывает N = 0', () {
      expect(AwgI1Preset.validate('<r 0>'), isNotNull);
    });

    test('отбрасывает незакрытый тег', () {
      expect(AwgI1Preset.validate('<r 32'), isNotNull);
    });

    test('match находит пресеты', () {
      expect(AwgI1Preset.match(AwgI1Preset.dns.value)?.id, 'dns');
      expect(AwgI1Preset.match('custom stuff'), isNull);
    });

    test('DNS-пресет содержит чётный hex', () {
      final value = AwgI1Preset.dns.value;
      final hex = RegExp(r'0x([0-9a-fA-F]+)').firstMatch(value)!.group(1)!;
      expect(hex.length.isEven, isTrue);
    });
  });
}
