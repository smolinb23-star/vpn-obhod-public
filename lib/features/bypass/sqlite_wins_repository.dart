import 'package:shared_preferences/shared_preferences.dart';

import 'wins_repository.dart';

/// Память побед в shared_preferences: bypass_wins(method_id, network_key, wins, last_success_ts).
class SqliteWinsRepository implements WinsRepository {
  SqliteWinsRepository._();

  static Future<SqliteWinsRepository> openDefault() async {
    return SqliteWinsRepository._();
  }

  static Future<SqliteWinsRepository> open(String path) async {
    return SqliteWinsRepository._();
  }

  String _key(String methodId, String networkKey) =>
      'win_$methodId_$networkKey';

  @override
  Future<int> winsFor(String methodId, String networkKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(methodId, networkKey)) ?? 0;
  }

  @override
  Future<void> recordWin(String methodId, String networkKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(methodId, networkKey);
    final current = prefs.getInt(key) ?? 0;
    final ts = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(key, current + 1);
    await prefs.setInt('${key}_ts', ts);
  }

  @override
  Future<String?> bestMethodFor(String networkKey) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('win_'));
    String? bestMethod;
    int bestWins = 0;
    int bestTs = 0;
    for (final key in keys) {
      final parts = key.split('_');
      if (parts.length < 3) continue;
      final methodId = parts[1];
      final networkKeyPart = parts.sublist(2).join('_');
      if (networkKeyPart != networkKey) continue;
      final wins = prefs.getInt(key) ?? 0;
      final ts = prefs.getInt('${key}_ts') ?? 0;
      if (wins > bestWins || (wins == bestWins && ts > bestTs)) {
        bestWins = wins;
        bestTs = ts;
        bestMethod = methodId;
      }
    }
    return bestMethod;
  }

  @override
  Future<void> close() async {}
}
