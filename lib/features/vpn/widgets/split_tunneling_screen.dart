import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:vpn_service/features/vpn/services/app_list_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Экран «Исключённые приложения» (Split Tunneling).
///
/// Список приложений загружается нативно через PackageManager (MethodChannel),
/// иконки отображаются из base64. Ручной ввод пакетов убран.
class SplitTunnelingScreen extends ConsumerStatefulWidget {
  const SplitTunnelingScreen({super.key});

  @override
  ConsumerState<SplitTunnelingScreen> createState() =>
      _SplitTunnelingScreenState();
}

class _SplitTunnelingScreenState extends ConsumerState<SplitTunnelingScreen> {
  final secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _modeKey = 'split_tunnel_mode';
  static const _selectedPkgsKey = 'split_tunnel_selected_packages';

  final Set<String> _selectedPackages = <String>{};
  SplitTunnelMode _mode = SplitTunnelMode.allThroughVpn;

  List<InstalledApp> _allApps = [];
  List<InstalledApp> _filteredApps = [];
  bool _loading = false;
  bool _saving = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadApps();
  }

  Future<void> _loadSettings() async {
    final storage = ref.read(secureStorageProvider);
    final modeRaw = await storage.read(key: _modeKey);
    final pkgsRaw = await storage.read(key: _selectedPkgsKey);

    if (mounted) {
      setState(() {
        final modeIndex = modeRaw != null ? int.tryParse(modeRaw) : null;
        _mode = SplitTunnelMode.values.firstWhere(
          (m) => m.index == modeIndex,
          orElse: () => SplitTunnelMode.allThroughVpn,
        );
        if (pkgsRaw != null && pkgsRaw.isNotEmpty) {
          _selectedPackages.addAll(pkgsRaw.split(','));
        }
      });
    }
  }

  Future<void> _saveSettings() async {
    final storage = ref.read(secureStorageProvider);
    await storage.write(key: _modeKey, value: _mode.index.toString());
    await storage.write(
      key: _selectedPkgsKey,
      value: _selectedPackages.join(','),
    );
  }

  Future<void> _loadApps() async {
    setState(() => _loading = true);
    try {
      final apps = await ref.read(appListServiceProvider).getInstalledApps();
      apps.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) {
        setState(() {
          _allApps = apps;
          _filteredApps = List.from(apps);
          _loading = false;
        });
      }
    } on Object catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filterApps(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredApps = List.from(_allApps);
      } else {
        final q = query.toLowerCase();
        _filteredApps = _allApps
            .where((a) => a.name.toLowerCase().contains(q) ||
                a.packageName.toLowerCase().contains(q))
            .toList();
      }
    });
  }

  void _togglePackage(String packageName) {
    setState(() {
      if (_selectedPackages.contains(packageName)) {
        _selectedPackages.remove(packageName);
      } else {
        _selectedPackages.add(packageName);
      }
    });
  }

  bool _isSelected(String packageName) =>
      _selectedPackages.contains(packageName);

  Widget _buildAppIcon(InstalledApp app) {
    if (app.iconBytes != null && app.iconBytes!.isNotEmpty) {
      return Image.memory(
        app.iconBytes!,
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.apps),
      );
    }
    return const Icon(Icons.apps);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _saveSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Настройки раздельного туннелирования сохранены',
            ),
          ),
        );
        Navigator.of(context).pop(_selectedPackages);
      }
    } on Object catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Исключённые приложения'),
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
                    'Режим раздельного туннелирования',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Выберите приложения из списка ниже. '
                    'Иконки и названия загружаются из системы.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  ...SplitTunnelMode.values.map((mode) {
                    return ListTile(
                      leading: Radio<SplitTunnelMode>(
                        value: mode,
                        groupValue: _mode,
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _mode = v);
                          }
                        },
                      ),
                      title: Text(_getModeTitle(mode)),
                      subtitle: Text(_getModeSubtitle(mode)),
                    );
                  }),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Поиск приложений',
                      hintText: 'Название или пакет приложения',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: _filterApps,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Приложений: ${_allApps.length}, выбрано: ${_selectedPackages.length}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_filteredApps.isEmpty)
            const Center(
              child: Text('Ничего не найдено'),
            )
          else
            ..._filteredApps.map((app) {
              return ListTile(
                leading: _buildAppIcon(app),
                title: Text(app.name),
                subtitle: Text(app.packageName),
                trailing: Checkbox(
                  value: _isSelected(app.packageName),
                  onChanged: (_) => _togglePackage(app.packageName),
                ),
              );
            }),
        ],
      ),
      bottomNavigationBar: _selectedPackages.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? '...' : 'Сохранить'),
              ),
            ),
    );
  }

  String _getModeTitle(SplitTunnelMode mode) {
    switch (mode) {
      case SplitTunnelMode.allThroughVpn:
        return 'Все приложения через VPN';
      case SplitTunnelMode.onlySelected:
        return 'Только выбранные приложения через VPN';
      case SplitTunnelMode.exceptSelected:
        return 'Все, кроме выбранных';
    }
  }

  String _getModeSubtitle(SplitTunnelMode mode) {
    switch (mode) {
      case SplitTunnelMode.allThroughVpn:
        return 'Весь трафик идёт через VPN-туннель';
      case SplitTunnelMode.onlySelected:
        return 'Только выбранные приложения будут идти через VPN';
      case SplitTunnelMode.exceptSelected:
        return 'Все приложения кроме выбранных будут идти через VPN';
    }
  }
}
