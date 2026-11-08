/// Пресеты I1 — «специального» пакета-сигнатуры AmneziaWG.
///
/// I1 отправляется перед handshake и не несёт данных; серверу его значение
/// знать не нужно. Синтаксис (amneziawg-go):
///  - `<b 0x...>`  — статические байты (hex, чётное число символов);
///  - `<r N>`      — N случайных байт;
///  - `<rd N>`     — N случайных цифр;
///  - `<rc N>`     — N случайных латинских букв;
///  - `<t>`        — 4 байта текущего UNIX-времени.
///
/// DPI-блокировка после handshake (RX почти 0, TX растёт) часто лечится
/// подбором I1 и MTU без пересборки APK.
class AwgI1Preset {
  const AwgI1Preset({
    required this.id,
    required this.label,
    required this.description,
    required this.value,
  });

  final String id;
  final String label;
  final String description;

  /// Значение для `I1 = ...`; пустая строка — I1 не отправляется.
  final String value;

  static const AwgI1Preset none = AwgI1Preset(
    id: 'default',
    label: 'По умолчанию (без I1)',
    description: 'Ничего не отправлять перед handshake — поведение AWG 1.x',
    value: '',
  );

  /// Валидный DNS-ответ: A-запись www.google.com → 93.184.216.34.
  static const AwgI1Preset dns = AwgI1Preset(
    id: 'dns',
    label: 'DNS-ответ',
    description: 'Имитация UDP-ответа DNS (A www.google.com)',
    value: '<b 0x1234818000010001000000000377777706676f6f676c6503636f6d0000010001c00c000100010000003c00045db8d822>',
  );

  /// Правдоподобный QUIC Initial: long header + случайные DCID/payload.
  static const AwgI1Preset quic = AwgI1Preset(
    id: 'quic',
    label: 'QUIC Initial',
    description: 'QUIC long header (версия 1) со случайными байтами',
    value: '<b 0xc30000000108><r 8><b 0x00><r 32>',
  );

  /// STUN binding request — часто проходит DPI, т.к. STUN разрешён.
  static const AwgI1Preset stun = AwgI1Preset(
    id: 'stun',
    label: 'STUN binding',
    description: 'STUN binding request (magic cookie + случайный transaction ID)',
    value: '<b 0x000100002112a442><r 12>',
  );

  /// Валидная по структуре запись TLS 1.2 ClientHello (без SNI).
  static const AwgI1Preset tls = AwgI1Preset(
    id: 'tls',
    label: 'TLS ClientHello',
    description: 'Запись TLS 1.2 ClientHello со случайным random',
    value: '<b 0x160301003b010000370303><r 32><b 0x000002002f0100000c000a00080006001700180019>',
  );

  /// Просто случайный шум — иногда помогает против сигнатурных DPI.
  static const AwgI1Preset random = AwgI1Preset(
    id: 'random',
    label: 'Случайные байты',
    description: '64 случайных байта без сигнатуры',
    value: '<r 64>',
  );

  static const List<AwgI1Preset> all = <AwgI1Preset>[
    none,
    dns,
    quic,
    stun,
    tls,
    random,
  ];

  static AwgI1Preset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// Пресет, точно совпадающий со значением; null — ручной ввод.
  static AwgI1Preset? match(String value) {
    final v = value.trim();
    for (final preset in all) {
      if (preset.value == v) return preset;
    }
    return null;
  }

  /// Проверяет синтаксис I1. null — значение корректно (пустое тоже).
  static String? validate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (value.length > 2048) {
      return 'I1 слишком длинная: ${value.length} символов (максимум 2048)';
    }

    var i = 0;
    while (i < value.length) {
      final ch = value[i];
      if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        i++;
        continue;
      }
      if (ch != '<') {
        return 'Неожиданный символ «$ch» на позиции $i: ожидается тег <...>';
      }
      final close = value.indexOf('>', i);
      if (close < 0) return 'Незакрытый тег < на позиции $i';
      final body = value.substring(i + 1, close).trim();
      if (body.isEmpty) return 'Пустой тег <> на позиции $i';

      if (body == 't') {
        i = close + 1;
        continue;
      }

      final space = body.indexOf(RegExp(r'\s'));
      final name = space < 0 ? body : body.substring(0, space);
      final arg = space < 0 ? '' : body.substring(space + 1).trim();

      switch (name) {
        case 'b':
          if (!arg.startsWith('0x')) {
            return 'Тег <b> требует hex-значение с префиксом 0x';
          }
          final hex = arg.substring(2);
          if (hex.isEmpty ||
              hex.length.isOdd ||
              !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
            return 'Тег <b 0x...>: нужен непустой hex с чётным числом символов';
          }
          break;
        case 'r':
        case 'rd':
        case 'rc':
          final n = int.tryParse(arg);
          if (n == null || n < 1 || n > 1200) {
            return 'Тег <$name N>: N должно быть числом от 1 до 1200';
          }
          break;
        default:
          return 'Неизвестный тег <$body>. Допустимы <b 0x...>, '
              '<r N>, <rd N>, <rc N>, <t>';
      }
      i = close + 1;
    }
    return null;
  }
}
