import 'dart:convert';

/// Тип профиля для Mihomo.
enum ProfileType { vless, awg, clash, xray, other }

/// Разобранный VPN-профиль для работы с Mihomo.
class VpnConfig {
  const VpnConfig({
    required this.remark,
    required this.profileType,
    required this.rawConfig,
    required this.type,
    this.xrayJson = '',
    this.stream = '',
    this.security = '',
    this.host = '',
  });

  final String remark;
  final ProfileType profileType;
  final String rawConfig;      // Исходная строка (YAML / JSON / .conf / ссылка)
  final String type;           // Строковое представление типа (awg, clash, xray, vless, other)
  final String xrayJson;       // Для обратной совместимости
  final String stream;
  final String security;
  final String host;

  /// Тип как строка для сохранения в ProfileRepository.
  String get typeString => type;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remark': remark,
        'profileType': profileType.name,
        'rawConfig': rawConfig,
        'type': type,
        'xrayJson': xrayJson,
        'stream': stream,
        'security': security,
        'host': host,
      };

  factory VpnConfig.fromJson(Map<String, dynamic> json) => VpnConfig(
        remark: json['remark'] as String? ?? 'profile',
        profileType: ProfileType.values.firstWhere(
          (p) => p.name == json['profileType'],
          orElse: () => ProfileType.other,
        ),
        rawConfig: json['rawConfig'] as String? ?? '',
        type: json['type'] as String? ?? 'other',
        xrayJson: json['xrayJson'] as String? ?? '',
        stream: json['stream'] as String? ?? '',
        security: json['security'] as String? ?? '',
        host: json['host'] as String? ?? '',
      );

  String toJsonString() => jsonEncode(toJson());

  /// Протокол vless.
  bool get isVless => profileType == ProfileType.vless || type == 'vless';

  /// AmneziaWG / WireGuard.
  bool get isAwg => profileType == ProfileType.awg || type == 'awg';

  /// Clash / Mihomo YAML.
  bool get isClash => profileType == ProfileType.clash || type == 'clash';

  /// Xray JSON.
  bool get isXray => profileType == ProfileType.xray || type == 'xray';

  /// Каскадный конфиг (не используется в Mihomo, оставлено для совместимости).
  bool get isCascade => false;

  /// CDN-фронт (не используется в Mihomo, оставлено для совместимости).
  bool get isCdnFronted => false;

  /// CIDR-список.
  bool get isCidrList => false;

  /// gRPC транспорт.
  bool get isGrpc => stream == 'grpc';
}
