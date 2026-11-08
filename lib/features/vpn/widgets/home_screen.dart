import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/connection_orchestrator.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/config_management_screen.dart'
    show ConfigManagementScreen, savedConfigsProvider;
import 'package:vpn_service/features/vpn/widgets/split_tunneling_screen.dart';

/// Упрощённый главный экран (Smart Connect).
///
/// Одна большая кнопка «Подключиться». При нажатии запускается
/// ConnectionOrchestrator, который последовательно перебирает методы
/// (AmneziaWG → VLESS Reality → Hysteria2 в зависимости от сети)
/// пока не найдёт рабочий.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _busy = false;
  String _status = 'Готово';
  final List<String> _attemptHistory = [];
  int _excludedAppsCount = 0;

  @override
  void initState() {
    super.initState();
    // Автоподключение при запуске если есть сохранённые конфиги
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final configs = await ref.read(savedConfigsProvider.future);
      if (configs.isNotEmpty && mounted) {
        await _connect();
      }
      // Загружаем количество исключённых приложений
      final selectedApps = ref.read(selectedAppsProvider);
      setState(() {
        _excludedAppsCount = selectedApps.length;
      });
    });
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Тестирование…';
      _attemptHistory.clear();
    });

    // Определяем тип сети
    final platform = ref.read(platformBridgeProvider);
    final info = await platform.networkInfo();
    final isMobile = info.type == 'mobile';

    final orchestrator =
        ref.read(connectionOrchestratorProvider(isMobile));

    final result = await orchestrator.autoConnect(
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
    );

    if (!mounted) return;
    setState(() => _busy = false);

    // Добавляем историю попыток в отображение.
    if (result.attempts.isNotEmpty) {
      setState(() {
        _attemptHistory
          ..clear()
          ..addAll(result.attempts.map((a) {
            final ok = a.ok ? 'OK' : 'ОШИБКА';
            final err = a.error != null ? ' — ${a.error}' : '';
            return '[${a.methodName}] $ok$err';
          }));
      });
    }

    if (result.success) {
      setState(() => _status = 'Успех: ${result.methodName}');
      if (result.publicIp != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Подключено через ${result.methodName}. IP: ${result.publicIp}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } else {
      setState(() => _status = 'Ошибка');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.error ?? 'Не удалось подключиться'),
                const SizedBox(height: 8),
                ..._attemptHistory.map((a) => Text(a, style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
          duration: const Duration(seconds: 6),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await ref.read(vpnControllerProvider.notifier).disconnect();
    await ref.read(awgSessionProvider.notifier).disconnect();
    if (mounted) {
      setState(() {
        _busy = false;
        _status = 'Отключено';
        _attemptHistory.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final awg = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);
    final connected = ui.state == TunnelState.connected || awg.up;
    final connecting = ui.state == TunnelState.connecting || awg.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN · Smart Connect'),
        actions: [
          IconButton(
            tooltip: 'Управление конфигами',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ConfigManagementScreen(),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Большая кнопка подключения.
              GestureDetector(
                onTap: connecting || _busy
                    ? null
                    : (connected ? _disconnect : _connect),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? Colors.green.shade600
                        : (connecting || _busy
                            ? Colors.orange.shade600
                            : theme.colorScheme.primary),
                    boxShadow: [
                      BoxShadow(
                        color: (connected
                                ? Colors.green
                                : theme.colorScheme.primary)
                            .withValues(alpha: 0.4),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: connecting || _busy
                      ? const Center(
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 4,
                            ),
                          ),
                        )
                      : Icon(
                          connected ? Icons.shield : Icons.shield_outlined,
                          size: 80,
                          color: Colors.white,
                        ),
                ),
              ),
              const SizedBox(height: 24),
              // Статус подключения.
              Text(
                connected
                    ? 'Подключено'
                    : (connecting || _busy ? _status : 'Отключено'),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (ui.remark.isNotEmpty || awg.configName != null) ...[
                const SizedBox(height: 4),
                Text(ui.remark.isNotEmpty ? ui.remark : awg.configName!,
                    style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 8),
              Text(
                'Протокол: ${ui.config?.protocol.name ?? (awg.up ? "amneziawg" : "—")}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _MetricChip(
                    icon: Icons.download,
                    label: 'RX',
                    value: formatSpeed(ui.state == TunnelState.connected
                        ? ui.metrics.downloadSpeed
                        : awg.rxSpeed),
                  ),
                  const SizedBox(width: 16),
                  _MetricChip(
                    icon: Icons.upload,
                    label: 'TX',
                    value: formatSpeed(ui.state == TunnelState.connected
                        ? ui.metrics.uploadSpeed
                        : awg.txSpeed),
                  ),
                ],
              ),
              if (ui.ipAfter != null || awg.publicIp != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Публичный IP: ${ui.ipAfter ?? awg.publicIp}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              // Индикатор раздельного туннелирования
              if (_excludedAppsCount > 0)
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.error_outline,
                        color: Colors.orange),
                    title: Text('Исключено приложений: $_excludedAppsCount',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text(
                      'Эти приложения не будут использовать VPN-туннель',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () async {
                        final result = await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SplitTunnelingScreen(),
                          ),
                        );
                        if (result != null && result is Set<String>) {
                          setState(() {
                            _excludedAppsCount = result.length;
                          });
                        }
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Вы можете исключить приложения (банки, Госуслуги и др.) из VPN-туннеля '
                'в настройках ниже.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              if (connected) ...[
              if (_attemptHistory.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('История попыток:',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          )),
                      const SizedBox(height: 6),
                      ..._attemptHistory.map((a) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(a,
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                      )),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (connected) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Отключиться'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 20),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
