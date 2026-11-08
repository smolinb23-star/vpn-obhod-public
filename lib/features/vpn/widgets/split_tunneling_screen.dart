import 'package:device_apps/device_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/vpn/services/connection_orchestrator.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Экран «Исключённые приложения» (Split Tunneling).
///
/// Позволяет выбрать приложения, которые НЕ будут использовать VPN-туннель
/// (трафик пойдёт напрямую через мобильную сеть/Wi-Fi), а также приложения,
/// которые БУДУТ идти через VPN (в режиме «только выбранные»).
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

  List<Application> _allApps = [];
  List<Application> _filteredApps = [];
  final Set<String> _selectedPackages = <String>{};
  SplitTunnelMode _mode = SplitTunnelMode.allThroughVpn;

  bool _loading = true;
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
        _mode = SplitTunnelMode.values.firstWhere(
          (m) => m.index == modeRaw,
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
    try {
      final apps = await DeviceApps.getInstalledApplications(
        includeAppIcons: true,
        includeSystemApps: false,
      );
      apps.sort((a, b) => a.appName.compareTo(b.appName));
      if (mounted) {
        setState(() {
          _allApps = apps;
          _filteredApps = List.from(apps);
          _loading = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
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
            .where((a) => a.appName.toLowerCase().contains(q))
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
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сохранения: $e')),
        );
      }
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
                    'Выберите, какие приложения будут использовать VPN.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
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
                      hintText: 'Введите название приложения',
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
            'Приложения: ${_selectedPackages.length} выбрано',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _selectedPackages.isEmpty
                ? 'Ни одно приложение не выбрано'
                : 'Эти приложения ${
                    _mode == SplitTunnelMode.onlySelected
                        ? 'будут использовать VPN'
                        : 'не будут использовать VPN'
                  }',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_filteredApps.isEmpty)
            const Center(
              child: Text('Ничего не найдено'),
            )
          else
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filteredApps.length,
                itemBuilder: (context, index) {
                  final app = _filteredApps[index];
                  final isSelected = _selectedPackages.contains(
                    app.packageName,
                  );
                  return ListTile(
                    leading: const Icon(Icons.apps),
                    title: Text(app.appName),
                    subtitle: Text(app.packageName),
                    trailing: Checkbox(
                      value: isSelected,
                      onChanged: (_) => _togglePackage(app.packageName),
                    ),
                  );
                },
              ),
            ),
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

/// Режим раздельного туннелирования.
enum SplitTunnelMode {
  allThroughVpn, // Все через VPN
  onlySelected,  // Только выбранные приложения через VPN
  exceptSelected, // Все кроме выбранных через VPN
}

/// Провайдер режима раздельного туннелирования.
final splitTunnelModeProvider =
    StateProvider<SplitTunnelMode>((ref) => SplitTunnelMode.allThroughVpn);

/// Провайдер списка выбранных пакетов.
final selectedAppsProvider =
    StateProvider<Set<String>>((ref) => <String>{});