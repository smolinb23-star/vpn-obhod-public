import 'dart:convert';

/// Безопасная валидация Xray-конфигурации перед запуском.
///
/// Требования безопасности Этапа 1:
/// - локальные inbound-порты привязаны строго к 127.0.0.1 (не 0.0.0.0);
/// - SOCKS-инбаунды не используют auth=noauth/anonymous.
class ConfigValidator {
  const ConfigValidator();

  /// Возвращает список нарушений. Пустой список — конфиг безопасен.
  List<String> validate(String xrayJson) {
    final errors = <String>[];
    Object? decoded;
    try {
      decoded = jsonDecode(xrayJson);
    } on FormatException catch (e) {
      return <String>['Невалидный JSON: ${e.message}'];
    }
    if (decoded is! Map<String, dynamic>) {
      return const <String>['Конфиг должен быть JSON-объектом'];
    }

    // В VPN-режиме flutter_vless поднимает собственный приватный
    // loopback-SOCKS, поэтому секция inbounds может отсутствовать.
    final inbounds = decoded['inbounds'];
    if (inbounds != null && inbounds is! List) {
      return const <String>['Секция inbounds должна быть списком'];
    }

    for (final raw in (inbounds as List? ?? const <dynamic>[])) {
      if (raw is! Map<String, dynamic>) {
        errors.add('inbound должен быть объектом');
        continue;
      }
      final listen = (raw['listen'] as String?)?.toLowerCase() ?? '';
      if (listen.isEmpty || listen == '0.0.0.0' || listen == '::') {
        errors.add(
          'inbound "${raw['tag'] ?? '?'}": listen="$listen" запрещён — '
          'только 127.0.0.1',
        );
      }
      if (raw['protocol'] == 'socks') {
        final settings = raw['settings'];
        final auth = settings is Map<String, dynamic>
            ? (settings['auth'] as String?)?.toLowerCase()
            : null;
        if (auth == null || auth == 'noauth' || auth == 'anonymous') {
          errors.add(
            'SOCKS inbound "${raw['tag'] ?? '?'}": auth=$auth запрещён — '
            'обязателен password',
          );
        }
      }
    }

    final outbounds = decoded['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      errors.add('Отсутствует хотя бы один outbound');
    }

    return errors;
  }

  void validateOrThrow(String xrayJson) {
    final errors = validate(xrayJson);
    if (errors.isNotEmpty) {
      throw ConfigValidationException(errors);
    }
  }
}

class ConfigValidationException implements Exception {
  const ConfigValidationException(this.errors);
  final List<String> errors;

  @override
  String toString() => 'Небезопасный конфиг:\n- ${errors.join('\n- ')}';
}
