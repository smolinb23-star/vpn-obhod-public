import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Статус подключения Mihomo.
enum MihomoTunnelState { disconnected, connecting, connected, error }

/// Результат проверки задержки сервера.
class ServerLatency {
  const ServerLatency({
    required this.name,
    required this.delayMs,
    this.ok = false,
  });

  final String name;
  final int delayMs;
  final bool ok;
}

/// Состояние туннеля Mihomo для UI.
@immutable
class MihomoUiState {
  const MihomoUiState({
    this.state = MihomoTunnelState.disconnected,
    this.currentServer = '',
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.latencyMs,
    this.error,
  });

  final MihomoTunnelState state;
  final String currentServer;
  final int downloadSpeed;
  final int uploadSpeed;
  final int? latencyMs;
  final String? error;

  MihomoUiState copyWith({
    MihomoTunnelState? state,
    String? currentServer,
    int? downloadSpeed,
    int? uploadSpeed,
    int? latencyMs,
    String? error,
    bool clearError = false,
  }) {
    return MihomoUiState(
      state: state ?? this.state,
      currentServer: currentServer ?? this.currentServer,
      downloadSpeed: downloadSpeed ?? this.downloadSpeed,
      uploadSpeed: uploadSpeed ?? this.uploadSpeed,
      latencyMs: latencyMs ?? this.latencyMs,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Сервис для работы с ядром Mihomo (sing-box) через MethodChannel.
///
/// Канал: `dev.local.vpnservice/mihomo`
/// Методы:
///  - start(configJson) — запуск туннеля с JSON-конфигом Mihomo
///  - stop — остановка
///  - getStatus — текущий статус
///  - generateConfig — генерация Mihomo JSON из импортированного конфига
class MihomoService {
  MihomoService._();

  static final MihomoService _instance = MihomoService._();

  factory MihomoService() => _instance;

  final MethodChannel _channel = const MethodChannel(
    'dev.local.vpnservice/mihomo',
  );

  final StreamController<MihomoUiState> _stateCtrl =
      StreamController<MihomoUiState>.broadcast();

  Stream<MihomoUiState> get stateStream => _stateCtrl.stream;

  MihomoUiState _current = const MihomoUiState();

  MihomoUiState get current => _current;

  /// Запускает туннель Mihomo с указанным JSON-конфигом.
  Future<void> start(String mihomoJson) async {
    _emit(MihomoUiState(
      state: MihomoTunnelState.connecting,
      error: null,
    ));
    try {
      await _channel.invokeMethod('start', {'config': mihomoJson});
      _stateSubscription?.cancel();
      _stateSubscription = _channel
          .receiveBroadcastStream('status')
          .listen(_onStatus, onError: (_) {});
    } on Exception catch (e) {
      _emit(MihomoUiState(
        state: MihomoTunnelState.error,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  /// Останавливает туннель.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on Object {
      // ignore
    }
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _emit(const MihomoUiState(state: MihomoTunnelState.disconnected));
  }

  StreamSubscription? _stateSubscription;

  void _onStatus(dynamic data) {
    try {
      final map = data as Map;
      final connState = map['connectionState'] as String?;
      final server = map['currentServer'] as String? ?? '';
      final dl = (map['downloadSpeed'] as num?)?.toInt() ?? 0;
      final ul = (map['uploadSpeed'] as num?)?.toInt() ?? 0;
      final latency = (map['latencyMs'] as num?)?.toInt();

      final mapped = switch (connState) {
        'connected' => MihomoTunnelState.connected,
        'connecting' => MihomoTunnelState.connecting,
        'disconnected' => MihomoTunnelState.disconnected,
        'error' => MihomoTunnelState.error,
        _ => MihomoTunnelState.disconnected,
      };

      _emit(MihomoUiState(
        state: mapped,
        currentServer: server,
        downloadSpeed: dl,
        uploadSpeed: ul,
        latencyMs: latency,
      ));
    } on Object {
      // ignore malformed status
    }
  }

  void _emit(MihomoUiState state) {
    _current = state;
    _stateCtrl.add(state);
  }

  /// Генерирует Mihomo JSON-конфиг из импортированного профиля.
  ///
  /// Поддерживает:
  ///  - Clash/Mihomo YAML (сグループ url-test для автовыбора сервера)
  ///  - Xray JSON (WireGuard + Noise)
  ///  - AmneziaWG .conf (Jc, Jmin, H1-H4, I1-I5 и т.д.)
  ///  - VLESS / Hysteria2 / другие протоколы через sing-box
  static String generateMihomoConfig({
    required String rawConfig,
    required String configType,
    List<String> excludedApps = const [],
  }) {
    final gen = _MihomoConfigGenerator();
    return gen.generate(rawConfig, configType, excludedApps);
  }

  void dispose() {
    _stateSubscription?.cancel();
    _stateCtrl.close();
  }
}

/// Провайдер MihomoService.
final mihomoServiceProvider = Provider<MihomoService>((ref) {
  return MihomoService();
});

/// Генератор Mihomo JSON-конфигурации.
class _MihomoConfigGenerator {
  String generate(String rawConfig, String configType,
      List<String> excludedApps) {
    switch (configType) {
      case 'clash':
      case 'mihomo':
        return _buildClashMihomoConfig(rawConfig, excludedApps);
      case 'xray':
        return _buildXrayMihomoConfig(rawConfig, excludedApps);
      case 'awg':
      case 'wireguard':
        return _buildAmneziaWgMihomoConfig(rawConfig, excludedApps);
      case 'vless':
      case 'hysteria2':
      case 'other':
        return _buildGenericMihomoConfig(rawConfig, configType, excludedApps);
      default:
        return _buildGenericMihomoConfig(rawConfig, configType, excludedApps);
    }
  }

  // ===== Clash / Mihomo YAML =====

  String _buildClashMihomoConfig(String rawYaml,
      List<String> excludedApps) {
    // Простой парсер YAML без внешних зависимостей — ищем proxies
    final proxies = _extractProxiesFromYaml(rawYaml);
    final proxyNames = proxies.map((p) => p['name'] as String).toList();

    // Группа url-test для автоматического выбора лучшего сервера
    final urlTestGroup = {
      'type': 'url-test',
      'tag': 'proxy',
      'url': 'https://cp.cloudflare.com/generate_204',
      'interval': '30s',
      'proxies': proxyNames,
    };

    // Правила для split tunneling (PROCESS-NAME)
    final rules = <Map<String, dynamic>>[];
    if (excludedApps.isNotEmpty) {
      rules.add({
        'type': 'process-name',
        'process_name': excludedApps,
        'outboundTag': 'direct',
      });
    }
    rules.addAll([
      {'type': 'match', 'outboundTag': 'proxy'},
    ]);

    final config = <String, dynamic>{
      'log': <String, dynamic>{
        'level': 'info',
        'timestamp': true,
      },
      'dns': <String, dynamic>{
        'servers': <String, dynamic>{
          'local': <String, dynamic>[
            <String, dynamic>{
              'address': '1.1.1.1',
              'address_resolver': '1.1.1.1',
              'strategy': 'ipv4_only',
            },
          ],
        },
        'rules': <dynamic>[
          {'outbound': 'any', 'server': 'local'},
        ],
        'final': 'local',
        'independent_cache': true,
      },
      'inbounds': <dynamic>[
        <String, dynamic>{
          'type': 'tun',
          'tag': 'tun-in',
          'address': <dynamic>['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
        },
      ],
      'outbounds': <dynamic>[
        <String, dynamic>{
          'type': 'selector',
          'tag': 'proxy',
          'outbounds': <dynamic>['url-test'],
        },
        urlTestGroup,
        ...proxies,
        <String, dynamic>{
          'type': 'direct',
          'tag': 'direct',
        },
        <String, dynamic>{
          'type': 'block',
          'tag': 'block',
        },
      ],
      'route': <String, dynamic>{
        'rules': rules,
        'final': 'proxy',
        'auto_detect_interface': true,
      },
      'experimental': <String, dynamic>{
        'cache_file': <String, dynamic>{
          'enabled': true,
          'path': 'cache.db',
        },
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  // ===== Xray JSON (WireGuard + Noise) =====

  String _buildXrayMihomoConfig(String rawJson,
      List<String> excludedApps) {
    // Xray JSON можно использовать как-is для sing-box (конвертация протоколов)
    // Но для надёжности создаём обёртку с нашими outbounds
    try {
      final xrayMap = jsonDecode(rawJson) as Map<String, dynamic>;
      final outbounds = xrayMap['outbounds'] as List<dynamic>?;
      if (outbounds == null || outbounds.isEmpty) {
        return _buildGenericMihomoConfig(rawJson, 'xray', excludedApps);
      }

      final firstOutbound = outbounds.first as Map<String, dynamic>;
      final protocol = firstOutbound['protocol'] as String?;

      // Преобразуем Xray outbound в sing-box формат
      final sbOutbound = _convertXrayOutboundToSingBox(firstOutbound);

      final rules = <Map<String, dynamic>>[];
      if (excludedApps.isNotEmpty) {
        rules.add({
          'type': 'process-name',
          'process_name': excludedApps,
          'outboundTag': 'direct',
        });
      }
      rules.add({'type': 'match', 'outboundTag': 'proxy'});

      final config = <String, dynamic>{
        'log': <String, dynamic>{'level': 'info'},
        'dns': <String, dynamic>{
          'servers': <String, dynamic>{
            'local': <String, dynamic>[
              {'address': '1.1.1.1', 'strategy': 'ipv4_only'},
            ],
          },
          'final': 'local',
        },
        'inbounds': <dynamic>[
          <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            'address': <dynamic>['172.19.0.1/30'],
            'auto_route': true,
            'strict_route': true,
          },
        ],
        'outbounds': <dynamic>[
          sbOutbound,
          <String, dynamic>{'type': 'direct', 'tag': 'direct'},
          <String, dynamic>{'type': 'block', 'tag': 'block'},
        ],
        'route': <String, dynamic>{
          'rules': rules,
          'final': 'proxy',
        },
      };

      return const JsonEncoder.withIndent('  ').convert(config);
    } on Object {
      return _buildGenericMihomoConfig(rawJson, 'xray', excludedApps);
    }
  }

  // ===== AmneziaWG .conf =====

  String _buildAmneziaWgMihomoConfig(String rawConf,
      List<String> excludedApps) {
    // Парсим ключи AmneziaWG из .conf
    final privateKey = _extractConfValue(rawConf, 'PrivateKey');
    final peerPublicKey = _extractConfValue(rawConf, 'PublicKey');
    final address = _extractConfValue(rawConf, 'Address');
    final endpoint = _extractConfValue(rawConf, 'Endpoint');
    final dns = _extractConfValue(rawConf, 'DNS') ?? '1.1.1.1';
    final mtu = _extractConfValue(rawConf, 'MTU') ?? '1280';

    // Amnezia-параметры
    final amneziaParams = <String, String>{};
    for (final key in [
      'Jc', 'Jmin', 'Jmax', 'H1', 'H2', 'H3', 'H4',
      'S1', 'S2', 'S3', 'S4',
      'I1', 'I2', 'I3', 'I4', 'I5',
      'ContentPaddingAddition', 'RekeyAfterTime',
      'RejectAfterTime', 'MaxHandshakeAttempts',
    ]) {
      final val = _extractConfValue(rawConf, key);
      if (val != null && val.isNotEmpty) {
        amneziaParams[key] = val;
      }
    }

    final epParts = _splitEndpoint(endpoint);
    final server = epParts.$1;
    final port = epParts.$2 ?? 51820;

    final rules = <Map<String, dynamic>>[];
    if (excludedApps.isNotEmpty) {
      rules.add({
        'type': 'process-name',
        'process_name': excludedApps,
        'outboundTag': 'direct',
      });
    }
    rules.add({'type': 'match', 'outboundTag': 'proxy'});

    final wireguardOutbound = <String, dynamic>{
      'type': 'wireguard',
      'tag': 'proxy',
      'server': server,
      'server_port': port,
      'local_address': <dynamic>[],
      'private_key': privateKey,
      'peer_public_key': peerPublicKey,
      'reserved': <dynamic>[],
      'mtu': int.tryParse(mtu) ?? 1280,
    };

    // Добавляем адреса
    if (address != null && address.isNotEmpty) {
      final addrs = address.split(',').map((e) => e.trim()).toList();
      wireguardOutbound['local_address'] = addrs;
    }

    // Добавляем Amnezia-обфускацию
    if (amneziaParams.isNotEmpty) {
      wireguardOutbound['amnezia'] = <String, dynamic>{};
      amneziaParams.forEach((k, v) {
        wireguardOutbound['amnezia'][k.toLowerCase()] = v;
      });
    }

    final config = <String, dynamic>{
      'log': <String, dynamic>{'level': 'info'},
      'dns': <String, dynamic>{
        'servers': <String, dynamic>{
          'local': <String, dynamic>[{'address': dns, 'strategy': 'ipv4_only'}],
        },
        'final': 'local',
      },
      'inbounds': <dynamic>[
        <String, dynamic>{
          'type': 'tun',
          'tag': 'tun-in',
          'address': <dynamic>['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
        },
      ],
      'outbounds': <dynamic>[
        wireguardOutbound,
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
      ],
      'route': <String, dynamic>{
        'rules': rules,
        'final': 'proxy',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  // ===== Generic (VLESS, Hysteria2, etc.) =====

  String _buildGenericMihomoConfig(String rawConfig, String type,
      List<String> excludedApps) {
    // Для неизвестных типов создаём базовый конфиг с прямым подключением
    // или пытаемся использовать как sing-box JSON
    try {
      final decoded = jsonDecode(rawConfig) as Map<String, dynamic>?;
      if (decoded != null) {
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
    } on Object {
      // ignore
    }

    // Fallback: direct connection
    final config = <String, dynamic>{
      'log': <String, dynamic>{'level': 'info'},
      'dns': <String, dynamic>{
        'servers': <String, dynamic>{
          'local': <String, dynamic>[{'address': '1.1.1.1', 'strategy': 'ipv4_only'}],
        },
        'final': 'local',
      },
      'inbounds': <dynamic>[
        <String, dynamic>{
          'type': 'tun',
          'tag': 'tun-in',
          'address': <dynamic>['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
        },
      ],
      'outbounds': <dynamic>[
        <String, dynamic>{'type': 'direct', 'tag': 'proxy'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
      ],
      'route': <String, dynamic>{
        'rules': excludedApps.isNotEmpty
            ? <Map<String, dynamic>>[
                {'type': 'process-name', 'process_name': excludedApps, 'outboundTag': 'direct'},
                {'type': 'match', 'outboundTag': 'proxy'},
              ]
            : <Map<String, dynamic>>[{'type': 'match', 'outboundTag': 'proxy'}],
        'final': 'proxy',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  // ===== Helpers =====

  /// Извлекает список прокси из Clash/Mihomo YAML.
  List<Map<String, dynamic>> _extractProxiesFromYaml(String yaml) {
    final result = <Map<String, dynamic>>[];
    // Простой парсер: ищем блоки "- name:" внутри "proxies:"
    final lines = yaml.split('\n');
    var inProxies = false;
    var currentProxy = <String, dynamic>{};
    var indentLevel = -1;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      if (trimmed.startsWith('proxies:')) {
        inProxies = true;
        continue;
      }

      if (inProxies) {
        final currentIndent = line.length - line.trimLeft().length;
        if (indentLevel == -1) {
          indentLevel = currentIndent;
        }

        if (currentIndent < indentLevel) {
          // Вышли из блока proxies
          if (currentProxy.isNotEmpty &&
              currentProxy.containsKey('name')) {
            result.add(currentProxy);
          }
          inProxies = false;
          indentLevel = -1;
          currentProxy = <String, dynamic>{};
          continue;
        }

        if (trimmed.startsWith('- name:')) {
          if (currentProxy.isNotEmpty &&
              currentProxy.containsKey('name')) {
            result.add(currentProxy);
          }
          currentProxy = <String, dynamic>{
            'name': trimmed.substring(7).trim(),
            'type': '',
            'server': '',
            'port': 0,
          };
          continue;
        }

        if (currentProxy.isNotEmpty) {
          if (trimmed.startsWith('type:')) {
            currentProxy['type'] = trimmed.substring(5).trim();
          } else if (trimmed.startsWith('server:')) {
            currentProxy['server'] = trimmed.substring(7).trim();
          } else if (trimmed.startsWith('port:')) {
            currentProxy['port'] = int.tryParse(trimmed.substring(5).trim()) ?? 0;
          } else if (trimmed.startsWith('private-key:')) {
            currentProxy['private-key'] = trimmed.substring(12).trim();
          } else if (trimmed.startsWith('public-key:')) {
            currentProxy['public-key'] = trimmed.substring(11).trim();
          }
        }
      }
    }

    if (currentProxy.isNotEmpty && currentProxy.containsKey('name')) {
      result.add(currentProxy);
    }

    return result;
  }

  /// Конвертирует Xray outbound в sing-box формат.
  Map<String, dynamic> _convertXrayOutboundToSingBox(
      Map<String, dynamic> xrayOutbound) {
    final protocol = xrayOutbound['protocol'] as String?;
    final settings = xrayOutbound['settings'] as Map<String, dynamic>? ?? {};

    switch (protocol) {
      case 'wireguard':
        return {
          'type': 'wireguard',
          'tag': 'proxy',
          'server': settings['address'] ?? '',
          'server_port': settings['port'] ?? 51820,
          'local_address': <dynamic>[],
          'private_key': settings['secretKey'] ?? '',
          'peer_public_key': settings['peerPublicKey'] ?? '',
          'mtu': settings['mtu'] ?? 1280,
        };
      case 'vless':
        return {
          'type': 'vless',
          'tag': 'proxy',
          'server': settings['address'] ?? '',
          'server_port': settings['port'] ?? 443,
          'uuid': settings['uuid'] ?? '',
          'network': settings['network'] ?? 'tcp',
          'security': settings['security'] ?? 'none',
        };
      case 'hysteria2':
        return {
          'type': 'hysteria2',
          'tag': 'proxy',
          'server': settings['address'] ?? '',
          'server_port': settings['port'] ?? 443,
          'password': settings['password'] ?? '',
        };
      default:
        return {
          'type': 'direct',
          'tag': 'proxy',
        };
    }
  }

  /// Извлекает значение ключа из .conf.
  String? _extractConfValue(String conf, String key) {
    final regex = RegExp(
      r'^\s*' + RegExp.escape(key) + r'\s*=\s*(.+?)\s*$',
      multiLine: true,
      caseSensitive: false,
    );
    final match = regex.firstMatch(conf);
    return match?.group(1)?.trim();
  }

  /// Разбивает endpoint на хост и порт.
  (String?, int?) _splitEndpoint(String? value) {
    if (value == null || value.isEmpty) return (null, null);
    final v = value.trim();
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close > 0) {
        final host = v.substring(1, close);
        final rest = v.substring(close + 1);
        final port =
            rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
        return (host, port);
      }
      return (v, null);
    }
    final last = v.lastIndexOf(':');
    if (last <= 0) return (v, null);
    return (v.substring(0, last), int.tryParse(v.substring(last + 1)));
  }
}
