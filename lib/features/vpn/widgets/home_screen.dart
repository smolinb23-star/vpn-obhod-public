import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vpn_service/core/services/profile_repository.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/config_management_screen.dart';
import 'package:vpn_service/features/vpn/widgets/split_tunneling_screen.dart';

/// Главный экран VPN.
///
/// - Большая кнопка «Подключиться / Отключиться».
/// - Выпадающий список сохранённых серверов (страны/флаги) — выбор
///   принудительно подключает именно этот сервер.
/// - Красная кнопка «Остановить» (жёсткий сброс VPN).
/// - Баннер ошибки (таймаут / TUN / разрешение).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const String _selectedKey = 'selected_profile_id';

  bool _busy = false;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _restoreSelected();
  }

  /// Восстанавливает последний выбранный сервер между запусками.
  Future<void> _restoreSelected() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_selectedKey);
    if (id != null && id.isNotEmpty && mounted) {
      setState(() => _selectedId = id);
    }
  }

  Future<void> _persistSelected(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedKey, id);
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } on Object {
      // На старых Android разрешение не нужно.
    }
  }

  Future<void> _connectProfile(ProfileEntity profile) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _selectedId = profile.id;
    });
    await _persistSelected(profile.id);
    await _requestNotificationPermission();
    try {
      await ref.read(vpnControllerProvider.notifier).connectProfile(profile);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectSelected() async {
    if (_busy) return;
    final profiles = await ref.read(profilesProvider.future);
    if (profiles.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нет серверов. Добавьте конфиг в управлении.'),
          ),
        );
      }
      return;
    }
    final selected = profiles.firstWhere(
      (p) => p.id == _selectedId,
      orElse: () => profiles.first,
    );
    await _connectProfile(selected);
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(vpnControllerProvider.notifier).disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Жёсткий сброс: отключает VPN, убивает нативный туннель и уведомление.
  Future<void> _forceStop() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(vpnControllerProvider.notifier).forceResetVpn();
    } finally {
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
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final profilesAsync = ref.watch(profilesProvider);
    final theme = Theme.of(context);
    final connected = ui.state == TunnelState.connected;
    final connecting = ui.state == TunnelState.connecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN · Обход'),
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
              Text(
                connected
                    ? 'VPN активен'
                    : (connecting
                        ? 'Подключение…'
                        : (ui.state == TunnelState.error
                            ? 'Ошибка'
                            : 'Отключено')),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (ui.currentServer.isNotEmpty)
                Text(
                  connected ? 'Через ${ui.currentServer}' : ui.remark,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              if (ui.ipAfter != null) ...[
                const SizedBox(height: 4),
                Text(
                  'IP: ${ui.ipAfter}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              _ConfigSelector(
                profilesAsync: profilesAsync,
                selectedId: _selectedId,
                enabled: !_busy &&
                    !connecting &&
                    ui.state != TunnelState.connected,
                onSelected: _connectProfile,
              ),
              if (ui.error != null) ...[
                const SizedBox(height: 16),
                _ErrorBanner(message: ui.error!),
              ],
              const SizedBox(height: 24),
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
                  ],
                  FilledButton.icon(
                    onPressed: _busy ? null : _forceStop,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Остановить'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _ServerList(
                profilesAsync: profilesAsync,
                selectedId: _selectedId,
                enabled: !_busy && !connecting,
                onSelected: _connectProfile,
              ),
              if (connected) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SplitTunnelingScreen(),
                            ),
                          ),
                  icon: const Icon(Icons.apps),
                  label: const Text('Исключённые приложения'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Баннер ошибки подключения.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

/// Выпадающий список конфигов со странами.
class _ConfigSelector extends StatelessWidget {
  const _ConfigSelector({
    required this.profilesAsync,
    required this.selectedId,
    required this.enabled,
    required this.onSelected,
  });

  final AsyncValue<List<ProfileEntity>> profilesAsync;
  final String? selectedId;
  final bool enabled;
  final ValueChanged<ProfileEntity> onSelected;

  @override
  Widget build(BuildContext context) {
    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) {
          return const Text(
            'Нет серверов. Добавьте конфиг в управлении.',
            style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          );
        }
        final ids = profiles.map((p) => p.id).toSet();
        final value = ids.contains(selectedId) ? selectedId : null;
        return InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Сервер (страна)',
            border: OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              hint: const Text('Выберите сервер…'),
              items: profiles.map((profile) {
                return DropdownMenuItem<String>(
                  value: profile.id,
                  child: Row(
                    children: [
                      Text(flagForName(profile.name),
                          style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          profile.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
              onChanged: enabled
                  ? (id) {
                      final profile = profiles.firstWhere((p) => p.id == id);
                      onSelected(profile);
                    }
                  : null,
            ),
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: CircularProgressIndicator(),
      ),
      error: (e, st) => Text('Ошибка загрузки серверов: $e'),
    );
  }
}

/// Список серверов из сохранённых профилей.
class _ServerList extends StatelessWidget {
  const _ServerList({
    required this.profilesAsync,
    required this.selectedId,
    required this.enabled,
    required this.onSelected,
  });

  final AsyncValue<List<ProfileEntity>> profilesAsync;
  final String? selectedId;
  final bool enabled;
  final ValueChanged<ProfileEntity> onSelected;

  @override
  Widget build(BuildContext context) {
    return profilesAsync.when(
      data: (profiles) {
        if (profiles.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Сохранённые серверы (${profiles.length}):',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...profiles.map((profile) {
              final selected = profile.id == selectedId;
              return ListTile(
                leading: Text(flagForName(profile.name),
                    style: const TextStyle(fontSize: 24)),
                title: Text(profile.name),
                subtitle: Text(profile.type.toUpperCase()),
                trailing: Icon(
                  selected ? Icons.check_circle : Icons.chevron_right,
                  color: selected ? Colors.green : null,
                ),
                enabled: enabled,
                onTap: enabled ? () => onSelected(profile) : null,
              );
            }),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (e, st) => Text('Ошибка загрузки серверов: $e'),
    );
  }
}

/// Флаг страны по названию/коду сервера (🇳🇱 Нидерланды и т.п.).
///
/// Сначала ищем названия стран и городов (рус/англ), затем двухбуквенный
/// код как отдельный токен — чтобы «BERLIN» не превращался в 🇮🇳 (IN).
String flagForName(String name) {
  final upper = name.toUpperCase();

  const named = <String, String>{
    // Нидерланды
    'НИДЕРЛАНД': '🇳🇱', 'ГОЛЛАНД': '🇳🇱', 'АМСТЕРДАМ': '🇳🇱',
    'NETHERLANDS': '🇳🇱', 'HOLLAND': '🇳🇱', 'AMSTERDAM': '🇳🇱',
    // Финляндия
    'ФИНЛЯНД': '🇫🇮', 'ХЕЛЬСИНКИ': '🇫🇮', 'FINLAND': '🇫🇮',
    'HELSINKI': '🇫🇮',
    // Германия
    'ГЕРМАН': '🇩🇪', 'БЕРЛИН': '🇩🇪', 'ФРАНКФУРТ': '🇩🇪',
    'GERMANY': '🇩🇪', 'BERLIN': '🇩🇪', 'FRANKFURT': '🇩🇪',
    // Польша
    'ПОЛЬШ': '🇵🇱', 'ВАРШАВ': '🇵🇱', 'POLAND': '🇵🇱', 'WARSAW': '🇵🇱',
    // Франция
    'ФРАНЦ': '🇫🇷', 'ПАРИЖ': '🇫🇷', 'FRANCE': '🇫🇷', 'PARIS': '🇫🇷',
    // США
    'США': '🇺🇸', 'АМЕРИК': '🇺🇸', 'НЬЮ-ЙОРК': '🇺🇸', 'СИЭТЛ': '🇺🇸',
    'ЛОС-АНДЖЕЛЕС': '🇺🇸', 'МАЙАМИ': '🇺🇸', 'USA': '🇺🇸',
    'UNITED STATES': '🇺🇸', 'NEW YORK': '🇺🇸', 'SEATTLE': '🇺🇸',
    'LOS ANGELES': '🇺🇸', 'MIAMI': '🇺🇸',
    // Великобритания
    'ВЕЛИКОБРИТАН': '🇬🇧', 'АНГЛИ': '🇬🇧', 'ЛОНДОН': '🇬🇧',
    'UNITED KINGDOM': '🇬🇧', 'LONDON': '🇬🇧', 'ENGLAND': '🇬🇧',
    // Канада
    'КАНАД': '🇨🇦', 'ТОРОНТО': '🇨🇦', 'CANADA': '🇨🇦', 'TORONTO': '🇨🇦',
    // Швеция
    'ШВЕЦИ': '🇸🇪', 'СТОКГОЛЬМ': '🇸🇪', 'SWEDEN': '🇸🇪', 'STOCKHOLM': '🇸🇪',
    // Норвегия
    'НОРВЕГИ': '🇳🇴', 'ОСЛО': '🇳🇴', 'NORWAY': '🇳🇴', 'OSLO': '🇳🇴',
    // Дания
    'ДАНИ': '🇩🇰', 'КОПЕНГАГЕН': '🇩🇰', 'DENMARK': '🇩🇰',
    'COPENHAGEN': '🇩🇰',
    // Швейцария
    'ШВЕЙЦАРИ': '🇨🇭', 'ЦЮРИХ': '🇨🇭', 'SWITZERLAND': '🇨🇭', 'ZURICH': '🇨🇭',
    // Австрия
    'АВСТРИ': '🇦🇹', 'ВЕНА': '🇦🇹', 'AUSTRIA': '🇦🇹', 'VIENNA': '🇦🇹',
    // Испания
    'ИСПАНИ': '🇪🇸', 'МАДРИД': '🇪🇸', 'SPAIN': '🇪🇸', 'MADRID': '🇪🇸',
    // Италия
    'ИТАЛИ': '🇮🇹', 'МИЛАН': '🇮🇹', 'ITALY': '🇮🇹', 'MILAN': '🇮🇹',
    // Турция
    'ТУРЦИ': '🇹🇷', 'СТАМБУЛ': '🇹🇷', 'TURKEY': '🇹🇷', 'ISTANBUL': '🇹🇷',
    // Япония
    'ЯПОНИ': '🇯🇵', 'ТОКИО': '🇯🇵', 'JAPAN': '🇯🇵', 'TOKYO': '🇯🇵',
    // Сингапур / Гонконг / Корея
    'СИНГАПУР': '🇸🇬', 'SINGAPORE': '🇸🇬',
    'ГОНКОНГ': '🇭🇰', 'HONG KONG': '🇭🇰', 'HONGKONG': '🇭🇰',
    'КОРЕЯ': '🇰🇷', 'СЕУЛ': '🇰🇷', 'KOREA': '🇰🇷', 'SEOUL': '🇰🇷',
    // Австралия
    'АВСТРАЛИ': '🇦🇺', 'СИДНЕЙ': '🇦🇺', 'AUSTRALIA': '🇦🇺', 'SYDNEY': '🇦🇺',
    // Индия / Бразилия
    'ИНДИЯ': '🇮🇳', 'МУМБАИ': '🇮🇳', 'INDIA': '🇮🇳', 'MUMBAI': '🇮🇳',
    'БРАЗИЛИ': '🇧🇷', 'BRAZIL': '🇧🇷',
    // Балтия / СНГ
    'ЛАТВИ': '🇱🇻', 'РИГА': '🇱🇻', 'LATVIA': '🇱🇻', 'RIGA': '🇱🇻',
    'ЛИТВ': '🇱🇹', 'ВИЛЬНЮС': '🇱🇹', 'LITHUANIA': '🇱🇹',
    'ЭСТОНИ': '🇪🇪', 'ТАЛЛИН': '🇪🇪', 'ESTONIA': '🇪🇪', 'TALLINN': '🇪🇪',
    'УКРАИН': '🇺🇦', 'КИЕВ': '🇺🇦', 'UKRAINE': '🇺🇦',
    'КАЗАХСТАН': '🇰🇿', 'АЛМАТЫ': '🇰🇿', 'KAZAKHSTAN': '🇰🇿',
    'АРМЕНИ': '🇦🇲', 'ЕРЕВАН': '🇦🇲', 'ARMENIA': '🇦🇲',
    'ГРУЗИ': '🇬🇪', 'ТБИЛИСИ': '🇬🇪', 'GEORGIA': '🇬🇪',
    'МОЛДОВ': '🇲🇩', 'КИШИН': '🇲🇩', 'MOLDOVA': '🇲🇩',
    // Прочее
    'ЧЕХИ': '🇨🇿', 'ПРАГА': '🇨🇿', 'CZECH': '🇨🇿', 'PRAGUE': '🇨🇿',
    'РУМЫНИ': '🇷🇴', 'БУХАРЕСТ': '🇷🇴', 'ROMANIA': '🇷🇴',
    'БОЛГАРИ': '🇧🇬', 'СОФИЯ': '🇧🇬', 'BULGARIA': '🇧🇬',
    'ВЕНГРИ': '🇭🇺', 'БУДАПЕШТ': '🇭🇺', 'HUNGARY': '🇭🇺',
    'ГРЕЦИ': '🇬🇷', 'АФИНЫ': '🇬🇷', 'GREECE': '🇬🇷',
    'ИЗРАИЛ': '🇮🇱', 'ISRAEL': '🇮🇱',
    'ОАЭ': '🇦🇪', 'ДУБАЙ': '🇦🇪', 'DUBAI': '🇦🇪', 'EMIRATES': '🇦🇪',
    'СЕРБИ': '🇷🇸', 'БЕЛГРАД': '🇷🇸', 'SERBIA': '🇷🇸',
    'ИРЛАНД': '🇮🇪', 'ДУБЛИН': '🇮🇪', 'IRELAND': '🇮🇪', 'DUBLIN': '🇮🇪',
    'БЕЛЬГИ': '🇧🇪', 'БРЮССЕЛЬ': '🇧🇪', 'BELGIUM': '🇧🇪',
    'ПОРТУГАЛИ': '🇵🇹', 'ЛИССАБОН': '🇵🇹', 'PORTUGAL': '🇵🇹',
    'МЕКСИК': '🇲🇽', 'MEXICO': '🇲🇽',
    'АРГЕНТИН': '🇦🇷', 'ARGENTINA': '🇦🇷',
    'ВЬЕТНАМ': '🇻🇳', 'VIETNAM': '🇻🇳',
    'ТАИЛАНД': '🇹🇭', 'БАНГКОК': '🇹🇭', 'THAILAND': '🇹🇭',
    'ИНДОНЕЗИ': '🇮🇩', 'INDONESIA': '🇮🇩',
    'МАЛАЙЗИ': '🇲🇾', 'MALAYSIA': '🇲🇾',
    'ФИЛИППИН': '🇵🇭', 'PHILIPPINES': '🇵🇭',
    'ТАЙВАНЬ': '🇹🇼', 'TAIWAN': '🇹🇼',
    'НОВАЯ ЗЕЛАНДИЯ': '🇳🇿', 'NEW ZEALAND': '🇳🇿',
    'ИСЛАНДИ': '🇮🇸', 'ICELAND': '🇮🇸',
    'РОССИ': '🇷🇺', 'МОСКВА': '🇷🇺', 'RUSSIA': '🇷🇺', 'MOSCOW': '🇷🇺',
  };
  for (final entry in named.entries) {
    if (upper.contains(entry.key)) return entry.value;
  }

  const codes = <String, String>{
    'PL': '🇵🇱', 'NL': '🇳🇱', 'FI': '🇫🇮', 'RU': '🇷🇺', 'US': '🇺🇸',
    'DE': '🇩🇪', 'FR': '🇫🇷', 'GB': '🇬🇧', 'UK': '🇬🇧', 'JP': '🇯🇵',
    'SG': '🇸🇬', 'HK': '🇭🇰', 'KR': '🇰🇷', 'CA': '🇨🇦', 'AU': '🇦🇺',
    'CH': '🇨🇭', 'SE': '🇸🇪', 'NO': '🇳🇴', 'DK': '🇩🇰', 'IE': '🇮🇪',
    'ES': '🇪🇸', 'IT': '🇮🇹', 'PT': '🇵🇹', 'BR': '🇧🇷', 'AR': '🇦🇷',
    'MX': '🇲🇽', 'IN': '🇮🇳', 'ID': '🇮🇩', 'TH': '🇹🇭', 'VN': '🇻🇳',
    'TR': '🇹🇷', 'AE': '🇦🇪', 'SA': '🇸🇦', 'IL': '🇮🇱', 'ZA': '🇿🇦',
    'EG': '🇪🇬', 'LV': '🇱🇻', 'LT': '🇱🇹', 'EE': '🇪🇪', 'UA': '🇺🇦',
    'KZ': '🇰🇿', 'AM': '🇦🇲', 'GE': '🇬🇪', 'MD': '🇲🇩', 'RO': '🇷🇴',
    'CZ': '🇨🇿', 'AT': '🇦🇹', 'BE': '🇧🇪', 'GR': '🇬🇷', 'HU': '🇭🇺',
    'BG': '🇧🇬', 'RS': '🇷🇸', 'HR': '🇭🇷', 'SI': '🇸🇮', 'SK': '🇸🇰',
    'NZ': '🇳🇿', 'IS': '🇮🇸', 'MY': '🇲🇾', 'PH': '🇵🇭', 'TW': '🇹🇼',
  };
  // Двухбуквенный код только как отдельный токен: NL-1, us.example, [DE].
  final token = RegExp(r'(^|[^A-Z])([A-Z]{2})([^A-Z]|$)');
  for (final match in token.allMatches(upper)) {
    final flag = codes[match.group(2)];
    if (flag != null) return flag;
  }
  return '🌐';
}
