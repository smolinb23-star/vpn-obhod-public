import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  final Set<String> _selectedPackages = <String>{};
  SplitTunnelMode _mode = SplitTunnelMode.allThroughVpn;

  bool _saving = false;
  String _manualPkgInput = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
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

  void _togglePackage(String packageName) {
    setState(() {
      if (_selectedPackages.contains(packageName)) {
        _selectedPackages.remove(packageName);
      } else {
        _selectedPackages.add(packageName);
      }
    });
  }

  void _addManualPackage() {
    final pkg = _manualPkgInput.trim();
    if (pkg.isNotEmpty && !_selectedPackages.contains(pkg)) {
      setState(() {
        _selectedPackages.add(pkg);
        _manualPkgInput = '';
      });
    }
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
                    'Выберите, какие приложения будут использовать VPN.\n'
                    'Введите имена пакетов вручную (например, com.whatsapp):',
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
                      labelText: 'Имя пакета приложения',
                      hintText: 'например, com.whatsapp',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.android),
                    ),
                    onChanged: (v) => _manualPkgInput = v,
                    onSubmitted: (_) => _addManualPackage(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'В пакетах: ${_selectedPackages.length}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: _addManualPackage,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_selectedPackages.isEmpty)
            const Text(
              'Ни один пакет не добавлен',
              style: TextStyle(fontStyle: FontStyle.italic),
            )
          else ...[
            Text(
              'Добавленные пакеты:',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ..._selectedPackages.map((pkg) {
              return ListTile(
                title: Text(pkg),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _togglePackage(pkg),
                ),
              );
            }),
          ],
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
