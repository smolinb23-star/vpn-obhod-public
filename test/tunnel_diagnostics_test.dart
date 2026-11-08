import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_service/features/vpn/services/tunnel_diagnostics.dart';

void main() {
  group('TunnelDiagnostics.parsePingRttMs', () {
    test('Linux/Android среднее', () {
      const out = '3 packets transmitted, 3 received, 0% packet loss, time 2003ms\n'
          'rtt min/avg/max/mdev = 8.123/8.456/9.789/0.5 ms';
      expect(TunnelDiagnostics.parsePingRttMs(out), 8);
    });

    test('Windows Average', () {
      const out = 'Ping statistics for 1.1.1.1:\n'
          '    Packets: Sent = 4, Received = 4, Lost = 0 (0% loss),\n'
          'Approximate round trip times in milli-seconds:\n'
          '    Minimum = 8ms, Maximum = 10ms, Average = 9ms';
      expect(TunnelDiagnostics.parsePingRttMs(out), 9);
    });

    test('time= строка', () {
      const out = '64 bytes from 1.1.1.1: icmp_seq=1 ttl=56 time=12.3 ms';
      expect(TunnelDiagnostics.parsePingRttMs(out), 12);
    });

    test('нет данных — null', () {
      expect(TunnelDiagnostics.parsePingRttMs('no ping'), isNull);
    });
  });
}
