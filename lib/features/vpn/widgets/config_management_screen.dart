import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/connection_orchestrator.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Экран «Управление конфигами».
///
/// Позволяет:
///  - вставлять текст конфига (vless:// ссылку или .conf текст);
///  - выбирать .conf файл из памяти устройства;
///  - сохранять конфиги с именами между перезапусками;
///  - просматривать список сохранённых конфигов;
///  - удалять конфиги.
class ConfigManagementScreen extends ConsumerStatefulWidget {
  const ConfigManagementScreen({super.key});

  @override
  ConsumerState<ConfigManagementScreen> createState() =>
      _ConfigManagementScreenState();
}

class _ConfigManagementScreenState
    extends ConsumerState<ConfigManagementScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  String? _validationError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLastConfig();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLastConfig() async {
    final storage = ref.read(secureStorageProvider);
    final raw = await storage.read(key: 'last_config_input');
    if (raw != null && raw.isNotEmpty && mounted) {
      _inputCtrl.text = raw;
    }
  }

  Future<void> _saveLastConfig(String text) async {
    final storage = ref.read(secureStorageProvider);
    await storage.write(key: 'last_config_input', value: text);
  }

  bool _isValid(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('http://') || t.startsWith('https://')) return true;
    if (t.startsWith('vless://') ||
        t.startsWith('hysteria2://') ||
        t.startsWith('hy2://') ||
        t.startsWith('vmess://') ||
        t.startsWith('trojan://') ||
        t.startsWith('ss://') ||
        t.startsWith('wireguard://')) {
      return true;
    }
    if (t.contains('[Interface]') && t.contains('[Peer]')) return true;
    if (t.startsWith('{')) return true;
    if (RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(t) && t.length > 64) {
      return true;
    }
    return false;
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Выберите .conf файл',
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      var bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) return;
      if (!mounted) return;
      _inputCtrl.text = String.fromCharCodes(bytes);
      setState(() => _validationError = null);
      await _saveLastConfig(_inputCtrl.text);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Выбор файла: $e')));
      }
    }
  }

  Future<void> _saveConfig() async {
    final input = _inputCtrl.text.trim();
    if (!_isValid(input)) {
      setState(() => _validationError =
          'Неверный формат конфига. Вставьте ссылку или содержимое .conf.');
      return;
    }

    setState(() {
      _validationError = null;
      _busy = true;
    });

    try {
      await _saveLastConfig(input);

      final orchestrator =
          ref.read(connectionOrchestratorProvider(false));

      if (WGConfigParser.looksLikeWireGuardConf(input)) {
        final cfg = const WGConfigParser().parse(input);
        await orchestrator.saveAwgConfig(cfg);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Конфиг «${cfg.name}» сохранён')),
          );
        }
      } else {
        // Пытаемся распарсить как VLESS/подписку через VpnController
        final vpnCtrl = ref.read(vpnControllerProvider.notifier);
        final parsed = await vpnCtrl.importProfile(input);
        if (parsed != null && mounted) {
          await orchestrator.saveVlessConfig(parsed);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Конфиг «${parsed.remark}» сохранён')),
          );
          if (mounted) setState(() => _inputCtrl.clear());
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Формат не распознан как vless:// ссылка или .conf.',
              ),
            ),
          );
        }
      }

      if (mounted) setState(() => _inputCtrl.clear());
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка сохранения: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Управление конфигами'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Добавить конфиг',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Вставьте vless:// ссылку, URL подписки или содержимое .conf файла.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputCtrl,
                          maxLines: 5,
                          onChanged: (_) {
                            if (_validationError != null) {
                              setState(() => _validationError = null);
                            }
                          },
                          decoration: InputDecoration(
                            labelText: 'Конфиг',
                            hintText:
                                'vless://uuid@host:port?... или [Interface]...',
                            border: const OutlineInputBorder(),
                            alignLabelWithHint: true,
                            errorText: _validationError,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        children: [
                          IconButton.filledTonal(
                            tooltip: 'Выбрать .conf файл',
                            onPressed: _busy ? null : _pickFile,
                            icon: const Icon(Icons.attach_file),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _busy ? null : _saveConfig,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save),
                            label: _busy ? const Text('...') : const Text('Сохранить'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SavedConfigsList(),
        ],
      ),
    );
  }
}

/// Список сохранённых конфигов.
class _SavedConfigsList extends ConsumerWidget {
  const _SavedConfigsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configsAsync = ref.watch(savedConfigsProvider);

    return configsAsync.when(
      data: (configs) {
        if (configs.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.inbox_outlined,
                      size: 48, color: Theme.of(context).disabledColor),
                  const SizedBox(height: 12),
                  Text(
                    'Нет сохранённых конфигов',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Добавьте конфиг выше, чтобы он появился здесь.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        }

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Сохранённые конфиги',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...configs.map((cfg) {
                  final id = cfg['id'] as String? ?? '';
                  final name = cfg['name'] as String? ?? 'Без имени';
                  final typeIndex = cfg['type'] as int? ?? 0;
                  final typeName =
                      typeIndex == 0 ? 'AmneziaWG' : 'VLESS';
                  return ListTile(
                    title: Text(name),
                    subtitle: Text('$typeName · $id'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await ref
                            .read(connectionOrchestratorProvider(false))
                            .deleteConfig(id);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Конфиг удалён')),
                          );
                        }
                      },
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, st) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Ошибка загрузки конфигов: $e'),
        ),
      ),
    );
  }
}

/// Провайдер списка сохранённых конфигов.
final savedConfigsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final orchestrator = ref.read(connectionOrchestratorProvider(false));
    return orchestrator.getAllSavedConfigs();
  },
);
