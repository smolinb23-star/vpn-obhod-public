import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'package:vpn_service/core/models/vpn_config.dart';

/// Профиль конфигурации для хранения в SQLite.
class ProfileEntity {
  const ProfileEntity({
    required this.id,
    required this.name,
    required this.configString,
    required this.type,
    required this.priority,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String configString;
  final String type;
  final int priority;
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'configString': configString,
        'type': type,
        'priority': priority,
        'enabled': enabled ? 1 : 0,
      };

  factory ProfileEntity.fromJson(Map<String, dynamic> json) => ProfileEntity(
        id: json['id'] as String,
        name: json['name'] as String,
        configString: json['configString'] as String,
        type: json['type'] as String,
        priority: json['priority'] as int,
        enabled: (json['enabled'] as int?) == 1,
      );
}

/// Репозиторий профилей конфигураций в SQLite.
///
/// Хранит все конфиги (VLESS, AmneziaWG, Hysteria2, CDN, каскад, CIDR)
/// с приоритетом для авто-переключения.
class ProfileRepository {
  ProfileRepository._();

  static final ProfileRepository _instance = ProfileRepository._();

  factory ProfileRepository() => _instance;

  static Database? _db;

  static Future<Database> _getDatabase() async {
    if (_db != null) return _db!;
    final databasesPath = await getDatabasesPath();
    final path = '${databasesPath}${_pathSeparator}vpn_profiles.db';
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            configString TEXT NOT NULL,
            type TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1
          )
        ''');
      },
    );
    return _db!;
  }

  static String get _pathSeparator {
    if (Platform.isWindows) return '\\';
    return '/';
  }

  /// Сохраняет профиль в БД.
  Future<void> saveProfile(ProfileEntity profile) async {
    final db = await _getDatabase();
    await db.insert(
      'profiles',
      profile.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Загружает все профили, отсортированные по приоритету.
  Future<List<ProfileEntity>> getAllProfiles() async {
    final db = await _getDatabase();
    final maps = await db.query(
      'profiles',
      where: 'enabled = 1',
      orderBy: 'priority ASC',
    );
    return maps.map((m) => ProfileEntity.fromJson(m)).toList();
  }

  /// Удаляет профиль по ID.
  Future<void> deleteProfile(String id) async {
    final db = await _getDatabase();
    await db.delete('profiles', where: 'id = ?', whereArgs: [id]);
  }

  /// Удаляет все профили.
  Future<void> clearAll() async {
    final db = await _getDatabase();
    await db.delete('profiles');
  }

  /// Закрывает БД.
  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
      _db = null;
    }
  }
}

/// Провайдер ProfileRepository.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
});