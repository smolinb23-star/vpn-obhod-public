import 'package:vpn_service/features/vpn/widgets/advanced_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Упрощённый главный экран (Smart Connect): одна большая кнопка,
/// статус, текущий протокол, счётчики RX/TX. Ручные настройки — в
/// «Расширенные настройки» (иконка шестерёнки в AppBar).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final TextEditingController _subCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final last = await ref.read(vpnControllerProvider.notifier).restoreLast();
      if (last != null && mounted) {
        _subCtrl.text = last.remark;
      }
    });
  }

  @override
  void dispose() {
    _subCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      await ref.read(vpnControllerProvider.notifier).autoConnect(
            subscription: _subCtrl.text.trim().isEmpty
                ? null
                : _subCtrl.text.trim(),
          );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(vpnControllerProvider.notifier).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final theme = Theme.of(context);
    final connected = ui.state == TunnelState.connected;
    final connecting = ui.state == TunnelState.connecting;

    ref.listen(vpnControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN · Smart Connect'),
        actions: [
          IconButton(
            tooltip: 'Расширенные настройки',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdvancedSettingsScreen(),
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
              // Большой щит-кнопка.
              GestureDetector(
                onTap: connecting
                    ? null
                    : (connected ? _disconnect : _connect),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? Colors.green.shade600
                        : (connecting
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
                  child: connecting
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
              Text(
                connected
                    ? 'Подключено'
                    : (connecting ? 'Поиск сервера…' : 'Отключено'),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (ui.remark.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(ui.remark, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 8),
              Text(
                'Протокол: ${ui.config?.protocol.name ?? '—'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _MetricChip(
                    icon: Icons.download,
                    label: 'RX',
                    value: formatSpeed(ui.metrics.downloadSpeed),
                  ),
                  const SizedBox(width: 16),
                  _MetricChip(
                    icon: Icons.upload,
                    label: 'TX',
                    value: formatSpeed(ui.metrics.uploadSpeed),
                  ),
                ],
              ),
              if (ui.ipAfter != null) ...[
                const SizedBox(height: 12),
                Text('Публичный IP: ${ui.ipAfter}',
                    style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: TextField(
                  controller: _subCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Подписка или конфиг (URL / vless:// / base64)',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Вставьте URL подписки или конфиг. Приложение само найдёт '
                'рабочий сервер (VLESS Reality в приоритете).',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              if (connected) ...[
                const SizedBox(height: 16),
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
