import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/features/bypass/bypass_method.dart';
import 'package:vpn_service/features/vpn/services/health_monitor.dart';

void main() {
  group('HealthMonitor', () {
    test('Degraded после 3 замеров RTT > 300 мс', () async {
      final monitor = HealthMonitor(
        sampler: () async => const MethodHealth(alive: true, rttMs: 400),
        dwellTime: Duration.zero,
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, TunnelHealth.unknown,
          reason: 'гистерезис 3 замера ещё не набран');

      await monitor.tick();
      expect(monitor.state, TunnelHealth.degraded);
    });

    test('потери > 2% тоже дают Degraded', () async {
      final monitor = HealthMonitor(
        sampler: () async =>
            const MethodHealth(alive: true, rttMs: 50, lossRatio: 0.25),
        dwellTime: Duration.zero,
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, TunnelHealth.degraded);
    });

    test('Dead после 3 фейлов подряд, dwell игнорируется', () async {
      var calls = 0;
      final monitor = HealthMonitor(
        sampler: () async {
          calls++;
          return calls <= 2
              ? const MethodHealth(alive: true, rttMs: 50)
              : const MethodHealth(alive: false);
        },
        dwellTime: const Duration(minutes: 5),
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, TunnelHealth.dead);
    });

    test('успешный замер сбрасывает серию dead', () async {
      var calls = 0;
      final monitor = HealthMonitor(
        sampler: () async {
          calls++;
          if (calls == 1 || calls == 2) {
            return const MethodHealth(alive: false);
          }
          return const MethodHealth(alive: true, rttMs: 40);
        },
        dwellTime: Duration.zero,
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, isNot(TunnelHealth.dead));
    });

    test('dwell time задерживает переход в degraded', () async {
      var now = DateTime(2026, 1, 1, 12);
      var rtt = 40;
      final monitor = HealthMonitor(
        sampler: () async => MethodHealth(alive: true, rttMs: rtt),
        dwellTime: const Duration(minutes: 5),
        clock: () => now,
      );
      addTearDown(monitor.dispose);

      // unknown → healthy после 3 хороших замеров (dwell ещё не стартовал).
      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, TunnelHealth.healthy);

      // 3 плохих замера в тот же момент времени: dwell блокирует degraded.
      rtt = 500;
      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      expect(monitor.state, TunnelHealth.healthy);

      // Через 6 минут dwell истёк — переход разрешён.
      now = now.add(const Duration(minutes: 6));
      await monitor.tick();
      expect(monitor.state, TunnelHealth.degraded);
    });
  });
}
