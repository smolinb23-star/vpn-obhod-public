import 'dart:convert';

/// Разобранный WireGuard/AmneziaWG-конфиг из .conf-файла.
///
/// Стандартные поля WireGuard ([Interface]/[Peer]) плюс Amnezia-расширения
/// (Jc, Jmin, Jmax, H1..H4, S1, S2). Через Xray wireguard-outbound они не
/// применяются, но сохраняются: при появлении AmneziaWG-движка достаточно
/// передать [amnezia] в нативный слой, не меняя парсер.
class WireGuardConfig {
  const WireGuardConfig({
    required this.name,
    required this.privateKey,
    required this.addresses,
    required this.peerPublicKey,
    required this.endpointHost,
    required this.endpointPort,
    this.peerPresharedKey,
    this.allowedIps = const ['0.0.0.0/0', '::/0'],
    this.persistentKeepalive = 25,
    this.dns = const [],
    this.mtu,
    this.amnezia = const {},
    this.warnings = const [],
  });

  final String name;

  /// Приватный ключ интерфейса (base64, 44 символа).
  final String privateKey;

  /// Адреса из `Address =` (CIDR). Xray wireguard-outbound требует их явно.
  final List<String> addresses;

  final String peerPublicKey;
  final String? peerPresharedKey;
  final String endpointHost;
  final int endpointPort;
  final List<String> allowedIps;
  final int persistentKeepalive;
  final List<String> dns;
  final int? mtu;

  /// Amnezia-расширения как есть (Jc=..., Jmin=..., H1=..., S1=...).
  final Map<String, String> amnezia;

  /// Некритичные замечания парсера (неизвестные секции/ключи, дефолты).
  final List<String> warnings;

  bool get hasAmnezia => amnezia.isNotEmpty;

  /// Копия с переопределёнными полями (используется при подготовке туннеля:
  /// резолвинг endpoint, DNS-override, MTU из UI).
  WireGuardConfig copyWith({
    String? name,
    String? endpointHost,
    int? endpointPort,
    List<String>? dns,
    int? mtu,
    Map<String, String>? amnezia,
    List<String>? warnings,
  }) =>
      WireGuardConfig(
        name: name ?? this.name,
        privateKey: privateKey,
        addresses: addresses,
        peerPublicKey: peerPublicKey,
        peerPresharedKey: peerPresharedKey,
        endpointHost: endpointHost ?? this.endpointHost,
        endpointPort: endpointPort ?? this.endpointPort,
        allowedIps: allowedIps,
        persistentKeepalive: persistentKeepalive,
        dns: dns ?? this.dns,
        mtu: mtu ?? this.mtu,
        amnezia: amnezia ?? this.amnezia,
        warnings: warnings ?? this.warnings,
      );

  /// Восстановление из JSON (последний .conf для авто-реконнекта).
  factory WireGuardConfig.fromJson(Map<String, dynamic> json) {
    final addresses = (json['addresses'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    final allowed = (json['allowedIps'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    final dns = (json['dns'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    final amnezia = <String, String>{};
    final rawAmnezia = json['amnezia'];
    if (rawAmnezia is Map) {
      for (final entry in rawAmnezia.entries) {
        amnezia[entry.key.toString()] = entry.value.toString();
      }
    }
    return WireGuardConfig(
      name: json['name']?.toString() ?? 'AmneziaWG',
      privateKey: json['privateKey']?.toString() ?? '',
      addresses: addresses,
      peerPublicKey: json['peerPublicKey']?.toString() ?? '',
      peerPresharedKey: json['peerPresharedKey']?.toString(),
      endpointHost: json['endpointHost']?.toString() ?? '',
      endpointPort: (json['endpointPort'] as num?)?.toInt() ?? 0,
      allowedIps: allowed.isEmpty ? const ['0.0.0.0/0', '::/0'] : allowed,
      persistentKeepalive: (json['persistentKeepalive'] as num?)?.toInt() ?? 25,
      dns: dns,
      mtu: (json['mtu'] as num?)?.toInt(),
      amnezia: amnezia,
      warnings: (json['warnings'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
    );
  }

  /// Xray-конфигурация с wireguard-outbound.
  ///
  /// Поля сверены с Xray-core `infra/conf/wireguard.go`:
  /// `settings.secretKey`, `settings.address`, `settings.peers[]`
  /// (publicKey / preSharedKey / endpoint / allowedIPs / keepAlive), `mtu`,
  /// `remoteDNS`. Inbounds намеренно отсутствуют — в VPN-режиме flutter_vless
  /// поднимает собственный приватный loopback-SOCKS.
  String toXrayJson() {
    final peer = <String, dynamic>{
      'publicKey': peerPublicKey,
      if (peerPresharedKey != null && peerPresharedKey!.isNotEmpty)
        'preSharedKey': peerPresharedKey,
      'endpoint': '$endpointHost:$endpointPort',
      'allowedIPs': allowedIps,
      if (persistentKeepalive > 0) 'keepAlive': persistentKeepalive,
    };

    final settings = <String, dynamic>{
      'secretKey': privateKey,
      if (addresses.isNotEmpty) 'address': addresses,
      'peers': <dynamic>[peer],
      if (mtu != null && mtu! > 0) 'mtu': mtu,
      if (dns.isNotEmpty) 'remoteDNS': dns,
    };

    return jsonEncode(<String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'wireguard',
          'settings': settings,
        },
      ],
    });
  }

  /// Payload для нативного моста AwgBridge (MethodChannel connect).
  ///
  /// Ключи Amnezia передаются в нижнем регистре как есть — Kotlin-мост
  /// канонизирует их в Jc/Jmin/Jmax/S1/S2/H1..H4 перед Config.parse.
  Map<String, Object?> toNativePayload() => <String, Object?>{
        'name': name,
        'privateKey': privateKey,
        'publicKey': peerPublicKey,
        if (peerPresharedKey != null && peerPresharedKey!.isNotEmpty)
          'presharedKey': peerPresharedKey,
        'endpoint': '$endpointHost:$endpointPort',
        'addresses': addresses,
        'allowedIps': allowedIps,
        'keepalive': persistentKeepalive,
        if (dns.isNotEmpty) 'dns': dns,
        if (mtu != null && mtu! > 0) 'mtu': mtu,
        if (amnezia.isNotEmpty) 'amnezia': amnezia,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'privateKey': privateKey,
        'addresses': addresses,
        'peerPublicKey': peerPublicKey,
        if (peerPresharedKey != null) 'peerPresharedKey': peerPresharedKey,
        'endpointHost': endpointHost,
        'endpointPort': endpointPort,
        'allowedIps': allowedIps,
        'persistentKeepalive': persistentKeepalive,
        'dns': dns,
        if (mtu != null) 'mtu': mtu,
        'amnezia': amnezia,
        'warnings': warnings,
      };
}
