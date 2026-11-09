import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/widgets/root_screen.dart';
import 'features/bypass/bypass_providers.dart';
import 'features/bypass/sqlite_wins_repository.dart';
import 'features/bypass/wins_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // sqflite_common_ffi для поддержки десктопов; на мобильных sqflite сам подхватит.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // SQLite-память побед; при недоступности плагина — безопасный fallback.
  WinsRepository wins;
  try {
    wins = await SqliteWinsRepository.openDefault();
  } on Object catch (e) {
    // ignore: avoid_print
    print('SQLite wins недоступен, in-memory fallback: $e');
    wins = InMemoryWinsRepository();
  }

  runApp(
    ProviderScope(
      overrides: <Override>[winsRepositoryProvider.overrideWithValue(wins)],
      child: const VpnApp(),
    ),
  );
}

class VpnApp extends StatelessWidget {
  const VpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPN Obhod',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}
