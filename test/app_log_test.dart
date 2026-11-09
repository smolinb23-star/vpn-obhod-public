import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/core/services/app_log.dart';

void main() {
  group('AppLog', () {
    test('хранит только последние maxLines строк', () {
      final log = AppLog(maxLines: 3);
      for (var i = 0; i < 5; i++) {
        log.info('T', 'line $i');
      }
      expect(log.length, 3);
      expect(log.dump(), contains('line 4'));
      expect(log.dump(), isNot(contains('line 1')));
    });

    test('tail возвращает последние N', () {
      final log = AppLog(maxLines: 10);
      log.info('T', 'a');
      log.info('T', 'b');
      log.info('T', 'c');
      expect(log.tail(2).length, 2);
      expect(log.tail(2).last, contains('c'));
    });

    test('warn/error помечаются', () {
      final log = AppLog(maxLines: 10);
      log.warn('T', 'warning');
      log.error('T', 'failure');
      expect(log.dump(), contains('WARN warning'));
      expect(log.dump(), contains('ERROR failure'));
    });
  });
}
