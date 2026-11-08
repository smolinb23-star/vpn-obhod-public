import 'package:flutter/material.dart';

import '../../features/bypass/widgets/bypass_screen.dart';
import '../../features/vpn/widgets/diagnostics_screen.dart';
import '../../features/vpn/widgets/home_screen.dart';
import '../../features/vpn/widgets/split_tunneling_screen.dart';

/// Корневой экран с нижней навигацией.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomeScreen(), BypassScreen(), DiagnosticsScreen(), SplitTunnelingScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'VPN',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route_outlined),
            selectedIcon: Icon(Icons.alt_route),
            label: 'Обход',
          ),
          NavigationDestination(
            icon: Icon(Icons.troubleshoot_outlined),
            selectedIcon: Icon(Icons.troubleshoot),
            label: 'Диагностика',
          ),
          NavigationDestination(
            icon: Icon(Icons.mobile_friendly),
            selectedIcon: Icon(Icons.mobile_friendly),
            label: 'Исключённые приложения',
          ),
        ],
      ),
    );
  }
}
