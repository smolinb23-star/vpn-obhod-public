// ignore_for_file: unused_import, unused_element
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vpn_service/core/services/clash_yaml_parser.dart';
import 'package:vpn_service/core/services/mihomo_service.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/core/services/xray_json_parser.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Экран «Управление конфигами».
///
/// Позволяет:
///  - вставлять текст конфига (Clash YAML, .conf, Xray JSON, ссылки);
///  - выбирать файл из памяти устройства;
///  - сохранять конфиги в SQLite (sqflite) между перезапусками;
///  - просматривать список сохранённых конфигов;
///  - редактировать и удалять конфиги.
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('last_config_input');
    if (raw != null && raw.isNotEmpty && mounted) {
      _inputCtrl.text = raw;
    }
  }

  Future<void> _saveLastConfig(String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_config_input', text);
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
    if (RegExp(r'^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}\s*)+$')
        .hasMatch(t)) {
      return true;
    }
    if (RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(t) && t.length > 64) {
      return true;
    }
    return false;
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Выберите конфиг файл',
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
          'Неверный формат конфига. Вставьте ссылку или содержимое файла.');
      return;
    }

    setState(() {
      _validationError = null;
      _busy = true;
    });

    try {
      await _saveLastConfig(input);

      // Определяем тип конфига
      String detectedType = 'other';
      String name = 'Без имени';

      if (WGConfigParser.looksLikeWireGuardConf(input)) {
        final wg = const WGConfigParser().parse(input);
        name = wg.name;
        detectedType = 'awg';
      } else if (ClashYamlParser.looksLikeClashYaml(input)) {
        try {
          final clashConfigs = const ClashYamlParser().parse(input);
          if (clashConfigs.isNotEmpty) {
            name = clashConfigs.first.remark;
            detectedType = 'clash';
          }
        } on Object {
          // ignore parse errors, will save as-is
        }
      } else if (XrayJsonParser.looksLikeWireGuardXrayJson(input)) {
        detectedType = 'xray';
        name = 'Xray JSON';
      }

      final vpnCtrl = ref.read(vpnControllerProvider.notifier);
      final parsed = await vpnCtrl.importProfile(input);
      if (parsed != null) {
        name = parsed.remark;
        detectedType = parsed.type;
      }

      await ref.read(profileRepositoryProvider).saveProfile(ProfileEntity(
        id: name.hashCode.toString(),
        name: name,
        rawConfig: input,
        type: detectedType,
        priority: 0,
        enabled: true,
      ));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Конфиг «$name» сохранён')),
        );
        _inputCtrl.clear();
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка сохранения: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editConfig(ProfileEntity profile) async {
    _inputCtrl.text = profile.rawConfig;
    setState(() => _validationError = null);
  }

  Future<void> _deleteConfig(String id) async {
    await ref.read(profileRepositoryProvider).deleteProfile(id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Конфиг удалён')),
      );
    }
  }

  Future<void> _toggleEnabled(String id, bool value) async {
    await ref.read(profileRepositoryProvider).updateProfile(id, enabled: value);
  }

  Future<void> _setPriority(String id, int priority) async {
    await ref.read(profileRepositoryProvider).updateProfile(id, priority: priority);
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
                    'Вставьте Clash YAML, .conf, Xray JSON или ссылку.\n'
                    'Поддерживаются: AmneziaWG (.conf), Clash/Mihomo YAML, '
                    'VLESS (vless://), Xray JSON, подписки.',
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
                                'Clash YAML, vless://, [Interface]... или {JSON}',
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
                            tooltip: 'Выбрать файл',
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
                            label: _busy
                                ? const Text('...')
                                : const Text('Сохранить'),
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

/// Список сохранённых конфигов с возможностью редактирования и удаления.
class _SavedConfigsList extends ConsumerWidget {
  const _SavedConfigsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) {
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
                ...profiles.map((profile) {
                  return _ConfigListTile(profile: profile);
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

/// Плитка конфига в списке.
class _ConfigListTile extends ConsumerStatefulWidget {
  final ProfileEntity profile;

  const _ConfigListTile({required this.profile});

  @override
  ConsumerState<_ConfigListTile> createState() => _ConfigListTileState();
}

class _ConfigListTileState extends ConsumerState<_ConfigListTile> {
  bool _editing = false;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.profile.name);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: _editing
            ? TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (_) => _saveName(),
              )
            : Text(widget.profile.name),
        subtitle: Text(
          '${widget.profile.type.toUpperCase()} · приоритет ${widget.profile.priority}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: _editing
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: _saveName,
                    tooltip: 'Сохранить',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() => _editing = false);
                      _nameCtrl.text = widget.profile.name;
                    },
                    tooltip: 'Отмена',
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      widget.profile.enabled
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      color: widget.profile.enabled
                          ? Colors.green
                          : Colors.grey,
                    ),
                    onPressed: () async {
                      await ref
                          .read(profileRepositoryProvider)
                          .updateProfile(widget.profile.id,
                              enabled: !widget.profile.enabled);
                    },
                    tooltip: widget.profile.enabled
                        ? 'Отключить'
                        : 'Включить',
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () {
                      setState(() => _editing = true);
                    },
                    tooltip: 'Редактировать',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await ref
                          .read(profileRepositoryProvider)
                          .deleteProfile(widget.profile.id);
                    },
                    tooltip: 'Удалить',
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _saveName() async {
    final newName = _nameCtrl.text.trim();
    if (newName.isNotEmpty && newName != widget.profile.name) {
      await ref.read(profileRepositoryProvider).updateProfile(
            widget.profile.id,
            priority: widget.profile.priority,
          );
      // Пересохраняем с новым именем (создаём новую запись и удаляем старую)
      final repo = ref.read(profileRepositoryProvider);
      await repo.saveProfile(ProfileEntity(
        id: newName.hashCode.toString(),
        name: newName,
        rawConfig: widget.profile.rawConfig,
        type: widget.profile.type,
        priority: widget.profile.priority,
        enabled: widget.profile.enabled,
      ));
      await repo.deleteProfile(widget.profile.id);
    }
    if (mounted) setState(() => _editing = false);
  }
}

/// Провайдер списка профилей из sqflite.
final profilesProvider = FutureProvider<List<ProfileEntity>>(
  (ref) async {
    return ref.read(profileRepositoryProvider).getAllProfiles();
  },
);
