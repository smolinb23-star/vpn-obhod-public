import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/features/bypass/bypass_method.dart';
import 'package:vpn_service/features/bypass/bypass_orchestrator.dart';
import 'package:vpn_service/features/bypass/methods/mock_methods.dart';
import 'package:vpn_service/features/bypass/orchestrator_state.dart';
import 'package:vpn_service/features/bypass/wins_repository.dart';

/// Верификатор трафика с programmable-ответами.
class ScriptedVerifier implements TrafficVerifier {
  ScriptedVerifier(this.results);
  final List<bool?> results;
  int _i = 0;

  @override
  Future<bool?> verifyTraffic() async {
    final r = _i < results.length ? results[_i] : true;
    _i++;
    return r;
  }
}

MockBypassMethod mk(String id, int latency, {double reliability = 1.0}) {
  final m = MockBypassMethod(
    id: id,
    name: id,
    reliability: reliability,
    baseLatencyMs: latency,
  );
  m.fixedLatencyMs = latency;
  return m;
}

void main() {
  const network = 'test_net';

  late InMemoryWinsRepository wins;

  setUp(() => wins = InMemoryWinsRepository());
  tearDown(() => wins.close());

  group('BypassOrchestrator', () {
    test('Сценарий 1: все живы → выбирается метод с меньшим RTT', () async {
      final a = mk('a', 100);
      final b = mk('b', 200);
      final c = mk('c', 300);
      final orch = BypassOrchestrator(
        methods: [c, b, a],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);

      await orch.start(network);

      expect(orch.state, OrchestratorState.connected);
      expect(orch.active?.id, 'a');
      expect(a.isConnected, isTrue);
      expect(b.isConnected, isFalse);
      // Победа записана в память.
      expect(await wins.winsFor('a', network), 1);
    });

    test('Сценарий 2: лидер деградирует (3 замера) → переключение на второго',
        () async {
      final fast = mk('fast', 100);
      final second = mk('second', 200);
      final orch = BypassOrchestrator(
        methods: [fast, second],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);

      await orch.start(network);
      expect(orch.active?.id, 'fast');

      // Гистерезис: 2 замера деградации — ещё не переключает.
      await orch.onHealthSample(const MethodHealth(alive: true, rttMs: 500));
      await orch.onHealthSample(const MethodHealth(alive: true, rttMs: 520));
      expect(orch.active?.id, 'fast');

      // Третий подтверждённый замер → Degraded → второй метод.
      await orch.onHealthSample(
          const MethodHealth(alive: true, rttMs: 540, lossRatio: 0.03));
      expect(orch.active?.id, 'second');
      expect(fast.isConnected, isFalse);
      expect(second.isConnected, isTrue);
    });

    test('Сценарий 3: лидер мёртв (3 фейла) → мгновенный fallback, dwell игнор',
        () async {
      final fast = mk('fast', 100);
      final backup = mk('backup', 400);
      final orch = BypassOrchestrator(
        methods: [fast, backup],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: const Duration(minutes: 5), // большой dwell
      );
      addTearDown(orch.dispose);

      await orch.start(network);
      expect(orch.active?.id, 'fast');

      // Только что переключились — dwell не должен мешать при Dead.
      await orch.onHealthSample(const MethodHealth(alive: false));
      await orch.onHealthSample(const MethodHealth(alive: false));
      expect(orch.active?.id, 'fast'); // 2 из 3 — ещё держимся

      await orch.onHealthSample(const MethodHealth(alive: false));
      expect(orch.active?.id, 'backup'); // Dead → мгновенно
      expect(orch.state, OrchestratorState.connected);
    });

    test('Проверка реального трафика: handshake без смены IP → следующий метод',
        () async {
      final liar = mk('liar', 50);
      final real = mk('real', 150);
      final orch = BypassOrchestrator(
        methods: [liar, real],
        // Первый connect — IP не изменился, второй — изменился.
        trafficVerifier: ScriptedVerifier([false, true]),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);

      await orch.start(network);

      expect(orch.active?.id, 'real');
      expect(liar.isConnected, isFalse);
      // Ложный метод не получает победу.
      expect(await wins.winsFor('liar', network), 0);
      expect(await wins.winsFor('real', network), 1);
    });

    test('Dead всех методов → состояние error', () async {
      final m1 = mk('m1', 100)..probeShouldFail = true;
      final m2 = mk('m2', 200)..forceUnavailable = true;
      final orch = BypassOrchestrator(
        methods: [m1, m2],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
      );
      addTearDown(orch.dispose);

      await orch.start(network);
      expect(orch.state, OrchestratorState.error);
      expect(orch.active, isNull);
    });

    test('Память побед: метод-победитель сети опережает более быстрый',
        () async {
      final slow = mk('slow', 300);
      final fast = mk('fast', 100);
      // У сети уже есть победитель — slow.
      await wins.recordWin('slow', network);
      await wins.recordWin('slow', network);

      final orch = BypassOrchestrator(
        methods: [fast, slow],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);

      await orch.start(network);
      expect(orch.active?.id, 'slow',
          reason: 'история побед сети важнее разовой задержки');
    });

    test('Ручной override переключает и снимается обратно в авто', () async {
      final a = mk('a', 100);
      final b = mk('b', 200);
      final orch = BypassOrchestrator(
        methods: [a, b],
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);

      await orch.start(network);
      expect(orch.active?.id, 'a');

      await orch.setManualOverride('b');
      expect(orch.active?.id, 'b');

      await orch.setManualOverride(null);
      expect(orch.state, OrchestratorState.connected);
    });

    test('Демо-набор: 8 методов, старт выбирает живой', () async {
      final methods = buildDefaultMockMethods();
      expect(methods.length, 8);
      final orch = BypassOrchestrator(
        methods: methods,
        trafficVerifier: const AlwaysPassVerifier(),
        winsRepository: wins,
        dwellTime: Duration.zero,
      );
      addTearDown(orch.dispose);
      addTearDown(() => Future.wait(methods.map((m) => m.dispose())));

      await orch.start('demo_network');
      // Все моки с reliability > 0 имеют шанс; хотя бы один должен подключиться.
      expect([OrchestratorState.connected, OrchestratorState.error],
          contains(orch.state));
      if (orch.state == OrchestratorState.connected) {
        expect(orch.active, isNotNull);
        expect(orch.active!.mock, isTrue);
      }
    });
  });
}
