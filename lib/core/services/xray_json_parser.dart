import 'dart:convert';

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/app_log.dart';

/// Ошибки разбора Xray JSON.
class XrayJsonParseException implements Exception {
  const XrayJsonParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Парсер Xray JSON конфигураций.
///
/// Поддерживает:
///  1. WireGuard outbound (protocol: "wireguard") — извлекает secretKey,
///     publicKey, endpoint, address и конвертирует в WireGuardConfig.
///  2. Noise-параметры (deXrayWARP стиль) — передаются как-is в xrayJson,
///     так как Xray-ядро умеет генерировать шум для обхода DPI.
class XrayJsonParser {
  const XrayJsonParser();

  /// Быстрая проверка, что текст похож на Xray JSON с wireguard outbound.
  static bool looksLikeWireGuardXrayJson(String content) {
    try {
      final trimmed = content.trim();
      if (!trimmed.startsWith('{')) return false;
      final map = jsonDecode(trimmed) as Map<String, dynamic>;
      final outbounds = map['outbounds'];
      if (outbounds is! List || outbounds.isEmpty) return false;
      final first = outbounds.first as Map<String, dynamic>?;
      return first?['protocol'] == 'wireguard';
    } on Object {
      return false;
    }
  }

  /// Разбирает Xray JSON с WireGuard outbound и возвращает VpnConfig.
  ///
  /// Извлекает:
  ///   - settings.secretKey → приватный ключ
  ///   - settings.peers[].publicKey → публичный ключ пира
  ///   - settings.peers[].endpoint → хост:порт
  ///   - settings.address → адреса интерфейса
  ///   - shapings/noise → передаются в xrayJson как-is
  VpnConfig parse(String content, {String fallbackName = 'WireGuard'}) {
    final log = <String>[];

    void emit(String message) {
      log.add(message);
      appLog.info('XrayJsonParser', message);
    }

    final map = jsonDecode(content) as Map<String, dynamic>;

    final outbounds = map['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      throw const XrayJsonParseException('Xray JSON без outbounds');
    }

    final firstOutbound = outbounds.first as Map<String, dynamic>;
    final protocol = firstOutbound['protocol'] as String?;
    if (protocol != 'wireguard') {
      throw XrayJsonParseException(
        'Xray JSON протокол "$protocol" не поддерживается этим парсером',
      );
    }

    final settings = firstOutbound['settings'] as Map<String, dynamic>? ?? const {};

    final secretKey = settings['secretKey'] as String?;
    if (secretKey == null || secretKey.isEmpty) {
      throw const XrayJsonParseException('WireGuard: нет secretKey');
    }

    final peers = settings['peers'] as List<dynamic>?;
    if (peers == null || peers.isEmpty) {
      throw const XrayJsonParseException('WireGuard: нет peers');
    }

    final firstPeer = peers.first as Map<String, dynamic>?;
    final peerPublicKey = firstPeer?['publicKey'] as String?;
    if (peerPublicKey == null || peerPublicKey.isEmpty) {
      throw const XrayJsonParseException('WireGuard: нет publicKey в peers');
    }

    final endpoint = firstPeer?['endpoint'] as String?;
    final endpointParts = _splitEndpoint(endpoint);
    final endpointHost = endpointParts.$1;
    final endpointPort = endpointParts.$2;

    if (endpointHost == null || endpointHost.isEmpty) {
      throw const XrayJsonParseException(
        'WireGuard: нет endpoint в peers',
      );
    }
    if (endpointPort == null || endpointPort <= 0 || endpointPort > 65535) {
      throw const XrayJsonParseException('WireGuard: некорректный порт endpoint');
    }

    final addresses = (settings['address'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList(growable: false) ??
        <String>[];

    if (addresses.isEmpty) {
      throw const XrayJsonParseException(
        'WireGuard: нет address в settings',
      );
    }

    emit('Разбор WireGuard JSON: secretKey=$secretKey, peerPublicKey=$peerPublicKey, '
        'endpoint=$endpointHost:$endpointPort, addresses=$addresses');

    // Noise-параметры для обхода DPI (deXrayWARP стиль) — оставляем в xrayJson как-is.
    // Xray-ядро через flutter_vless их обработает.
    final xrayJson = jsonEncode(map);

    return VpnConfig(
      remark: fallbackName,
      protocol: ProfileProtocol.wireguard,
      xrayJson: xrayJson,
      stream: 'wireguard',
      security: 'none',
      host: endpointHost,
    );
  }

  (String?, int?) _splitEndpoint(String? value) {
    if (value == null || value.isEmpty) return (null as String?, null as int?);
    final v = value.trim();
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close > 0) {
        final host = v.substring(1, close);
        final rest = v.substring(close + 1);
        final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
        return (host, port);
      }
      return (v, null);
    }
    final last = v.lastIndexOf(':');
    if (last <= 0) return (v, null);
    return (v.substring(0, last), int.tryParse(v.substring(last + 1)));
  }
}
