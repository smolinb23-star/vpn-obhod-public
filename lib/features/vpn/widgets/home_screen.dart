import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/advanced_settings_screen.dart';

/// Упрощённый главный экран (Smart Connect).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final TextEditingController _subCtrl = TextEditingController();
  bool _busy = false;
  bool _autoConnect = false;
  String? _validationError;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _subKey = 'smart_connect_input';
  static const _autoKey = 'smart_connect_auto';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final saved = await _storage.read(key: _subKey);
      if (saved != null && saved.isNotEmpty && mounted) {
        _subCtrl.text = saved;
      }
      final auto = await _storage.read(key: _autoKey);
      if (auto == 'true' && mounted) {
        setState(() => _autoConnect = true);
        if (_subCtrl.text.trim().isNotEmpty) {
          await _connect();
        }
      }
    });
  }

  @override
  void dispose() {
    _subCtrl.dispose();
    super.dispose();
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
        dialogTitle: 'Выберите .conf или текстовый конфиг',
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
      final text = String.fromCharCodes(bytes);
      if (!mounted) return;
      _subCtrl.text = text;
      setState(() => _validationError = null);
      await _storage.write(key: _subKey, value: text);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Выбор файла: $e')));
      }
    }
  }

  Future<void> _connect() async {
    final input = _subCtrl.text.trim();
    if (!_isValid(input)) {
      setState(() => _validationError =
          'Неверный формат конфига. Вставьте ссылку или файл.');
      return;
    }
    setState(() {
      _validationError = null;
      _busy = true;
    });
    await _storage.write(key: _subKey, value: input);

    // AmneziaWG .conf → отдельный путь через AWG-контроллер.
    if (WGConfigParser.looksLikeWireGuardConf(input)) {
      try {
        final cfg = const WGConfigParser().parse(input);
        await ref.read(awgSessionProvider.notifier).connect(cfg);
        if (!mounted) return;
        final s = ref.read(awgSessionProvider);
        if (s.up) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('AmneziaWG подключено — ${cfg.name}')),
          );
        } else if (s.error != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(s.error!)));
        }
      } on Object catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('AWG: $e')));
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    try {
      await ref
          .read(vpnControllerProvider.notifier)
          .autoConnect(subscription: input);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(vpnControllerProvider.notifier).disconnect();
    await ref.read(awgSessionProvider.notifier).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final awg = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);
    final connected = ui.state == TunnelState.connected || awg.up;
    final connecting = ui.state == TunnelState.connecting || awg.connecting;

    ref.listen(vpnControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });
    ref.listen(awgSessionProvider, (prev, next) {
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
              if (ui.remark.isNotEmpty || awg.configName != null) ...[
                const SizedBox(height: 4),
                Text(ui.remark.isNotEmpty ? ui.remark : awg.configName!,
                    style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 8),
              Text(
                'Протокол: ${ui.config?.protocol.name ?? (awg.up ? "amneziawg" : "—")}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _MetricChip(
                    icon: Icons.download,
                    label: 'RX',
                    value: formatSpeed(ui.state == TunnelState.connected
                        ? ui.metrics.downloadSpeed
                        : awg.rxSpeed),
                  ),
                  const SizedBox(width: 16),
                  _MetricChip(
                    icon: Icons.upload,
                    label: 'TX',
                    value: formatSpeed(ui.state == TunnelState.connected
                        ? ui.metrics.uploadSpeed
                        : awg.txSpeed),
                  ),
                ],
              ),
              if (ui.ipAfter != null || awg.publicIp != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Публичный IP: ${ui.ipAfter ?? awg.publicIp}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _subCtrl,
                      maxLines: 3,
                      onChanged: (_) {
                        if (_validationError != null) {
                          setState(() => _validationError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText:
                            'Подписка или конфиг (URL / vless:// / .conf)',
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                        errorText: _validationError,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Выбрать файл .conf',
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Switch(
                    value: _autoConnect,
                    onChanged: (v) async {
                      setState(() => _autoConnect = v);
                      await _storage.write(
                          key: _autoKey, value: v ? 'true' : 'false');
                    },
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Автоподключение при запуске'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Вставьте URL подписки, vless:// ссылку или выберите .conf '
                'файл. Приложение само найдёт рабочий сервер (VLESS Reality в '
                'приоритете). На мобильном интернете AmneziaWG может '
                'блокироваться — используйте VLESS.',
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
