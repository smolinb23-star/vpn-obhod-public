import 'dart:async';

/// Итог разведки метода (probe).
class ProbeResult {
  const ProbeResult({
    required this.success,
    this.latencyMs,
    this.realIpChanged,
    this.error,
  });

  const ProbeResult.failed([this.error = 'probe failed'])
      : success = false,
        latencyMs = null,
        realIpChanged = null;

  final bool success;
  final int? latencyMs;

  /// null — проверить нельзя (сервис недоступен), true — IP изменился.
  final bool? realIpChanged;
  final String? error;
}

/// Мгновенное здоровье активного метода из healthStream.
class MethodHealth {
  const MethodHealth({
    required this.alive,
    this.rttMs = 0,
    this.lossRatio = 0,
    this.handshakeErrors = 0,
  });

  final bool alive;
  final int rttMs;
  final double lossRatio;
  final int handshakeErrors;
}

/// Жизненный статус метода для UI.
enum MethodStatus { unknown, available, active, degraded, unavailable }

/// Единый интерфейс способа обхода белого списка.
///
/// Реализации: мок (демо без VPS) и боевые провайдеры поверх VpnService.
/// Замена мока на боевой метод — одна точка: `BypassMethodFactory`.
abstract class BypassMethod {
  /// Устойчивый идентификатор (ключ в SQLite-памяти побед).
  String get id;

  /// Человекочитаемое имя для UI.
  String get name;

  /// Приоритет: меньшее значение = выше приоритет (VLESS Reality = 0).
  int get priority => 100;

  /// true — метод симулирован (демо-режим без реального сервера).
  bool get mock;

  /// Можно ли вообще пробовать метод на этом устройстве/сети.
  Future<bool> isAvailable();

  /// Разведка без удержания соединения. Вызывающий обязан применить таймаут.
  Future<ProbeResult> probe();

  Future<void> connect();

  Future<void> disconnect();

  /// Поток здоровья активного соединения (эмитится только после connect).
  Stream<MethodHealth> get healthStream;
}

/// Проверка реального трафика после connect: публичный IP должен измениться.
abstract class TrafficVerifier {
  /// true — IP изменился; false — трафик не идёт; null — проверить нельзя.
  Future<bool?> verifyTraffic();
}

class AlwaysPassVerifier implements TrafficVerifier {
  const AlwaysPassVerifier();
  @override
  Future<bool?> verifyTraffic() async => true;
}
