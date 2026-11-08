import 'dart:async';

import 'package:vpn_service/features/bypass/bypass_method.dart';

/// Интегральная оценка здоровья туннеля.
enum TunnelHealth { unknown, healthy, degraded, dead }

/// Один замер здоровья (публикуется в UI и используется авто-реконнектом).
class HealthSample {
  const HealthSample({
    required this.state,
    required this.health,
    required this.at,
  });

  final TunnelHealth state;
  final MethodHealth health;
  final DateTime at;

  bool get alive => health.alive;
  int get rttMs => health.rttMs;
  double get lossRatio => health.lossRatio;
}

/// Health-цикл: раз в 15 секунд оценивает RTT и потери.
///
/// Правила мастер-команды:
///  - Degraded при RTT > 300 мс или потерях > 2%;
///  - Dead при 3 «мёртвых» замерах подряд;
///  - гистерезис 3 замера на переход;
///  - dwell time 5 минут между переходами (Dead его игнорирует).
class HealthMonitor {
  HealthMonitor({
    required Future<MethodHealth> Function() sampler,
    this.interval = const Duration(seconds: 15),
    this.degradedRttMs = 300,
    this.degradedLossRatio = 0.02,
    this.hysteresisSamples = 3,
    this.deadSamples = 3,
    this.dwellTime = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : _sampler = sampler,
        _clock = clock ?? DateTime.now;

  final Future<MethodHealth> Function() _sampler;
  final Duration interval;
  final int degradedRttMs;
  final double degradedLossRatio;
  final int hysteresisSamples;
  final int deadSamples;
  final Duration dwellTime;
  final DateTime Function() _clock;

  final StreamController<HealthSample> _ctrl =
      StreamController<HealthSample>.broadcast();

  Timer? _timer;
  bool _ticking = false;
  int _degradedStreak = 0;
  int _healthyStreak = 0;
  int _deadStreak = 0;
  DateTime? _lastTransitionAt;
  TunnelHealth _state = TunnelHealth.unknown;
  HealthSample? _last;

  Stream<HealthSample> get stream => _ctrl.stream;
  TunnelHealth get state => _state;
  HealthSample? get last => _last;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Один замер. Публичный для тестов (таймер не нужен).
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      MethodHealth health;
      try {
        health = await _sampler();
      } on Object {
        health = const MethodHealth(alive: false, handshakeErrors: 1);
      }
      _apply(health);
    } finally {
      _ticking = false;
    }
  }

  void _apply(MethodHealth health) {
    final now = _clock();

    if (!health.alive) {
      _deadStreak++;
      _healthyStreak = 0;
      _degradedStreak = 0;
      if (_deadStreak >= deadSamples) {
        _transition(TunnelHealth.dead, now);
      }
    } else {
      _deadStreak = 0;
      final degraded = health.rttMs > degradedRttMs ||
          health.lossRatio > degradedLossRatio;
      if (degraded) {
        _degradedStreak++;
        _healthyStreak = 0;
        if (_degradedStreak >= hysteresisSamples) {
          _transition(TunnelHealth.degraded, now);
        }
      } else {
        _degradedStreak = 0;
        _healthyStreak++;
        if (_healthyStreak >= hysteresisSamples) {
          _transition(TunnelHealth.healthy, now);
        }
      }
    }

    final sample = HealthSample(state: _state, health: health, at: now);
    _last = sample;
    if (!_ctrl.isClosed) _ctrl.add(sample);
  }

  void _transition(TunnelHealth next, DateTime now) {
    if (next == _state) return;
    // Dead важнее dwell: аварийный реконнект не откладываем.
    if (next != TunnelHealth.dead &&
        _lastTransitionAt != null &&
        now.difference(_lastTransitionAt!) < dwellTime) {
      return;
    }
    _state = next;
    _lastTransitionAt = now;
  }

  Future<void> dispose() async {
    stop();
    await _ctrl.close();
  }
}
