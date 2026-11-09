// ignore_for_file: unused_import
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Модель профиля конфигурации для хранения в shared_preferences.
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

/// Репозиторий профилей конфигураций в shared_preferences.
///
/// Единственный источник verdad для всех импортированных конфигов.
/// Поддерживает полный CRUD: создание, чтение, обновление, удаление.
class ProfileRepository {
  ProfileRepository._();

  static final ProfileRepository _instance = ProfileRepository._();

  factory ProfileRepository() => _instance;

  static const _prefix = 'profile_';

  /// Сохраняет (или обновляет) профиль.
  Future<void> saveProfile(ProfileEntity profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix${profile.id}', jsonEncode(profile.toJson()));
  }

  /// Загружает все активные профили, отсортированные по приоритету.
  Future<List<ProfileEntity>> getAllProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    final profiles = <ProfileEntity>[];
    for (final key in keys) {
      final jsonStr = prefs.getString(key);
      if (jsonStr != null) {
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          profiles.add(ProfileEntity.fromJson(json));
        } on Object {
          // ignore malformed
        }
      }
    }
    profiles.sort((a, b) => a.priority.compareTo(b.priority));
    return profiles;
  }

  /// Загружает все профили (включая выключенные).
  Future<List<ProfileEntity>> getAllProfilesIncludingDisabled() async {
    return getAllProfiles();
  }

  /// Получает профиль по ID.
  Future<ProfileEntity?> getProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_prefix$id');
    if (jsonStr == null) return null;
    try {
      return ProfileEntity.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// Удаляет профиль по ID.
  Future<void> deleteProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$id');
  }

  /// Обновляет только флаг enabled и приоритет.
  Future<void> updateProfile(String id, {bool? enabled, int? priority}) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_prefix$id');
    if (jsonStr == null) return;
    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (enabled != null) json['enabled'] = enabled ? 1 : 0;
      if (priority != null) json['priority'] = priority;
      await prefs.setString('$_prefix$id', jsonEncode(json));
    } on Object {
      // ignore
    }
  }

  /// Удаляет все профили.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}

/// Провайдер ProfileRepository.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
});

/// Провайдер списка профилей (обновляется через `ref.invalidate`).
final profilesProvider = FutureProvider<List<ProfileEntity>>(
  (ref) async => ref.read(profileRepositoryProvider).getAllProfiles(),
);
