import 'dart:async';

import 'bypass_method.dart';
import 'orchestrator_state.dart';
import 'wins_repository.dart';

/// Кандидат на подключение с результатом разведки.
class RankedMethod {
  const RankedMethod(this.method, this.probe, this.wins);
  final BypassMethod method;
  final ProbeResult probe;
  final int wins;
}

/// Главный движок авто-переключения методов обхода.
///
/// Жизненный цикл: idle → probing → connecting → connected ⇄ switching → error.
///
/// Правила (из мастер-команды):
///  - параллельный `probe()` всех доступных методов с таймаутом на метод;
///  - ранжирование: успех → приоритет истории побед → RTT → число побед;
///  - после connect обязательная проверка реального трафика (смена IP);
///  - Degraded: RTT > 300 мс или потери > 2%, подтверждённые 3 замерами;
///  - Dead: 3 смерти подряд → немедленное переключение;
///  - dwell time после переключения (для Degraded), Dead его игнорирует;
///  - память побед в [WinsRepository] по ключу сети.
class BypassOrchestrator {
  BypassOrchestrator({
    required List<BypassMethod> methods,
    required TrafficVerifier trafficVerifier,
    required WinsRepository winsRepository,
    Duration probeTimeout = const Duration(seconds: 8),
    Duration dwellTime = const Duration(minutes: 5),
    this.degradedRttMs = 300,
    this.degradedLossRatio = 0.02,
    this.hysteresisSamples = 3,
    this.deadSamples = 3,
  })  : _methods = List<BypassMethod>.unmodifiable(methods),
        _trafficVerifier = trafficVerifier,
        _wins = winsRepository,
        _probeTimeout = probeTimeout,
        _dwellTime = dwellTime;

  final List<BypassMethod> _methods;
  final TrafficVerifier _trafficVerifier;
  final WinsRepository _wins;
  final Duration _probeTimeout;
  final Duration _dwellTime;

  final int degradedRttMs;
  final double degradedLossRatio;

  /// Сколько замеров деградации подряд подтверждают переход на другой метод.
  final int hysteresisSamples;

  /// Сколько «мёртвых» замеров подряд означают Dead.
  final int deadSamples;

  final StreamController<OrchestratorState> _stateCtrl =
      StreamController<OrchestratorState>.broadcast();
  final StreamController<BypassMethod?> _activeCtrl =
      StreamController<BypassMethod?>.broadcast();

  OrchestratorState _state = OrchestratorState.idle;
  BypassMethod? _active;
  StreamSubscription<MethodHealth>? _healthSub;
  String _networkKey = 'unknown';
  bool _mobileNetwork = false;
  String? _manualOverrideId;
  int _degradedStreak = 0;
  int _deadStreak = 0;
  int _probeRounds = 0;
  DateTime? _lastSwitchAt;
  bool _disposed = false;

  // --- Публичное состояние ---

  OrchestratorState get state => _state;
  BypassMethod? get active => _active;
  int get probeRounds => _probeRounds;
  String? get manualOverrideId => _manualOverrideId;
  Stream<OrchestratorState> get stateStream => _stateCtrl.stream;
  Stream<BypassMethod?> get activeStream => _activeCtrl.stream;

  /// Ручной выбор пользователя (override). null — вернуть авто-режим.
  Future<void> setManualOverride(String? methodId) async {
    _manualOverrideId = methodId;
    if (methodId == null) {
      // Снятие override — заново прогнать авто-выбор.
      await start(_networkKey);
      return;
    }
    final method = _methods.firstWhere(
      (m) => m.id == methodId,
      orElse: () => throw ArgumentError('unknown method: $methodId'),
    );
    await _switchTo(method, respectDwell: false, record: false);
  }

  /// Запуск: разведка всех методов и подключение лучшего.
  Future<void> start(String networkKey, {bool mobileNetwork = false}) async {
    _networkKey = networkKey;
    _mobileNetwork = mobileNetwork;
    if (_active != null) {
      await _disconnectActive();
    }
    final candidates = await _rank(networkKey);
    if (candidates.isEmpty) {
      _setState(OrchestratorState.error);
      return;
    }
    await _connectFirstUsable(candidates);
  }

  Future<void> stop() async {
    await _disconnectActive();
    _setState(OrchestratorState.idle);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _disconnectActive();
    await _stateCtrl.close();
    await _activeCtrl.close();
    await _wins.close();
  }

  // --- Разведка и ранжирование ---

  /// Параллельный probe доступных методов + ранжирование.
  Future<List<RankedMethod>> _rank(String networkKey,
      {String? excludeId}) async {
    _setState(OrchestratorState.probing);
    _probeRounds++;

    final historyWinner = await _wins.bestMethodFor(networkKey);

    final available = <BypassMethod>[];
    for (final m in _methods) {
      if (m.id == excludeId) continue;
      if (await m.isAvailable()) available.add(m);
    }

    final probed = await Future.wait(
      available.map(
        (m) => m
            .probe()
            .timeout(_probeTimeout,
                onTimeout: () => const ProbeResult.failed('probe timeout'))
            .catchError((Object e) => ProbeResult.failed('$e')),
      ),
    );

    final ranked = <RankedMethod>[];
    for (var i = 0; i < available.length; i++) {
      final m = available[i];
      final r = probed[i];
      if (!r.success) continue;
      final wins = await _wins.winsFor(m.id, networkKey);
      ranked.add(RankedMethod(m, r, wins));
    }

    ranked.sort((a, b) {
      // 0. На мобильной сети VLESS Reality и Hysteria2 — впереди AWG.
      if (_mobileNetwork) {
        int mobileRank(String id) {
          if (id.startsWith('vless')) return 0;
          if (id == 'hysteria2') return 1;
          if (id == 'amneziawg') return 2;
          return 3;
        }
        final ra = mobileRank(a.method.id);
        final rb = mobileRank(b.method.id);
        if (ra != rb) return ra.compareTo(rb);
      } else {
        // На Wi-Fi AmneziaWG может быть основным.
        int wifiRank(String id) {
          if (id == 'amneziawg') return 0;
          if (id.startsWith('vless')) return 1;
          if (id == 'hysteria2') return 2;
          return 3;
        }
        final ra = wifiRank(a.method.id);
        final rb = wifiRank(b.method.id);
        if (ra != rb) return ra.compareTo(rb);
      }
      // 1. Приоритет протокола (VLESS Reality выше AWG/Hysteria2).
      if (a.method.priority != b.method.priority) {
        return a.method.priority.compareTo(b.method.priority);
      }
      // 1. История побед для этой сети — пробуем первым.
      final aHist = a.method.id == historyWinner ? 1 : 0;
      final bHist = b.method.id == historyWinner ? 1 : 0;
      if (aHist != bHist) return bHist - aHist;
      // 2. Меньший RTT.
      final al = a.probe.latencyMs ?? 1 << 30;
      final bl = b.probe.latencyMs ?? 1 << 30;
      if (al != bl) return al.compareTo(bl);
      // 3. Больше побед.
      if (a.wins != b.wins) return b.wins.compareTo(a.wins);
      // 4. Стабильный порядок по id.
      return a.method.id.compareTo(b.method.id);
    });

    return ranked;
  }

  /// Подключает первого кандидата, прошедшего проверку реального трафика.
  Future<void> _connectFirstUsable(List<RankedMethod> candidates) async {
    // Старый активный метод снимаем до подключения нового (switch-путь).
    if (_active != null) {
      await _disconnectActive();
    }
    for (final candidate in candidates) {
      final ok = await _tryConnect(candidate.method);
      if (ok) {
        await _wins.recordWin(candidate.method.id, _networkKey);
        _setState(OrchestratorState.connected);
        return;
      }
    }
    _setState(OrchestratorState.error);
  }

  /// connect + обязательная проверка смены IP. true — метод рабочий.
  Future<bool> _tryConnect(BypassMethod method) async {
    _setState(OrchestratorState.connecting);
    try {
      await method.connect();
    } on Object {
      return false;
    }

    _active = method;
    _activeCtrl.add(method);
    _watchHealth(method);

    final changed = await _trafficVerifier.verifyTraffic();
    if (changed == false) {
      await _disconnectActive();
      return false;
    }
    return true;
  }

  void _watchHealth(BypassMethod method) {
    _healthSub?.cancel();
    _degradedStreak = 0;
    _deadStreak = 0;
    _healthSub = method.healthStream.listen((h) {
      if (identical(method, _active)) {
        onHealthSample(h);
      }
    });
  }

  /// Оценка очередного замера здоровья. Вызывается из подписки на healthStream
  /// (и напрямую из тестов).
  Future<void> onHealthSample(MethodHealth health) async {
    // Замеры учитываются только в устойчивом connected — иначе возможна
    // реентерабельная гонка переключений во время probing/connecting.
    if (_state != OrchestratorState.connected || _active == null) return;

    if (!health.alive) {
      _deadStreak++;
      if (_deadStreak >= deadSamples) {
        // Dead: мгновенное переключение, dwell игнорируется.
        await _switchToNext(excludeId: _active!.id);
      }
      return;
    }

    _deadStreak = 0;
    final degraded =
        health.rttMs > degradedRttMs || health.lossRatio > degradedLossRatio;

    if (!degraded) {
      _degradedStreak = 0;
      return;
    }

    _degradedStreak++;
    if (_degradedStreak < hysteresisSamples) return;

    // Degraded подтверждён: уважаем dwell time.
    if (_lastSwitchAt != null &&
        DateTime.now().difference(_lastSwitchAt!) < _dwellTime) {
      return;
    }
    await _switchToNext(excludeId: _active!.id);
  }

  Future<void> _switchToNext({String? excludeId}) async {
    final candidates = await _rank(_networkKey, excludeId: excludeId);
    if (candidates.isEmpty) {
      // Попробуем и excluded — возможно, он уже ожил.
      final retry = await _rank(_networkKey);
      if (retry.isEmpty) {
        _setState(OrchestratorState.error);
        return;
      }
      await _connectFirstUsable(retry);
      return;
    }
    await _connectFirstUsable(candidates);
  }

  Future<void> _switchTo(BypassMethod method,
      {required bool respectDwell, required bool record}) async {
    if (respectDwell &&
        _lastSwitchAt != null &&
        DateTime.now().difference(_lastSwitchAt!) < _dwellTime) {
      return;
    }
    await _disconnectActive();
    final ok = await _tryConnect(method);
    if (!ok) {
      _setState(OrchestratorState.error);
      return;
    }
    if (record) {
      await _wins.recordWin(method.id, _networkKey);
    }
    _setState(OrchestratorState.connected);
  }

  Future<void> _disconnectActive() async {
    await _healthSub?.cancel();
    _healthSub = null;
    final method = _active;
    _active = null;
    _activeCtrl.add(null);
    if (method != null) {
      try {
        await method.disconnect();
      } on Object {
        // Ошибки стопки не должны ронять движок.
      }
    }
    _degradedStreak = 0;
    _deadStreak = 0;
  }

  void _setState(OrchestratorState next) {
    if (_state == next) return;
    _state = next;
    if (next == OrchestratorState.connected ||
        next == OrchestratorState.connecting) {
      _lastSwitchAt = DateTime.now();
    }
    if (!_stateCtrl.isClosed) _stateCtrl.add(next);
  }
}
