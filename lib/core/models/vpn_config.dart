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

/// Тип каскадного маршрутизации.
enum CascadeType { none, russiaForeign }

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
    this.streamPath = '/',
    this.streamHost = '',
    this.cascadeType = CascadeType.none,
    this.cascadeOutbound1,
    this.cascadeOutbound2,
    this.cidrList = const [],
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
        streamPath: json['streamPath'] as String? ?? '/',
        streamHost: json['streamHost'] as String? ?? '',
        cascadeType: CascadeType.values.firstWhere(
          (p) => p.name == json['cascadeType'],
          orElse: () => CascadeType.none,
        ),
        cascadeOutbound1: json['cascadeOutbound1'] != null
            ? VpnConfig.fromJson(json['cascadeOutbound1'] as Map<String, dynamic>)
            : null,
        cascadeOutbound2: json['cascadeOutbound2'] != null
            ? VpnConfig.fromJson(json['cascadeOutbound2'] as Map<String, dynamic>)
            : null,
        cidrList: (json['cidrList'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(growable: false) ?? const [],
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

  /// Путь для WebSocket/XHTTP транспорта.
  final String streamPath;

  /// Host заголовок для WebSocket/XHTTP транспорта.
  final String streamHost;

  /// Тип каскадной маршрутизации.
  final CascadeType cascadeType;

  /// Промежуточный сервер с российским IP (для каскада).
  final VpnConfig? cascadeOutbound1;

  /// Зарубежный сервер (для каскада).
  final VpnConfig? cascadeOutbound2;

  /// Список CIDR диапазонов для маршрутизации через VPN.
  final List<String> cidrList;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remark': remark,
        'protocol': protocol.name,
        'xrayJson': xrayJson,
        'stream': stream,
        'security': security,
        'host': host,
        'cdnFronted': cdnFronted,
        'streamPath': streamPath,
        'streamHost': streamHost,
        'cascadeType': cascadeType.name,
        'cascadeOutbound1': cascadeOutbound1?.toJson(),
        'cascadeOutbound2': cascadeOutbound2?.toJson(),
        'cidrList': cidrList,
      };

  String toJsonString() => jsonEncode(toJson());

  Map<String, dynamic> get xrayMap =>
      jsonDecode(xrayJson) as Map<String, dynamic>;

  /// Возвращает true если это каскадный конфиг.
  bool get isCascade => cascadeType != CascadeType.none;

  /// Возвращает true если это CDN-фронт конфиг.
  bool get isCdnFronted => cdnFronted;

  /// Возвращает true если это CIDR-маршрутизация (только список IP, нет реального сервера).
  bool get isCidrList => cidrList.isNotEmpty && host.isEmpty;
}
