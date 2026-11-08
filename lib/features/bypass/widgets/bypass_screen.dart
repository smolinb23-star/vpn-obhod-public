import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/bypass/bypass_method.dart';
import 'package:vpn_service/features/bypass/bypass_providers.dart';
import 'package:vpn_service/features/bypass/orchestrator_state.dart';

class _RoutingModeCard extends ConsumerWidget {
  const _RoutingModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(routingModeProvider);
    final all = mode == RoutingMode.allThroughVpn;
    return Card(
      child: SwitchListTile(
        title: const Text('Режим обхода'),
        subtitle: Text(all
            ? 'Все через VPN (AllowedIPs = 0.0.0.0/0)'
            : 'Только заблокированные (раздельная маршрутизация)'),
        value: all,
        onChanged: (v) => ref.read(routingModeProvider.notifier).state =
            v ? RoutingMode.allThroughVpn : RoutingMode.blockedOnly,
      ),
    );
  }
}


/// Экран «Обход»: список методов, статусы, активный метод, авто-выбор,
/// ручной override.
class BypassScreen extends ConsumerStatefulWidget {
  const BypassScreen({super.key});

  @override
  ConsumerState<BypassScreen> createState() => _BypassScreenState();
}

class _BypassScreenState extends ConsumerState<BypassScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctrl = ref.read(bypassControllerProvider.notifier);
      ctrl.startAuto();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(bypassControllerProvider);
    final methods = ref.watch(bypassMethodsProvider);
    final ctrl = ref.read(bypassControllerProvider.notifier);

    final running = ui.orchestratorState == OrchestratorState.connected ||
        ui.orchestratorState == OrchestratorState.probing ||
        ui.orchestratorState == OrchestratorState.connecting;

    return Scaffold(
      appBar: AppBar(title: const Text('Обход белых списков')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _stateLabel(ui.orchestratorState),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => ctrl.startAuto(),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Авто-выбор'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const _RoutingModeCard(),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: methods.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final m = methods[i];
                final status = ui.statuses[m.id] ?? MethodStatus.unknown;
                final isActive = ui.activeId == m.id;
                return Card(
                  color: isActive
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    leading: Text(_statusEmoji(status),
                        style: const TextStyle(fontSize: 24)),
                    title: Text(m.name),
                    subtitle: Text(
                      m.mock
                          ? 'демо-режим (без VPS)${isActive ? ' · активен' : ''}'
                          : (isActive ? 'активен' : ''),
                    ),
                    trailing: isActive
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : IconButton(
                            icon: const Icon(Icons.radio_button_unchecked),
                            tooltip: 'Выбрать вручную',
                            onPressed: () => ctrl.selectManual(m.id),
                          ),
                    onTap: () => ctrl.selectManual(m.id),
                  ),
                );
              },
            ),
          ),
          if (running)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: () => ctrl.stop(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Остановить авто-переключение'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _statusEmoji(MethodStatus s) => switch (s) {
        MethodStatus.active => '🟢',
        MethodStatus.available => '🟢',
        MethodStatus.degraded => '🟡',
        MethodStatus.unavailable => '🔴',
        MethodStatus.unknown => '⚪',
      };

  static String _stateLabel(OrchestratorState s) => switch (s) {
        OrchestratorState.idle => 'Остановлено',
        OrchestratorState.probing => 'Разведка методов…',
        OrchestratorState.connecting => 'Подключение лучшего метода…',
        OrchestratorState.connected => 'Подключено (авто-выбор)',
        OrchestratorState.switching => 'Переключение…',
        OrchestratorState.error => 'Нет живых методов',
      };
}
