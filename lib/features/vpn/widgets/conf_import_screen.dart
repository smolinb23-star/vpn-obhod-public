import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';

/// Экран импорта `.conf`-файла Cloudflare WARP / AmneziaWG.
///
/// Пользователь выбирает файл из памяти устройства, приложение разбирает
/// WireGuard-конфиг (включая Amnezia-расширения), показывает сводку и по
/// кнопке поднимает туннель через Xray wireguard-outbound.
class ConfImportScreen extends ConsumerStatefulWidget {
  const ConfImportScreen({super.key});

  @override
  ConsumerState<ConfImportScreen> createState() => _ConfImportScreenState();
}

class _ConfImportScreenState extends ConsumerState<ConfImportScreen> {
  final WGConfigParser _parser = const WGConfigParser();

  String? _fileName;
  WireGuardConfig? _wg;
  VpnConfig? _profile;
  String? _error;
  bool _busy = false;

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Выберите .conf (AmneziaWG / WARP)',
        type: FileType.custom,
        allowedExtensions: const ['conf', 'txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return; // пользователь отменил
      }
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        setState(() => _error = 'Не удалось прочитать файл');
        return;
      }
      _decodeAndParse(file.name, bytes);
    } on Object catch (e) {
      setState(() => _error = 'Ошибка выбора файла: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _decodeAndParse(String name, List<int> bytes) {
    try {
      // Снимаем UTF-8 BOM, если экспорт добавила Windows-утилита.
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.startsWith('\uFEFF')) text = text.substring(1);

      final wg = _parser.parse(text, fallbackName: _baseName(name));
      final profile = _parser.toVpnConfig(wg);
      setState(() {
        _fileName = name;
        _wg = wg;
        _profile = profile;
        _error = null;
      });
    } on WGConfigParseException catch (e) {
      setState(() {
        _fileName = name;
        _wg = null;
        _profile = null;
        _error = e.message;
      });
    }
  }

  static String _baseName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _connect() async {
    final profile = _profile;
    final wg = _wg;
    if (profile == null || wg == null) return;
    setState(() => _busy = true);
    try {
      final controller = ref.read(vpnControllerProvider.notifier);
      await controller.saveProfile(profile);
      await controller.connect(profile);
      if (!mounted) return;
      // Возврат на главный экран — там виден статус подключения.
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Подключение не удалось: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(vpnControllerProvider);
    final wg = _wg;
    final tunnelActive = ui.state == TunnelState.connected ||
        ui.state == TunnelState.connecting;

    return Scaffold(
      appBar: AppBar(title: const Text('Импорт .conf (AmneziaWG)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.folder_open),
              label: Text(_fileName == null
                  ? 'Выбрать .conf из памяти устройства'
                  : 'Другой файл: $_fileName'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              ),
            if (wg != null) ...[
              _SummaryCard(wg: wg),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy || tunnelActive ? null : _connect,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.vpn_lock),
                label: const Text('Подключить WireGuard-туннель'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              if (wg.hasAmnezia) ...[
                const SizedBox(height: 12),
                Text(
                  'Amnezia-параметры обнаружены (${wg.amnezia.keys.join(', ')}). '
                  'Через Xray они не применяются — туннель поднимется как '
                  'обычный WireGuard.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.wg});

  final WireGuardConfig wg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: Text(label,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(wg.name, style: theme.textTheme.titleMedium),
            const Divider(),
            row('Endpoint', '${wg.endpointHost}:${wg.endpointPort}'),
            row('PublicKey', _shorten(wg.peerPublicKey)),
            row('PrivateKey', '✓ загружен (${_shorten(wg.privateKey)})'),
            if (wg.peerPresharedKey != null)
              row('PresharedKey', '✓ (${_shorten(wg.peerPresharedKey!)})'),
            row('Address', wg.addresses.join(', ')),
            row('AllowedIPs', wg.allowedIps.join(', ')),
            if (wg.dns.isNotEmpty) row('DNS', wg.dns.join(', ')),
            if (wg.mtu != null) row('MTU', '${wg.mtu}'),
            row('Keepalive', '${wg.persistentKeepalive} c'),
            if (wg.hasAmnezia)
              row('Amnezia', wg.amnezia.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join(', ')),
          ],
        ),
      ),
    );
  }

  String _shorten(String key) =>
      key.length <= 12 ? key : '${key.substring(0, 8)}…${key.substring(key.length - 3)}';
}
