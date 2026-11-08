import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/vpn/services/awg_i1_presets.dart';
import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';

/// Панель подбора I1 — специального пакета-сигнатуры AmneziaWG.
///
/// Смена I1 на подключённом туннеле сразу перезапускает его: можно перебирать
/// пресеты без пересборки APK. Если handshake прошёл, а RX почти нулевой —
/// это типичный признак DPI-блокировки после рукопожатия.
class AwgDpiPanel extends ConsumerStatefulWidget {
  const AwgDpiPanel({super.key});

  @override
  ConsumerState<AwgDpiPanel> createState() => _AwgDpiPanelState();
}

class _AwgDpiPanelState extends ConsumerState<AwgDpiPanel> {
  late final TextEditingController _i1Ctrl;
  String _presetId = 'default';
  String? _validationError;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(awgSessionProvider);
    _i1Ctrl = TextEditingController(text: s.i1);
    _presetId = AwgI1Preset.match(s.i1)?.id ?? 'custom';
  }

  @override
  void dispose() {
    _i1Ctrl.dispose();
    super.dispose();
  }

  void _onPresetChanged(String? id) {
    if (id == null) return;
    final preset = AwgI1Preset.byId(id);
    setState(() {
      _presetId = id;
      _validationError = null;
      if (preset != null) _i1Ctrl.text = preset.value;
    });
  }

  void _onTextChanged(String value) {
    final match = AwgI1Preset.match(value);
    setState(() {
      _presetId = match?.id ?? 'custom';
      _validationError = null;
    });
  }

  Future<void> _apply() async {
    final error = AwgI1Preset.validate(_i1Ctrl.text);
    if (error != null) {
      setState(() => _validationError = error);
      return;
    }
    setState(() => _applying = true);
    try {
      final ok =
          await ref.read(awgSessionProvider.notifier).applyI1(_i1Ctrl.text);
      if (!mounted) return;
      if (!ok) {
        setState(() => _validationError = 'Некорректное значение I1');
        return;
      }
      final up = ref.read(awgSessionProvider).up;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(up
              ? 'I1 применён — туннель перезапущен'
              : 'I1 сохранён — применится при подключении'),
        ),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Синхронизация с I1, загруженным из .conf / сохранённым ранее.
    ref.listen<String>(awgSessionProvider.select((s) => s.i1), (prev, next) {
      if (next == _i1Ctrl.text) return;
      _i1Ctrl.text = next;
      if (mounted) {
        setState(() => _presetId = AwgI1Preset.match(next)?.id ?? 'custom');
      }
    });

    final s = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);
    final preset = AwgI1Preset.byId(_presetId);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.security, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('DPI-обход: I1 (сигнатура пакета)',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'I1 отправляется перед handshake и не несёт данных — серверу '
              'его значение знать не нужно. Если handshake прошёл, а RX почти '
              'не растёт, переберите I1 и MTU.',
              style: theme.textTheme.bodySmall,
            ),
            if (s.dpiSuspected) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Похоже на DPI-блокировку: handshake есть, RX '
                  '${s.status.rx} Б, TX ${s.status.tx} Б, потери '
                  '${((s.lossRatio ?? 0) * 100).toStringAsFixed(0)}%. '
                  'Смените I1 и/или MTU.',
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    value: _presetId,
                    isExpanded: true,
                    items: <DropdownMenuItem<String>>[
                      for (final p in AwgI1Preset.all)
                        DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(p.label),
                        ),
                      const DropdownMenuItem<String>(
                        value: 'custom',
                        child: Text('Свой вариант'),
                      ),
                    ],
                    onChanged: _applying ? null : _onPresetChanged,
                  ),
                ),
              ],
            ),
            if (preset != null)
              Text(preset.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _i1Ctrl,
              enabled: !_applying,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: _onTextChanged,
              decoration: InputDecoration(
                labelText: 'I1 (теги)',
                hintText: '<b 0x...><r 32>',
                border: const OutlineInputBorder(),
                errorText: _validationError,
                helperText: 'Пусто — не отправлять. Пример: <r 64>',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _applying ? null : _apply,
              icon: _applying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(s.up
                  ? 'Применить и переподключить'
                  : 'Сохранить I1'),
            ),
            const SizedBox(height: 8),
            Text(
              'Активно: ${s.i1.isEmpty ? 'I1 не задан' : s.i1}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
