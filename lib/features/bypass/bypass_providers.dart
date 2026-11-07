import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bypass_method.dart';
import 'bypass_orchestrator.dart';
import 'methods/mock_methods.dart';
import 'orchestrator_state.dart';
import 'wins_repository.dart';

/// Ключ текущей сети. TODO(non-blocking): SSID Wi-Fi / operator|mccmnc
/// через нативный канал (Этап 3, там же телеметрия сети).
final networkKeyProvider = Provider<String>((ref) => 'demo_network');

/// Фабрика методов. Сейчас — моки; замена на боевые провайдеры (поверх
/// VpnService + реальных профилей) — одна точка правки здесь.
final bypassMethodsProvider = Provider<List<BypassMethod>>((ref) {
  final methods = buildDefaultMockMethods();
  ref.onDispose(() => Future.wait(methods.map((m) => m.dispose())));
  return methods;
});

final winsRepositoryProvider = Provider<WinsRepository>((ref) {
  // SQLite-версия (SqliteWinsRepository) подключается на Этапе 3 вместе с
  // платформенной инициализацией; в демо — репозиторий в памяти.
  final repo = InMemoryWinsRepository();
  ref.onDispose(repo.close);
  return repo;
});

final orchestratorProvider = Provider<BypassOrchestrator>((ref) {
  final orch = BypassOrchestrator(
    methods: ref.watch(bypassMethodsProvider),
    trafficVerifier: const AlwaysPassVerifier(),
    winsRepository: ref.watch(winsRepositoryProvider),
  );
  ref.onDispose(orch.dispose);
  return orch;
});

/// Статусы методов для UI: id → статус.
class BypassUiState {
  const BypassUiState({
    required this.orchestratorState,
    required this.activeId,
    required this.statuses,
  });

  final OrchestratorState orchestratorState;
  final String? activeId;
  final Map<String, MethodStatus> statuses;

  BypassUiState copyWith({
    OrchestratorState? orchestratorState,
    String? activeId,
    bool clearActive = false,
    Map<String, MethodStatus>? statuses,
  }) {
    return BypassUiState(
      orchestratorState: orchestratorState ?? this.orchestratorState,
      activeId: clearActive ? null : (activeId ?? this.activeId),
      statuses: statuses ?? this.statuses,
    );
  }
}

class BypassController extends Notifier<BypassUiState> {
  BypassOrchestrator get _orch => ref.read(orchestratorProvider);
  List<BypassMethod> get _methods => ref.read(bypassMethodsProvider);

  @override
  BypassUiState build() {
    final sub1 = _orch.stateStream.listen((s) {
      state = state.copyWith(orchestratorState: s);
      _refreshStatuses();
    });
    final sub2 = _orch.activeStream.listen((m) {
      state = state.copyWith(
        activeId: m?.id,
        clearActive: m == null,
      );
      _refreshStatuses();
    });
    ref.onDispose(() {
      sub1.cancel();
      sub2.cancel();
    });
    return BypassUiState(
      orchestratorState: _orch.state,
      activeId: _orch.active?.id,
      statuses: <String, MethodStatus>{
        for (final m in _methods) m.id: MethodStatus.unknown,
      },
    );
  }

  Future<void> startAuto() => _orch.start(ref.read(networkKeyProvider));

  Future<void> stop() => _orch.stop();

  Future<void> selectManual(String? id) => _orch.setManualOverride(id);

  /// Обновляет статусы: активный/недоступен/неизвестен.
  /// Деградация приходит из healthStream на Этапе 3 (боевые методы).
  void _refreshStatuses() {
    final map = <String, MethodStatus>{};
    for (final m in _methods) {
      if (m.id == _orch.active?.id) {
        map[m.id] = MethodStatus.active;
      } else {
        // Асинхронную isAvailable здесь не ждём — помечаем unknown;
        // реальные статусы проставляются после probe (Этап 3).
        map[m.id] = MethodStatus.unknown;
      }
    }
    if (_orch.state == OrchestratorState.error) {
      for (final id in map.keys.toList()) {
        if (map[id] != MethodStatus.active) map[id] = MethodStatus.unavailable;
      }
    }
    state = state.copyWith(statuses: map);
  }
}

final bypassControllerProvider =
    NotifierProvider<BypassController, BypassUiState>(BypassController.new);
