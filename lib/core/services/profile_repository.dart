import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Модель профиля конфигурации для хранения в SQLite (sqflite).
///
/// Каждый профиль содержит:
///  - id — уникальный идентификатор
///  - name — имя, отображаемое в UI
///  - rawConfig — исходная строка конфига (YAML / JSON / .conf / ссылка)
///  - type — тип: vless, awg, clash, xray, other
///  - priority — приоритет для авто-переключения (меньше = выше)
///  - enabled — активен ли профиль
class ProfileEntity {
  const ProfileEntity({
    required this.id,
    required this.name,
    required this.rawConfig,
    required this.type,
    required this.priority,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String rawConfig;
  final String type;
  final int priority;
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'rawConfig': rawConfig,
        'type': type,
        'priority': priority,
        'enabled': enabled ? 1 : 0,
      };

  factory ProfileEntity.fromJson(Map<String, dynamic> json) => ProfileEntity(
        id: json['id'] as String,
        name: json['name'] as String,
        rawConfig: json['rawConfig'] as String,
        type: json['type'] as String,
        priority: json['priority'] as int,
        enabled: (json['enabled'] as int?) == 1,
      );
}

/// Репозиторий профилей конфигураций в SQLite (sqflite).
///
/// Единственный источник verdad для всех импортированных конфигов.
/// Поддерживает полный CRUD: создание, чтение, обновление, удаление.
class ProfileRepository {
  ProfileRepository._();

  static final ProfileRepository _instance = ProfileRepository._();

  factory ProfileRepository() => _instance;

  static const _tableName = 'profiles';

  /// База данных (ленивая инициализация).
  static Future<_DatabaseHolder> _openDb() async {
    final databasesPath = await getDatabasesPath();
    final path = '$databasesPath/vpn_profiles.db';
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            rawConfig TEXT NOT NULL,
            type TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1
          )
        ''');
      },
    );
    return _DatabaseHolder(db);
  }

  /// Сохраняет (или обновляет) профиль.
  Future<void> saveProfile(ProfileEntity profile) async {
    final db = await _openDb();
    try {
      await db.database.insert(
        _tableName,
        profile.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } finally {
      db.database.close();
    }
  }

  /// Загружает все активные профили, отсортированные по приоритету.
  Future<List<ProfileEntity>> getAllProfiles() async {
    final db = await _openDb();
    try {
      final maps = await db.database.query(
        _tableName,
        where: 'enabled = 1',
        orderBy: 'priority ASC, name ASC',
      );
      return maps.map((m) => ProfileEntity.fromJson(m)).toList(growable: false);
    } finally {
      db.database.close();
    }
  }

  /// Загружает все профили (включая выключенные).
  Future<List<ProfileEntity>> getAllProfilesIncludingDisabled() async {
    final db = await _openDb();
    try {
      final maps = await db.database.query(
        _tableName,
        orderBy: 'priority ASC, name ASC',
      );
      return maps.map((m) => ProfileEntity.fromJson(m)).toList(growable: false);
    } finally {
      db.database.close();
    }
  }

  /// Получает профиль по ID.
  Future<ProfileEntity?> getProfile(String id) async {
    final db = await _openDb();
    try {
      final maps = await db.database.query(
        _tableName,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (maps.isEmpty) return null;
      return ProfileEntity.fromJson(maps.first);
    } finally {
      db.database.close();
    }
  }

  /// Удаляет профиль по ID.
  Future<void> deleteProfile(String id) async {
    final db = await _openDb();
    try {
      await db.database.delete(_tableName, where: 'id = ?', whereArgs: [id]);
    } finally {
      db.database.close();
    }
  }

  /// Обновляет только флаг enabled и приоритет.
  Future<void> updateProfile(String id, {bool? enabled, int? priority}) async {
    final db = await _openDb();
    try {
      final updates = <String, dynamic>{};
      if (enabled != null) updates['enabled'] = enabled ? 1 : 0;
      if (priority != null) updates['priority'] = priority;
      if (updates.isNotEmpty) {
        await db.database.update(_tableName, updates,
            where: 'id = ?', whereArgs: [id]);
      }
    } finally {
      db.database.close();
    }
  }

  /// Удаляет все профили.
  Future<void> clearAll() async {
    final db = await _openDb();
    try {
      await db.database.delete(_tableName);
    } finally {
      db.database.close();
    }
  }
}

/// Вспомогательный холдер для базы данных (закрытие в finally).
class _DatabaseHolder {
  final Database database;
  _DatabaseHolder(this.database);
}

/// Провайдер ProfileRepository.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
});
