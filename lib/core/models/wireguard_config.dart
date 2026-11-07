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

  bool get hasAmnezia => amnezia.isNotEmpty;

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
      };
}
