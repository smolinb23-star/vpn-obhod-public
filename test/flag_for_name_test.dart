import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/features/vpn/widgets/home_screen.dart';

void main() {
  group('flagForName', () {
    test('русские названия стран', () {
      expect(flagForName('Нидерланды'), '🇳🇱');
      expect(flagForName('Финляндия'), '🇫🇮');
      expect(flagForName('Германия'), '🇩🇪');
      expect(flagForName('США'), '🇺🇸');
    });

    test('английские названия и города', () {
      expect(flagForName('Finland'), '🇫🇮');
      expect(flagForName('Amsterdam'), '🇳🇱');
      expect(flagForName('Frankfurt'), '🇩🇪');
    });

    test('двухбуквенный код только отдельным токеном', () {
      expect(flagForName('NL-1'), '🇳🇱');
      expect(flagForName('us.example.com'), '🇺🇸');
      expect(flagForName('DE [Frankfurt]'), '🇩🇪');
    });

    test('BERLIN не превращается в Индию', () {
      expect(flagForName('BERLIN'), '🇩🇪');
    });

    test('неизвестное имя — глобус', () {
      expect(flagForName('server-42'), '🌐');
    });
  });
}
