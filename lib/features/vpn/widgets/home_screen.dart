import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/features/bypass/bypass_providers.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/awg_status_panel.dart';
import 'package:vpn_service/features/vpn/widgets/conf_import_screen.dart';

/// Главный экран: подключение, статус, AmneziaWG-панель, LTE-форсирование.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  Future<void> _restore() async {
    final last = await ref.read(vpnControllerProvider.notifier).restoreLast();
    if (last != null && mounted) {
      _inputCtrl.text = last.remark;
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final controller = ref.read(vpnControllerProvider.notifier);
    final current = ref.read(vpnControllerProvider);

    if (current.state == TunnelState.connected ||
        current.state == TunnelState.connecting) {
      await controller.disconnect();
      return;
    }

    setState(() => _busy = true);
    try {
      var config = current.config;
      final raw = _inputCtrl.text.trim();
      if (raw.isEmpty || raw == current.remark) {
        config ??= await controller.restoreLast();
      } else {
        config = await controller.importProfile(raw);
      }
      if (config == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Вставьте vless://-ссылку или Xray JSON')),
          );
        }
        return;
      }
      await controller.connect(config);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forceLte() async {
    final result = await ref.read(platformBridgeProvider).forceLte();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.ok ? 'LTE включён' : 'Не удалось включить LTE'),
        content: Text(
          '${result.message}\n\n'
          '${result.needsPermission ? 'Выдайте разрешение по ADB:\n'
              'adb shell pm grant dev.local.vpnservice '
              'android.permission.WRITE_SECURE_SETTINGS\n\n' : ''}'
          'Если LTE-форсирование не нужно — остальные функции работают '
          'как обычно.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final network = ref.watch(networkKeyProvider);
    ref.listen(vpnControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    final connected = ui.state == TunnelState.connected;
    final connecting = ui.state == TunnelState.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN · Обход белых списков'),
        actions: [
          IconButton(
            tooltip: 'Импорт .conf (AmneziaWG / WARP)',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const ConfImportScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(ui: ui),
          const SizedBox(height: 12),
          const AwgStatusPanel(compact: true),
          const SizedBox(height: 12),
          TextField(
            controller: _inputCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Конфиг: vless://… , hysteria2://…, Xray JSON или подписка',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _toggle,
            icon: connecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(connected ? Icons.link_off : Icons.link),
            label: Text(connected || connecting ? 'Отключиться' : 'Подключиться'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          if (ui.ipAfter != null) ...[
            const SizedBox(height: 8),
            Text('Внешний IP: ${ui.ipAfter}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cell_tower, size: 20),
                      const SizedBox(width: 8),
                      Text('Сеть и стабильность',
                          style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'network_key: ${network.when(
                      data: (v) => v,
                      loading: () => '…',
                      error: (_, __) => 'unknown',
                    )}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _forceLte,
                    icon: const Icon(Icons.network_cell),
                    label: const Text('Форсировать LTE (только LTE)'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Требует WRITE_SECURE_SETTINGS (ADB). Без разрешения '
                    'покажется инструкция — остальное продолжает работать.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.ui});

  final VpnUiState ui;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (ui.state) {
      TunnelState.connected => ('Подключено', Colors.green),
      TunnelState.connecting => ('Подключение…', Colors.orange),
      TunnelState.error => ('Ошибка', Colors.red),
      TunnelState.disconnected => ('Отключено', Colors.grey),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.shield, color: color, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleLarge),
                  if (ui.remark.isNotEmpty)
                    Text(ui.remark, style: Theme.of(context).textTheme.bodyMedium),
                  Text(
                    '↓ ${formatSpeed(ui.metrics.downloadSpeed)}   '
                    '↑ ${formatSpeed(ui.metrics.uploadSpeed)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
