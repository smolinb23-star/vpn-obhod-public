import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/bypass/bypass_providers.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/log_export_service.dart';
import 'package:vpn_service/core/services/platform_bridge.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/widgets/awg_dpi_panel.dart';
import 'package:vpn_service/features/vpn/widgets/awg_status_panel.dart';
import 'package:vpn_service/features/vpn/widgets/conf_import_screen.dart';

/// Расширенные настройки: импорт .conf, I1/MTU/порт, DPI-диагностика,
/// форсирование LTE, экспорт логов.
class AdvancedSettingsScreen extends ConsumerStatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  ConsumerState<AdvancedSettingsScreen> createState() =>
      _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState
    extends ConsumerState<AdvancedSettingsScreen> {
  final LogExportService _logExport = LogExportService();
  bool _busy = false;

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

  Future<void> _exportLogs() async {
    try {
      await _logExport.share();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Экспорт логов: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkKeyProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Расширенные настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ConfImportScreen(),
              ),
            ),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Импорт .conf (AmneziaWG / WARP)'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          const SizedBox(height: 12),
          const AwgStatusPanel(),
          const SizedBox(height: 12),
          const AwgDpiPanel(),
          const SizedBox(height: 12),
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
                          style: theme.textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'network_key: ${network.when(
                      data: (v) => v,
                      loading: () => '…',
                      error: (_, __) => 'unknown',
                    )}',
                    style: theme.textTheme.bodySmall,
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
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _exportLogs,
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Экспорт логов (logs.txt)'),
          ),
        ],
      ),
    );
  }
}
