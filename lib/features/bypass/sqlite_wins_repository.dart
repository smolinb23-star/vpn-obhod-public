import 'package:sqflite/sqflite.dart';

import 'wins_repository.dart';

/// SQLite-память побед: bypass_wins(method_id, network_key, wins, last_success_ts).
class SqliteWinsRepository implements WinsRepository {
  SqliteWinsRepository._(this._db);

  static Future<SqliteWinsRepository> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE bypass_wins (
          method_id TEXT NOT NULL,
          network_key TEXT NOT NULL,
          wins INTEGER NOT NULL DEFAULT 0,
          last_success_ts INTEGER NOT NULL,
          PRIMARY KEY (method_id, network_key)
        )
      '''),
    );
    return SqliteWinsRepository._(db);
  }

  final Database _db;

  @override
  Future<int> winsFor(String methodId, String networkKey) async {
    final rows = await _db.query(
      'bypass_wins',
      columns: <String>['wins'],
      where: 'method_id = ? AND network_key = ?',
      whereArgs: <Object?>[methodId, networkKey],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return rows.first['wins'] as int? ?? 0;
  }

  @override
  Future<void> recordWin(String methodId, String networkKey) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    await _db.rawQuery('''
      INSERT INTO bypass_wins (method_id, network_key, wins, last_success_ts)
      VALUES (?, ?, 1, ?)
      ON CONFLICT(method_id, network_key)
      DO UPDATE SET wins = wins + 1, last_success_ts = excluded.last_success_ts
    ''', <Object?>[methodId, networkKey, ts]);
  }

  @override
  Future<String?> bestMethodFor(String networkKey) async {
    final rows = await _db.query(
      'bypass_wins',
      columns: <String>['method_id'],
      where: 'network_key = ?',
      whereArgs: <Object?>[networkKey],
      orderBy: 'wins DESC, last_success_ts DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['method_id'] as String;
  }

  @override
  Future<void> close() => _db.close();
}
