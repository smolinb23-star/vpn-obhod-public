import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/log_export_service.dart';
import 'package:vpn_service/features/vpn/services/tunnel_diagnostics.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Экран «Диагностика»: AllowedIPs/DNS активного конфига, ping 1.1.1.1,
/// HTTP-запрос к api.ipify.org внутри туннеля и экспорт логов.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  final LogExportService _logExport = LogExportService();

  PingResult? _ping;
  HttpProbeResult? _http;
  bool _pingBusy = false;
  bool _httpBusy = false;
  bool _exporting = false;

  Future<void> _runPing() async {
    setState(() {
      _pingBusy = true;
      _ping = null;
    });
    final result = await TunnelDiagnostics.ping('1.1.1.1');
    if (!mounted) return;
    setState(() {
      _ping = result;
      _pingBusy = false;
    });
  }

  Future<void> _runHttp() async {
    setState(() {
      _httpBusy = true;
      _http = null;
    });
    final result =
        await TunnelDiagnostics.httpGet('https://api.ipify.org');
    if (!mounted) return;
    setState(() {
      _http = result;
      _httpBusy = false;
    });
  }

  Future<void> _exportLogs() async {
    setState(() => _exporting = true);
    try {
      await _logExport.share();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Экспорт логов: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика'),
        actions: [
          IconButton(
            tooltip: 'Экспорт логов (logs.txt)',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _exporting ? null : _exportLogs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (s.dpiSuspected)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Похоже на DPI-блокировку после handshake: RX '
                  '${formatBytes(s.status.rx)}, TX '
                  '${formatBytes(s.status.tx)}, потери '
                  '${((s.lossRatio ?? 0) * 100).toStringAsFixed(0)}%. '
                  'Попробуйте I1 на главном экране и MTU 1180/1200.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          _Section(
            title: 'Активный конфиг',
            children: [
              _InfoRow('Профиль', s.configName ?? '—'),
              _InfoRow('Endpoint', s.endpoint ?? '—'),
              _InfoRow('Address', s.addresses.isEmpty ? '—' : s.addresses.join(', ')),
              _InfoRow('MTU', '${s.mtu}'),
              _InfoRow(
                'I1',
                s.i1.isEmpty ? 'не задан (без спецпакета)' : s.i1,
                monospace: true,
              ),
              _InfoRow(
                'AllowedIPs',
                s.allowedIps.isEmpty ? '—' : s.allowedIps.join(', '),
              ),
              _InfoRow(
                'DNS (эффективный)',
                s.dns.isEmpty ? '—' : s.dns.join(', '),
              ),
              _InfoRow(
                'DNS override',
                s.forceDefaultDns
                    ? 'включён: 1.1.1.1, 1.0.0.1'
                    : 'выключен (из .conf)',
              ),
              _InfoRow('Handshake', _handshakeAge(s.lastHandshakeMs)),
              _InfoRow(
                'RX / TX',
                '${formatBytes(s.status.rx)} / ${formatBytes(s.status.tx)}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Проверка внутри туннеля',
            children: [
              Text(
                'Запросы выполняются из приложения; при поднятом туннеле '
                'они идут через него.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pingBusy ? null : _runPing,
                      icon: _pingBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed),
                      label: const Text('ping 1.1.1.1'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _httpBusy ? null : _runHttp,
                      icon: _httpBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.public),
                      label: const Text('api.ipify.org'),
                    ),
                  ),
                ],
              ),
              if (_ping != null) ...[
                const SizedBox(height: 8),
                _ResultBox(
                  ok: _ping!.ok,
                  title: _ping!.ok
                      ? 'ping OK${_ping!.rttMs != null ? ' · ${_ping!.rttMs} мс' : ''}'
                          '${_ping!.tcpFallback ? ' · TCP fallback' : ''}'
                      : 'ping не прошёл',
                  body: _ping!.error ?? _ping!.output,
                ),
              ],
              if (_http != null) ...[
                const SizedBox(height: 8),
                _ResultBox(
                  ok: _http!.ok,
                  title: _http!.ok
                      ? 'HTTP ${_http!.statusCode} · ${_http!.elapsedMs} мс'
                      : 'HTTP не прошёл',
                  body: _http!.error ??
                      '${_http!.body ?? ''}\n'
                          '${_ipComparison(s)}',
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Логи',
            children: [
              Text(
                'logs.txt: последние 500 строк Dart-лога и logcat '
                'AwgBridge/AmneziaWG (только процесс приложения).',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _exporting ? null : _exportLogs,
                icon: _exporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: const Text('Экспорт логов'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ipComparison(AwgSessionState s) {
    final before = s.ipBefore;
    if (before == null) return 'IP до подключения не сохранён';
    return 'IP до подключения: $before';
  }

  static String _handshakeAge(int? epochMs) {
    if (epochMs == null || epochMs <= 0) return 'нет';
    final diff = DateTime.now().millisecondsSinceEpoch - epochMs;
    if (diff < 0) return 'только что';
    final sec = diff ~/ 1000;
    if (sec < 60) return '$sec с назад';
    final min = sec ~/ 60;
    if (min < 60) return '$min мин назад';
    return '${min ~/ 60} ч назад';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const Divider(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.monospace = false});

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
                fontSize: monospace ? 11 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({
    required this.ok,
    required this.title,
    required this.body,
  });

  final bool ok;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (ok ? Colors.green : theme.colorScheme.error)
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (ok ? Colors.green : theme.colorScheme.error)
              .withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ok ? Icons.check_circle : Icons.error,
                  size: 16, color: ok ? Colors.green : theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              body.trim(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
