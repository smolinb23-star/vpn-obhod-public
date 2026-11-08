import 'dart:async';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:http/http.dart' as http;

import 'package:vpn_service/core/models/vpn_config.dart';
import 'package:vpn_service/core/services/profile_parser.dart';
import 'package:vpn_service/core/services/wireguard_parser.dart';
import 'package:vpn_service/features/vpn/services/vpn_service.dart';

/// Провайдер сервиса туннеля.
final vpnServiceProvider = Provider<VpnService>((ref) {
  final service = VpnService();
  ref.onDispose(service.dispose);
  return service;
});

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

/// Состояние подключения для UI.
@immutable
class VpnUiState {
  const VpnUiState({
    this.state = TunnelState.disconnected,
    this.metrics = const TunnelMetrics(),
    this.remark = '',
    this.error,
    this.ipBefore,
    this.ipAfter,
    this.config,
  });

  final TunnelState state;
  final TunnelMetrics metrics;
  final String remark;
  final String? error;
  final String? ipBefore;
  final String? ipAfter;
  final VpnConfig? config;

  VpnUiState copyWith({
    TunnelState? state,
    TunnelMetrics? metrics,
    String? remark,
    String? error,
    bool clearError = false,
    String? ipBefore,
    String? ipAfter,
    VpnConfig? config,
  }) {
    return VpnUiState(
      state: state ?? this.state,
      metrics: metrics ?? this.metrics,
      remark: remark ?? this.remark,
      error: clearError ? null : (error ?? this.error),
      ipBefore: ipBefore ?? this.ipBefore,
      ipAfter: ipAfter ?? this.ipAfter,
      config: config ?? this.config,
    );
  }
}

class VpnController extends Notifier<VpnUiState> {
  static const _lastProfileKey = 'last_profile';
  static const _subscriptionKey = 'subscription_url';

  VpnService get _service => ref.read(vpnServiceProvider);
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  StreamSubscription? _statusSub;
  bool _autoReconnecting = false;

  @override
  VpnUiState build() {
    _statusSub?.cancel();
    _statusSub = _service.statusStream.listen(_onStatus);
    ref.onDispose(() => _statusSub?.cancel());
    return const VpnUiState();
  }

  void _onStatus(VlessStatus status) {
    final mapped = switch (status.connectionState) {
      VlessConnectionState.connected => TunnelState.connected,
      VlessConnectionState.connecting => TunnelState.connecting,
      VlessConnectionState.disconnecting => TunnelState.connecting,
      VlessConnectionState.disconnected => TunnelState.disconnected,
      VlessConnectionState.unknown => null,
    };
    if (mapped != null) {
      state = state.copyWith(state: mapped);
    }
    // Тихий fallback: если соединение оборвалось — перезапускаем автопоиск.
    if (status.connectionState == VlessConnectionState.disconnected &&
        state.state == TunnelState.disconnected &&
        !_autoReconnecting) {
      _autoReconnecting = true;
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        _autoReconnecting = false;
        if (state.state == TunnelState.disconnected) {
          await autoConnect();
        }
      }));
    }
  }

  /// Импортирует профиль (ссылка/JSON/подписка) и запоминает его.
  ///
  /// Основной путь — чистый Dart-парсер [ProfileParser]; при неподдерживаемом
  /// формате используется fallback `FlutterVless.parse()` (подписки, Clash
  /// YAML, sing-box JSON, экзотические протоколы).
  Future<VpnConfig?> importProfile(String input) async {
    VpnConfig? config;
    // WireGuard/AmneziaWG .conf, вставленный как текст.
    if (WGConfigParser.looksLikeWireGuardConf(input)) {
      try {
        config = const WGConfigParser().importConf(input);
      } on WGConfigParseException catch (e) {
        state = state.copyWith(error: 'WireGuard-конфиг: ${e.message}');
        return null;
      }
    }
    if (config == null) {
      try {
        config = const ProfileParser().parseOne(input);
      } on Object {
        config = _parseWithPlugin(input);
      }
    }
    if (config == null) {
      state = state.copyWith(error: 'Импорт не удался: формат не распознан');
      return null;
    }
    await _storage.write(key: _lastProfileKey, value: config.toJsonString());
    state = state.copyWith(remark: config.remark, clearError: true);
    return config;
  }

  /// Сохраняет уже разобранный профиль (например, из .conf-импорта)
  /// без повторного парсинга.
  Future<void> saveProfile(VpnConfig config) async {
    await _storage.write(key: _lastProfileKey, value: config.toJsonString());
    state = state.copyWith(remark: config.remark, clearError: true);
  }

  VpnConfig? _parseWithPlugin(String input) {
    try {
      final parsed = FlutterVless.parse(input);
      return VpnConfig(
        remark: parsed.remark,
        protocol: ProfileProtocol.other,
        xrayJson: parsed.getFullConfiguration(),
      );
    } on Object {
      return null;
    }
  }

  Future<VpnConfig?> restoreLast() async {
    final raw = await _storage.read(key: _lastProfileKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return VpnConfig.fromJson(decoded);
      }
    } on Object {
      // повреждённое хранилище — молча игнорируем
    }
    return null;
  }

  Future<void> connect(VpnConfig config) async {
    state = state.copyWith(state: TunnelState.connecting, clearError: true);
    try {
      await _service.initialize();
      // CONNECTED может наступить сразу после start(), подписываемся заранее.
      final connected = Completer<void>();
      late final StreamSubscription<VlessStatus> sub;
      sub = _service.statusStream.listen((s) {
        if (s.connectionState == VlessConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        }
      });
      try {
        await _service.start(config);
        state = state.copyWith(
          state: TunnelState.connecting,
          remark: config.remark,
          config: config,
        );
        // Проверка реального трафика после установления соединения.
        unawaited(_verifyTraffic(connected).whenComplete(sub.cancel));
      } catch (_) {
        await sub.cancel();
        rethrow;
      }
    } on Object catch (e) {
      state = state.copyWith(state: TunnelState.error, error: '$e');
    }
  }

  Future<void> autoConnect({String? subscription}) async {
    final input = subscription ??
        await _storage.read(key: _subscriptionKey) ??
        '';
    state = state.copyWith(
      state: TunnelState.connecting,
      remark: 'Поиск сервера…',
      clearError: true,
    );

    List<VpnConfig> configs = <VpnConfig>[];
    if (input.startsWith('http://') || input.startsWith('https://')) {
      final client = http.Client();
      try {
        final resp = await client
            .get(Uri.parse(input))
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          configs = const ProfileParser().parseAll(resp.body);
        }
      } on Object {
        // ignore
      } finally {
        client.close();
      }
    } else if (input.isNotEmpty) {
      try {
        configs = const ProfileParser().parseAll(input);
      } on Object {
        // ignore
      }
    }

    if (configs.isEmpty) {
      final last = await restoreLast();
      if (last != null) configs = <VpnConfig>[last];
    }

    if (configs.isEmpty) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Нет конфигураций. Вставьте подписку или конфиг.',
      );
      return;
    }

    // Probe: замеряем задержку, отбрасываем недоступные. Общий таймаут 15 с.
    List<(VpnConfig, int?)> probed;
    try {
      probed = await Future.wait(
        configs.map((c) async {
          final delay = await _service.probeDelay(c);
          return (c, delay);
        }),
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось найти рабочий сервер за 15 с. '
            'Проверьте конфиг или смените сеть (на мобильном интернете '
            'AmneziaWG может блокироваться).',
      );
      return;
    }

    final viable = probed.where((p) => p.$2 != null).toList()
      ..sort((a, b) => a.$2!.compareTo(b.$2!));

    if (viable.isEmpty) {
      for (final c in configs) {
        try {
          await connect(c);
          if (state.state == TunnelState.connected) return;
        } on Object {
          continue;
        }
      }
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось найти рабочий сервер. Проверьте конфиг или '
            'смените сеть (на мобильном интернете AmneziaWG может '
            'блокироваться).',
      );
      return;
    }

    for (final entry in viable) {
      try {
        await connect(entry.$1);
        if (state.state == TunnelState.connected) return;
      } on Object {
        continue;
      }
    }
    if (state.state != TunnelState.connected) {
      state = state.copyWith(
        state: TunnelState.error,
        error: 'Не удалось подключиться ни к одному серверу. Проверьте '
            'конфиг или смените сеть (на мобильном интернете AmneziaWG '
            'может блокироваться).',
      );
    }
  }

  Future<void> setSubscription(String url) async {
    await _storage.write(key: _subscriptionKey, value: url);
  }

  Future<void> _verifyTraffic(Completer<void> connected) async {
    try {
      await connected.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      state = state.copyWith(
        error: 'Таймаут подключения: состояние CONNECTED не достигнуто',
      );
      return;
    }
    final changed = await _service.verifyRealTraffic();
    final after = await _service.fetchPublicIp();
    state = state.copyWith(ipAfter: after);
    if (changed == false) {
      state = state.copyWith(
        error: 'Handshake прошёл, но IP не изменился — метод отклонён',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await _service.stop();
    } finally {
      state = state.copyWith(state: TunnelState.disconnected);
    }
  }
}

final vpnControllerProvider =
    NotifierProvider<VpnController, VpnUiState>(VpnController.new);
