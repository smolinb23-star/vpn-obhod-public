/// Память побед: какой метод лучше всего работает в конкретной сети.
///
/// network_key = SSID Wi-Fi или operator|mccmnc сотового оператора.
abstract class WinsRepository {
  Future<int> winsFor(String methodId, String networkKey);

  Future<void> recordWin(String methodId, String networkKey);

  /// Метод с наибольшим числом побед для сети (null — истории нет).
  Future<String?> bestMethodFor(String networkKey);

  Future<void> close();
}

/// Тестовая/демо реализация в памяти (sqflite недоступен в чистых Dart-тестах).
class InMemoryWinsRepository implements WinsRepository {
  final Map<String, int> _wins = <String, int>{};

  String _key(String methodId, String networkKey) => '$methodId|$networkKey';

  @override
  Future<int> winsFor(String methodId, String networkKey) async =>
      _wins[_key(methodId, networkKey)] ?? 0;

  @override
  Future<void> recordWin(String methodId, String networkKey) async {
    final k = _key(methodId, networkKey);
    _wins[k] = (_wins[k] ?? 0) + 1;
  }

  @override
  Future<String?> bestMethodFor(String networkKey) async {
    String? best;
    var bestWins = 0;
    for (final entry in _wins.entries) {
      final parts = entry.key.split('|');
      if (parts.last != networkKey) continue;
      if (entry.value > bestWins) {
        bestWins = entry.value;
        best = parts.first;
      }
    }
    return best;
  }

  @override
  Future<void> close() async {}
}
