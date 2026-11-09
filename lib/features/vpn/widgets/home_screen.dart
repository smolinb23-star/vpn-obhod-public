import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/config_management_screen.dart';
import 'package:vpn_service/features/vpn/widgets/split_tunneling_screen.dart';

/// Главный экран Mihomo VPN.
///
/// - Большая кнопка «Подключиться».
/// - Список серверов с флагами стран.
/// - Выпадающий список выбора конфига (страна).
/// - Статус «Подключено через [имя лучшего сервера]».
/// - Кнопка «Сбросить / Остановить» для жёсткого отключения.
/// - Нет сложных настроек (I1, MTU) на главном экране.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _busy = false;
  VpnConfig? _selectedConfig;

  @override
  void initState() {
    super.initState();
    // Автоподключение при запуске если есть профили.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final profiles = await ref.read(profilesProvider.future);
      if (profiles.isNotEmpty && mounted) {
        // Выбираем первый профиль по умолчанию
        _selectedConfig = VpnConfig(
          remark: profiles.first.name,
          protocol: ProfileProtocol.values.firstWhere(
            (p) => p.name == profiles.first.type,
            orElse: () => ProfileProtocol.other,
          ),
          xrayJson: profiles.first.rawConfig,
          profileType: ProfileType.values.firstWhere(
            (p) => p.name == profiles.first.type,
            orElse: () => ProfileType.other,
          ),
          rawConfig: profiles.first.rawConfig,
          type: profiles.first.type,
        );
        await _connect();
      }
    });
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);

    final controller = ref.read(vpnControllerProvider.notifier);
    await controller.autoConnect();

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connectSelected() async {
    if (_busy) return;
    setState(() => _busy = true);

    final controller = ref.read(vpnControllerProvider.notifier);
    if (_selectedConfig != null) {
      await controller.connect(_selectedConfig!);
    } else {
      await controller.autoConnect();
    }

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);

    final controller = ref.read(vpnControllerProvider.notifier);
    await controller.disconnect();

    if (mounted) setState(() => _busy = false);
  }

  /// Жёсткий сброс: отключает VPN и убивает нативный процесс.
  Future<void> _hardReset() async {
    if (_busy) return;
    setState(() => _busy = true);

    final controller = ref.read(vpnControllerProvider.notifier);
    await controller.hardReset();

    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('VPN полностью остановлен'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final theme = Theme.of(context);
    final connected = ui.state == TunnelState.connected;
    final connecting = ui.state == TunnelState.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN · Mihomo'),
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
              // Статус подключения.
              Text(
                connected
                    ? 'Подключено'
                    : (connecting ? 'Подключение…' : 'Отключено'),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (ui.currentServer.isNotEmpty)
                Text(
                  connected
                      ? 'Через ${ui.currentServer}'
                      : (ui.remark.isNotEmpty ? ui.remark : 'Готово'),
                  style: theme.textTheme.bodyMedium,
                ),
              const SizedBox(height: 12),
              // Выпадающий список конфигов.
              const _ConfigSelector(),
              const SizedBox(height: 24),
              // Большая кнопка подключения.
              GestureDetector(
                onTap: connecting || _busy
                    ? null
                    : (connected ? _disconnect : _connectSelected),
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
              // Кнопки управления.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (connected) ...[
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _disconnect,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Отключиться'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _hardReset,
                      icon: const Icon(Icons.power_settings_new, color: Colors.red),
                      label: const Text(
                        'Сбросить',
                        style: TextStyle(color: Colors.red),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _hardReset,
                      icon: const Icon(Icons.power_settings_new, color: Colors.grey),
                      label: const Text('Сбросить'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              // Список серверов.
              const _ServerList(),
              const SizedBox(height: 24),
              // Индикатор раздельного туннелирования.
              if (ui.state == TunnelState.connected) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SplitTunnelingScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.apps),
                  label: const Text('Исключённые приложения'),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Выпадающий список конфигов со странами.
class _ConfigSelector extends ConsumerWidget {
  const _ConfigSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) {
          return const Text(
            'Нет серверов. Добавьте конфиг в управлении.',
            style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Серверы (${profiles.length}):',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButton<String>(
              isExpanded: true,
              value: null,
              hint: const Text('Выберите сервер…'),
              items: profiles.map((profile) {
                final flag = _flagForName(profile.name);
                return DropdownMenuItem<String>(
                  value: profile.name,
                  child: Row(
                    children: [
                      Text(flag, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      Text(profile.name),
                    ],
                  ),
                );
              }).toList(),
              onChanged: null, // Выбор через _ServerList
            ),
          ],
        );
      },
      loading: () => const CircularProgressIndicator(),
      error: (e, st) => Text('Ошибка загрузки серверов: $e'),
    );
  }

  String _flagForName(String name) {
    final upper = name.toUpperCase();
    const codes = <String, String>{
      'PL': '🇵🇱', 'NL': '🇳🇱', 'FI': '🇫🇮', 'RU': '🇷🇺', 'US': '🇺🇸',
      'DE': '🇩🇪', 'FR': '🇫🇷', 'GB': '🇬🇧', 'JP': '🇯🇵', 'SG': '🇸🇬',
      'HK': '🇭🇰', 'KR': '🇰🇷', 'CA': '🇨🇦', 'AU': '🇦🇺', 'CH': '🇨🇭',
      'SE': '🇸🇪', 'NO': '🇳🇴', 'DK': '🇩🇰', 'IE': '🇮🇪', 'ES': '🇪🇸',
      'IT': '🇮🇹', 'PT': '🇵🇹', 'BR': '🇧🇷', 'AR': '🇦🇷', 'MX': '🇲🇽',
      'IN': '🇮🇳', 'ID': '🇮🇩', 'TH': '🇹🇭', 'VN': '🇻🇳', 'TR': '🇹🇷',
      'AE': '🇦🇪', 'SA': '🇸🇦', 'IL': '🇮🇱', 'ZA': '🇿🇦', 'EG': '🇪🇬',
    };
    for (final entry in codes.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return '🌐';
  }
}

/// Список серверов из сохранённых профилей.
class _ServerList extends ConsumerWidget {
  const _ServerList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) {
          return const Text(
            'Нет серверов. Добавьте конфиг в управлении.',
            style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Серверы (${profiles.length}):',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...profiles.map((profile) {
              final flag = _flagForName(profile.name);
              return ListTile(
                leading: Text(flag, style: const TextStyle(fontSize: 24)),
                title: Text(profile.name),
                subtitle: Text(profile.type.toUpperCase()),
                trailing: Icon(
                  profile.enabled
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                  color: profile.enabled ? Colors.green : Colors.grey,
                ),
                onTap: () async {
                  await ref.read(profileRepositoryProvider).updateProfile(
                        profile.id,
                        priority: 0,
                      );
                  // Подключаемся к выбранному серверу.
                  final controller = ref.read(vpnControllerProvider.notifier);
                  await controller.connect(VpnConfig(
                    remark: profile.name,
                    protocol: ProfileProtocol.other,
                    xrayJson: profile.rawConfig,
                    profileType: ProfileType.values.firstWhere(
                      (p) => p.name == profile.type,
                      orElse: () => ProfileType.other,
                    ),
                    rawConfig: profile.rawConfig,
                    type: profile.type,
                  ));
                },
              );
            }),
          ],
        );
      },
      loading: () => const CircularProgressIndicator(),
      error: (e, st) => Text('Ошибка загрузки серверов: $e'),
    );
  }

  String _flagForName(String name) {
    final upper = name.toUpperCase();
    const codes = <String, String>{
      'PL': '🇵🇱', 'NL': '🇳🇱', 'FI': '🇫🇮', 'RU': '🇷🇺', 'US': '🇺🇸',
      'DE': '🇩🇪', 'FR': '🇫🇷', 'GB': '🇬🇧', 'JP': '🇯🇵', 'SG': '🇸🇬',
      'HK': '🇭🇰', 'KR': '🇰🇷', 'CA': '🇨🇦', 'AU': '🇦🇺', 'CH': '🇨🇭',
      'SE': '🇸🇪', 'NO': '🇳🇴', 'DK': '🇩🇰', 'IE': '🇮🇪', 'ES': '🇪🇸',
      'IT': '🇮🇹', 'PT': '🇵🇹', 'BR': '🇧🇷', 'AR': '🇦🇷', 'MX': '🇲🇽',
      'IN': '🇮🇳', 'ID': '🇮🇩', 'TH': '🇹🇭', 'VN': '🇻🇳', 'TR': '🇹🇷',
      'AE': '🇦🇪', 'SA': '🇸🇦', 'IL': '🇮🇱', 'ZA': '🇿🇦', 'EG': '🇪🇬',
    };
    for (final entry in codes.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return '🌐';
  }
}
