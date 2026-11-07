import 'dart:convert';

/// Тип источника, из которого импортирован профиль.
enum ConfigKind { shareLink, xrayJson, subscription, unknown }

/// Протокол профиля — используется движком обхода для ранжирования методов.
enum ProfileProtocol {
  vless,
  vmess,
  trojan,
  shadowsocks,
  hysteria2,
  wireguard,
  socks,
  other,
}

/// Разобранный VPN-профиль с готовой Xray-конфигурацией.
class VpnConfig {
  const VpnConfig({
    required this.remark,
    required this.protocol,
    required this.xrayJson,
    this.stream = '',
    this.security = '',
    this.host = '',
    this.cdnFronted = false,
  });

  factory VpnConfig.fromJson(Map<String, dynamic> json) => VpnConfig(
        remark: json['remark'] as String? ?? 'profile',
        protocol: ProfileProtocol.values.firstWhere(
          (p) => p.name == json['protocol'],
          orElse: () => ProfileProtocol.other,
        ),
        xrayJson: json['xrayJson'] as String? ?? '',
        stream: json['stream'] as String? ?? '',
        security: json['security'] as String? ?? '',
        host: json['host'] as String? ?? '',
        cdnFronted: json['cdnFronted'] as bool? ?? false,
      );

  final String remark;
  final ProfileProtocol protocol;

  /// JSON-строка конфигурации Xray для запуска туннеля.
  final String xrayJson;

  /// Транспорт (tcp/xhttp/ws/grpc/...).
  final String stream;

  /// Безопасность (reality/tls/none).
  final String security;

  /// SNI / Host, к которому маскируется трафик.
  final String host;

  /// Идёт ли трафик через CDN-фронт (белый домен).
  final bool cdnFronted;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remark': remark,
        'protocol': protocol.name,
        'xrayJson': xrayJson,
        'stream': stream,
        'security': security,
        'host': host,
        'cdnFronted': cdnFronted,
      };

  String toJsonString() => jsonEncode(toJson());

  Map<String, dynamic> get xrayMap =>
      jsonDecode(xrayJson) as Map<String, dynamic>;
}
