import 'dart:async';
import 'dart:math';

import 'package:vpn_service/features/bypass/bypass_method.dart';

/// Метод-заглушка для демо и тестов без VPS.
///
/// Детерминированность: задержки и успех probe выводятся из `Random(seed)`,
/// где seed по умолчанию — hashCode(id). В тестах поведение переопределяется
/// явными полями ([fixedLatencyMs], [forceUnavailable], [probeShouldFail])
/// и скриптом здоровья ([degrade], [die]).
class MockBypassMethod implements BypassMethod {
  MockBypassMethod({
    required this.id,
    required this.name,
    this.reliability = 1.0,
    this.baseLatencyMs = 100,
    int? seed,
  }) : _rng = Random(seed ?? id.hashCode & 0x7fffffff);

  @override
  final String id;
  @override
  final String name;

  @override
  bool get mock => true;

  /// Доля успешных probe (0..1): метод «успешен на seed < reliability».
  final double reliability;
  final int baseLatencyMs;
  final Random _rng;

  // --- Управление из тестов ---
  int? fixedLatencyMs;
  bool forceUnavailable = false;
  bool probeShouldFail = false;
  bool connectShouldThrow = false;
  int probeCount = 0;
  int connectCount = 0;

  final StreamController<MethodHealth> _healthCtrl =
      StreamController<MethodHealth>.broadcast();
  MethodHealth _current = const MethodHealth(alive: true, rttMs: 100);
  bool _connected = false;

  MethodHealth get currentHealth => _current;
  bool get isConnected => _connected;

  @override
  Future<bool> isAvailable() async => !forceUnavailable;

  @override
  Future<ProbeResult> probe() async {
    probeCount++;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (forceUnavailable || probeShouldFail) {
      return const ProbeResult.failed('mock unavailable');
    }
    if (_rng.nextDouble() >= reliability) {
      return const ProbeResult.failed('mock seed >= reliability');
    }
    final latency = fixedLatencyMs ?? baseLatencyMs + _rng.nextInt(20);
    return ProbeResult(success: true, latencyMs: latency, realIpChanged: true);
  }

  @override
  Future<void> connect() async {
    connectCount++;
    if (connectShouldThrow) {
      throw StateError('mock connect failed: $id');
    }
    _connected = true;
    _emit(_current.alive
        ? MethodHealth(alive: true, rttMs: fixedLatencyMs ?? _current.rttMs)
        : _current);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Stream<MethodHealth> get healthStream => _healthCtrl.stream;

  // --- Скрипты деградации для тестов/демо ---

  void degrade({int rttMs = 500, double lossRatio = 0.05}) {
    _current = MethodHealth(alive: true, rttMs: rttMs, lossRatio: lossRatio);
    _emit(_current);
  }

  void recover({int rttMs = 80}) {
    _current = MethodHealth(alive: true, rttMs: rttMs);
    _emit(_current);
  }

  void die() {
    _current = const MethodHealth(alive: false);
    _emit(_current);
  }

  void _emit(MethodHealth h) {
    if (!_healthCtrl.isClosed && _connected) {
      _healthCtrl.add(h);
    }
  }

  Future<void> dispose() => _healthCtrl.close();
}

/// Семёрка методов обхода из мастер-команды (моки).
///
/// reliability/latency подобраны так, чтобы в демо всегда был живой выбор
/// и заметная разница ранжирования: Reality быстрее всех, WebRTC — manual.
List<MockBypassMethod> buildDefaultMockMethods() => <MockBypassMethod>[
      MockBypassMethod(
        id: 'vless_reality',
        name: 'VLESS Reality + Vision',
        reliability: 0.9,
        baseLatencyMs: 60,
      ),
      MockBypassMethod(
        id: 'vless_xhttp_cdn',
        name: 'VLESS + XHTTP + CDN',
        reliability: 0.7,
        baseLatencyMs: 120,
      ),
      MockBypassMethod(
        id: 'hysteria2',
        name: 'Hysteria2 (port hopping)',
        reliability: 0.85,
        baseLatencyMs: 90,
      ),
      MockBypassMethod(
        id: 'wireguard',
        name: 'WireGuard (mesh)',
        reliability: 0.6,
        baseLatencyMs: 40,
      ),
      MockBypassMethod(
        id: 'cascade',
        name: 'Каскад: локальный хост → сервер',
        reliability: 0.5,
        baseLatencyMs: 150,
      ),
      MockBypassMethod(
        id: 'webrtc_tunnel',
        name: 'WebRTC-туннель (ручной)',
        reliability: 0.3,
        baseLatencyMs: 250,
      ),
      MockBypassMethod(
        id: 'doh',
        name: 'DNS-over-HTTPS обфускация',
        reliability: 0.8,
        baseLatencyMs: 30,
      ),
    ];
