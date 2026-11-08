import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vpn_service/features/vpn/services/awg_session_controller.dart';
import 'package:vpn_service/features/vpn/services/health_monitor.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Панель нативного AmneziaWG: статус, rx/tx (1 с), проверка IP, MTU, DNS.
///
/// Встраивается на экран VPN и на экран импорта .conf — счётчики видны
/// сразу после подключения, без пересборки APK.
class AwgStatusPanel extends ConsumerWidget {
  const AwgStatusPanel({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(awgSessionProvider);
    final theme = Theme.of(context);
    final (label, color) = switch (s.phase) {
      AwgPhase.up => ('AmneziaWG подключён', Colors.green),
      AwgPhase.connecting => ('Подключение…', Colors.orange),
      AwgPhase.error => ('Ошибка туннеля', Colors.red),
      AwgPhase.idle => ('AmneziaWG отключён', Colors.grey),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.shield, color: color, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: theme.textTheme.titleMedium),
                      if (s.configName != null)
                        Text(s.configName!,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                _HealthChip(health: s.health),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Counter(
                    icon: Icons.download,
                    title: 'RX',
                    bytes: s.status.rx,
                    packets: s.status.rxPackets,
                    speed: s.rxSpeed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Counter(
                    icon: Icons.upload,
                    title: 'TX',
                    bytes: s.status.tx,
                    packets: s.status.txPackets,
                    speed: s.txSpeed,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text('RTT: ${s.rttMs == null ? '—' : '${s.rttMs} мс'}',
                    style: theme.textTheme.bodySmall),
                Text(
                    'Потери: ${s.lossRatio == null ? '—' : '${(s.lossRatio! * 100).toStringAsFixed(0)}%'}',
                    style: theme.textTheme.bodySmall),
                Text(
                    'Handshake: ${_handshakeAge(s.lastHandshakeMs)}',
                    style: theme.textTheme.bodySmall),
                if (s.reconnectAttempts > 0)
                  Text('Реконнект: ${s.reconnectAttempts}/3',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.orange)),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.publicIp == null
                        ? 'Публичный IP: не проверен'
                        : 'Публичный IP: ${s.publicIp}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ip = await ref
                        .read(awgSessionProvider.notifier)
                        .checkIp();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ip == null
                          ? 'Не удалось получить IP (нет сети?)'
                          : 'Публичный IP: $ip'),
                    ));
                  },
                  icon: const Icon(Icons.public, size: 18),
                  label: const Text('Проверить IP'),
                ),
              ],
            ),
            if (s.ipBefore != null)
              Text('IP до подключения: ${s.ipBefore}',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('MTU:', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: s.mtu,
                  items: const [
                    DropdownMenuItem(value: 1180, child: Text('1180')),
                    DropdownMenuItem(value: 1200, child: Text('1200')),
                    DropdownMenuItem(value: 1240, child: Text('1240')),
                    DropdownMenuItem(value: 1280, child: Text('1280')),
                    DropdownMenuItem(value: 1320, child: Text('1320')),
                    DropdownMenuItem(value: 1360, child: Text('1360')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(awgSessionProvider.notifier).setMtu(v);
                    }
                  },
                ),
                const Spacer(),
                Text('смена MTU перезапускает туннель',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('DNS-override 1.1.1.1 / 1.0.0.1'),
              subtitle: const Text('Принудительно, даже если DNS есть в .conf'),
              value: s.forceDefaultDns,
              onChanged: (v) => ref
                  .read(awgSessionProvider.notifier)
                  .setForceDefaultDns(v),
            ),
            if (!compact && s.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                s.notes.take(4).join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (s.error != null) ...[
              const SizedBox(height: 8),
              Text(s.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
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

class _Counter extends StatelessWidget {
  const _Counter({
    required this.icon,
    required this.title,
    required this.bytes,
    required this.packets,
    required this.speed,
  });

  final IconData icon;
  final String title;
  final int bytes;
  final int? packets;
  final int speed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 4),
              Text(title, style: theme.textTheme.labelMedium),
              const Spacer(),
              Text(formatSpeed(speed), style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(formatBytes(bytes),
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text(packets == null ? 'пакеты: н/д' : 'пакетов: $packets',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _HealthChip extends StatelessWidget {
  const _HealthChip({required this.health});

  final TunnelHealth health;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (health) {
      TunnelHealth.healthy => ('OK', Colors.green),
      TunnelHealth.degraded => ('Degraded', Colors.orange),
      TunnelHealth.dead => ('Dead', Colors.red),
      TunnelHealth.unknown => ('—', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}
