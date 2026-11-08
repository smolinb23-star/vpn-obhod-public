import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/models/wireguard_config.dart';
import 'package:vpn_service/core/services/app_log.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/log_export_service.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';
import 'package:vpn_service/features/vpn/vpn_controller.dart';
import 'package:vpn_service/features/vpn/widgets/awg_status_panel.dart';

/// Экран импорта `.conf`-файла Cloudflare WARP / AmneziaWG.
///
/// Три пути импорта:
///  1. файл через file_picker (FileType.any + ручная проверка `.conf`);
///  2. вставка содержимого текстом (обходит любые проблемы SAF/файловой системы);
///  3. нативный AmneziaWG с полной обфускацией, Xray — fallback.
class ConfImportScreen extends ConsumerStatefulWidget {
  const ConfImportScreen({super.key});

  @override
  ConsumerState<ConfImportScreen> createState() => _ConfImportScreenState();
}

class _ConfImportScreenState extends ConsumerState<ConfImportScreen> {
  final WGConfigParser _parser = const WGConfigParser();
  final TextEditingController _pasteCtrl = TextEditingController();
  final LogExportService _logExport = LogExportService();

  String? _fileName;
  WireGuardConfig? _wg;
  VpnConfig? _profile;
  String? _error;
  List<String> _warnings = const [];
  List<String> _parseLog = const [];
  bool _busy = false;
  bool _showLog = false;

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  /// READ_EXTERNAL_STORAGE на Android <= 12. На 13+ SAF не требует разрешений
  /// (READ_MEDIA_* относится к медиа и для .conf бесполезен).
  Future<void> _requestStoragePermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.storage.status;
      appLog.info('ConfImport', 'storage permission: $status');
      if (!status.isGranted && !status.isPermanentlyDenied) {
        final result = await Permission.storage.request();
        appLog.info('ConfImport', 'storage request → $result');
      }
    } on Object catch (e) {
      appLog.warn('ConfImport', 'permission check: $e');
    }
  }

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await _requestStoragePermission();
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Выберите .conf (AmneziaWG / WARP)',
        // FileType.custom с allowedExtensions ['conf'] ломает выбор на части
        // Android-прошивок (MIME application/octet-stream не матчится).
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        appLog.info('ConfImport', 'выбор файла отменён');
        return;
      }
      final file = result.files.first;
      appLog.info('ConfImport', 'выбран файл: ${file.name} '
          '(${file.size} байт, path=${file.path})');

      var bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
        appLog.info('ConfImport', 'байты прочитаны по path: ${bytes.length}');
      }
      if (bytes == null) {
        setState(() => _error = 'Не удалось прочитать файл «${file.name}»: '
            'Android не отдал ни байты, ни путь');
        return;
      }

      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.startsWith('\uFEFF')) text = text.substring(1);

      final isConf = file.name.toLowerCase().endsWith('.conf');
      if (!isConf && !WGConfigParser.looksLikeWireGuardConf(text)) {
        setState(() => _error =
            'Файл «${file.name}» не является .conf WireGuard/AmneziaWG. '
            'Выберите файл с расширением .conf или вставьте текст вручную.');
        return;
      }
      if (!isConf) {
        appLog.warn('ConfImport', 'расширение не .conf, но содержимое похоже '
            'на WireGuard — разбираю');
      }
      _decodeAndParse(file.name, text);
    } on Object catch (e, st) {
      appLog.error('ConfImport', 'pickFile', e);
      debugPrint('$st');
      setState(() => _error = 'Ошибка выбора файла: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _parsePasted() {
    final text = _pasteCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Поле вставки пустое');
      return;
    }
    _decodeAndParse('вставка.conf', text);
  }

  void _decodeAndParse(String name, String text) {
    final log = <String>[];
    try {
      final wg = _parser.parse(text, fallbackName: _baseName(name), logSink: log);
      final profile = _parser.toVpnConfig(wg);
      setState(() {
        _fileName = name;
        _wg = wg;
        _profile = profile;
        _warnings = wg.warnings;
        _parseLog = log;
        _error = null;
        _showLog = wg.warnings.isNotEmpty;
      });
      appLog.info('ConfImport', 'разобран «$name»: '
          '${wg.endpointHost}:${wg.endpointPort}, '
          'amnezia=${wg.amnezia.keys.join(",")}, warnings=${wg.warnings.length}');
    } on WGConfigParseException catch (e) {
      appLog.error('ConfImport', 'parse: ${e.message}');
      setState(() {
        _fileName = name;
        _wg = null;
        _profile = null;
        _warnings = const [];
        _parseLog = log;
        _error = e.message;
        _showLog = true;
      });
    }
  }

  static String _baseName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _connect() async {
    final cfg = _wg;
    if (cfg == null) return;
    setState(() => _busy = true);
    try {
      if (Platform.isAndroid) {
        final notif = await Permission.notification.request();
        appLog.info('ConfImport', 'notification permission → $notif');
      }
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await ref.read(awgSessionProvider.notifier).disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fallback: подключается через Xray wireguard-outbound (plain WG).
  Future<void> _connectViaXray(VpnConfig config) async {
    setState(() => _busy = true);
    try {
      final controller = ref.read(vpnControllerProvider.notifier);
      await controller.saveProfile(config);
      await controller.connect(config);
      if (!mounted) return;
      final ui = ref.read(vpnControllerProvider);
      if (ui.state == TunnelState.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ui.error ?? 'Xray-fallback не удался')),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xray-fallback не удался: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportLogs() async {
    try {
      await _logExport.share();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Экспорт логов: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wg = _wg;
    final session = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Импорт .conf (AmneziaWG)'),
        actions: [
          IconButton(
            tooltip: 'Экспорт логов (logs.txt)',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _exportLogs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
          const SizedBox(height: 12),
          TextField(
            controller: _pasteCtrl,
            minLines: 5,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Вставить содержимое .conf',
              hintText: '[Interface]\nPrivateKey = ...\n[Peer]\n...',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _parsePasted,
            icon: const Icon(Icons.content_paste_go),
            label: const Text('Разобрать вставленный текст'),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          if (wg != null) ...[
            _SummaryCard(wg: wg),
            if (_warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              _WarningsCard(warnings: _warnings),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || session.connecting
                  ? null
                  : (session.up ? _disconnect : _connect),
              icon: _busy || session.connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(session.up ? Icons.link_off : Icons.vpn_lock),
              label: Text(session.up
                  ? 'Отключить AmneziaWG'
                  : 'Подключить через AmneziaWG'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy || session.up || _profile == null
                  ? null
                  : () => _connectViaXray(_profile!),
              icon: const Icon(Icons.router),
              label: const Text('Подключить через Xray (без обфускации)'),
            ),
            if (wg.hasAmnezia) ...[
              const SizedBox(height: 8),
              Text(
                'Amnezia-параметры: ${wg.amnezia.keys.join(', ')} — '
                'применяются нативным движком.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
          const SizedBox(height: 16),
          const AwgStatusPanel(),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Лог парсинга'),
            initiallyExpanded: _showLog,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: theme.colorScheme.surfaceContainerHighest,
                child: SelectableText(
                  _parseLog.isEmpty ? '—' : _parseLog.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Если файл не выбирается — скопируйте содержимое .conf в поле выше. '
            'Кнопка с жуком в AppBar сохраняет logs.txt (Dart + logcat '
            'AwgBridge/AmneziaWG) через share sheet.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _WarningsCard extends StatelessWidget {
  const _WarningsCard({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: ExpansionTile(
        title: Text('Предупреждения парсера (${warnings.length})',
            style: theme.textTheme.bodyMedium),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          for (final w in warnings)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('• $w', style: theme.textTheme.bodySmall),
            ),
        ],
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
            row('DNS', wg.dns.isEmpty ? 'не задан (→ 1.1.1.1)' : wg.dns.join(', ')),
            row('MTU', wg.mtu?.toString() ?? 'из UI (1280)'),
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

  String _shorten(String key) => key.length <= 12
      ? key
      : '${key.substring(0, 8)}…${key.substring(key.length - 3)}';
}
