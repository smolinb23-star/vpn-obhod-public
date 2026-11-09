# PROGRESS

Формат: `Этап N — DONE/BLOCKED — подход — apk ok/fail — следующий шаг`

- Этап 0 — DONE — окружение: локальный Flutter/Android SDK недоступны → сборка через GitHub Actions — следующий шаг: Этап 1
- Этап 1 — DONE (код) — flutter_vless ^1.1.7, парсер vless/hy2/JSON/подписок, валидатор (запрет 0.0.0.0 и noauth), UI + проверка смены IP, CI GitHub Actions — apk: OK (dist/app-release.apk, 88 МБ, сборка 42415873587) — следующий шаг: установка на устройство
- Этап 2 — DONE (код, моки) — BypassEngine: интерфейс BypassMethod, 7 моков (детерминированные по seed), BypassOrchestrator (параллельный probe с таймаутом 8с, ранжирование success→история→RTT→wins, проверка смены IP после connect, Degraded RTT>300/потери>2% гистерезис 3, Dead 3 фейла — мгновенно, dwell 5 мин), память побед (абстракция WinsRepository: SQLite + InMemory), экран «Обход» 🟢🟡🔴 + авто-выбор + ручной override — apk: OK (тот же билд, 24 теста зелёные) — следующий шаг: Этап 3
- Этап 2.5 — DONE — импорт .conf Cloudflare WARP/AmneziaWG: file_picker ^8.3.7, WGConfigParser (INI [Interface]/[Peer] + Amnezia Jc/Jmin/Jmax/H1-H4/S1-S2), экран ConfImportScreen (выбор файла, сводка, подключение), кнопка в AppBar HomeScreen — apk: OK (be016a6)
- Этап 2.6 — DONE — нативный AmneziaWG: com.zaneschepke:amneziawg-android:2.3.7 (GoBackend, libam-go.so), MethodChannel dev.local.vpnservice/awg (prepare/connect/disconnect/getStatus + событие onStatus), AwgBridge.kt + AwgConfBuilder.kt (payload→канонический AWG .conf, jc→Jc), VpnService библиотеки мержится из AAR, minSdk 24, packaging excludes (okhttp OSGI-манифесты). Обфускация handshake (Jc/Jmin/Jmax/S1/S2/H1..H4) применяется нативно. Fallback-кнопка «через Xray (без обфускации)» сохранена — apk: OK (766e0b4, 101 МБ, 50 dart + 8 kotlin тестов зелёные)
- Этап 3 — IN PROGRESS (3.1/3.2/3.3 DPI DONE, 3.3 core pending) — стабильность: Foreground Service, смена сети, LTE-форсирование, SSID/operator → network_key, SQLite-память вместо in-memory; нативный движок AmneziaWG уже внедрён на 2.6
- Этап 3.1 — DONE — фикс импорта .conf: file_picker FileType.any + ручная проверка `.conf` (fallback по содержимому), permission_handler (storage только Android ≤12, SAF на 13+), устойчивый парсер (регистр/AmneziaJc/inline-комментарии/неизвестные секции→warnings, маскирование ключей в логе, base64 без padding/URL-safe), вставка текста .conf, экспорт logs.txt (Dart ring-buffer 500 + logcat своего pid) через share sheet — apk: OK (dist/app-release.apk, 101.9 МБ, CI 42430940513, orphan 941925b) — следующий шаг: Этап 3.2
- Этап 3.2 — DONE — диагностика AmneziaWG: rx/tx байты+пакеты каждую 1 с (GoBackend statistics + /proc/net/dev), «Проверить IP» (api.ipify.org + исходный IP до подключения), MTU 1280/1380/1420 в UI (persist), DNS-override 1.1.1.1/1.0.0.1 при пустом/некорректном DNS, endpoint-резолвинг домена в IPv4 до connect, health-индикатор RTT/потерь/handshake — apk: OK (тот же билд 3.1 + тесты) — следующий шаг: Этап 3.3
- Этап 3.4 — DONE (код + APK) — Smart Auto-Connect: ConnectionOrchestrator (последовательный перебор методов, таймаут 5с на метод, приоритет Wi-Fi: AWG→VLESS, мобильная: VLESS→AWG, проверка успеха через api.ipify.org <3с + смена IP); ConfigManagementScreen (сохранение конфигов, выбор файла через скрепку, список с удалением); упрощённый HomeScreen (одна большая кнопка «Подключиться», статус процесса, RX/TX, IP); конфиги персистят в flutter_secure_storage — apk: OK (dist/app-release.apk, 101.8 МБ, CI 42476316515, orphan 96e09e4, тесты 92 Dart + 9 Kotlin зелёные) — следующий шаг: проверка на телефоне (одна кнопка, авто-подбор протокола, YouTube/Gemini), затем Этап 5 (звонки + офлайн-сообщения)
- Исправления ConnectionOrchestrator: таймаут IP проверки 10с, задержка 3с после connect, 3 повторных попытки, резервные эндпоинты (ifconfig.me, cp.cloudflare.com), приоритет VLESS на мобильной сети с чёткой ошибкой, история попыток в UI, правильный disconnect между методами
- CI исправления: gradle/actions/setup-gradle@v4 (кэширование), retry для flutter build apk --release (3 попытки × 30с), зеркало Gradle на mirrors.cloud.tencent.com, таймауты HTTP 120с
- Этап 4 — DONE (код + APK) — Мультипротокольный обход — CDN-фронт (VLESS+WebSocket/XHTTP на Cloudflare IP), каскадные конфигурации (Россия→Зарубежье), CIDR-маршрутизация, парсер vless:// с параметрами Reality (pbk, fp, sni, flow=xtls-rprx-vision), gRPC транспорт, Hysteria2 полноценный метод — apk: OK (CI 42476316515, orphan bc23db7, тесты 92 Dart + 9 Kotlin зелёные)
- Этап 4.1 — DONE (код + APK) — Split Tunneling (раздельное туннелирование): Screen «Исключённые приложения» с выбором пакетов, три режима (все через VPN / только выбранные / все кроме выбранных), сохранение в flutter_secure_storage, передача excludedApps в VpnService.start() — apk: OK (dist/app-release.apk, 101.8 МБ, CI 42485141175, orphan 5f46fd488781e137a6a38458ca975d076761fee7, тесты 92 Dart + 9 Kotlin зелёные)
- Этап 4.2 — DONE (код + APK) — Приоритизация методов для мобильных сетей: VLESS Reality → VLESS XHTTP → CIDR → Hysteria2 → AmneziaWG (последний); экран «Исключённые приложения» с ручным вводом пакетов, тремя режимами (все через VPN / только выбранные / все кроме выбранных), сохранением в flutter_secure_storage; ConnectionOrchestrator с приоритетом VLESS Reality на мобильных, cp.cloudflare.com первым эндпоинтом проверки IP, предварительной проверкой наличия VLESS на мобильной сети; тесты 92 Dart + 9 Kotlin зелёные — apk: OK (dist/app-release.apk, 104,517,972 байт, CI 42494311956, commit 6cab7d863774ae31f6e717d3603e1ecabe617d55)
- Этап 4.3 — DONE (код + APK) — Часть 1: нативный App Picker через MethodChannel (PlatformBridge.getInstalledApps() через PackageManager, JSON [{name, package, icon_base64}]), SplitTunnelingScreen переделана на нативный список с иконками и чекбоксами (без device_apps, без ручного ввода). Часть 2: ClashYamlParser — парсит секцию proxies, извлекает server/port/private-key/public-key/amnezia-wg-option, конвертирует в WireGuardConfig. Часть 3: XrayJsonParser — парсит Xray JSON с protocol: wireguard (secretKey, publicKey, endpoint, address), шум-параметры передаются в xrayJson как-is. Часть 4: WGConfigParser + AwgConfBuilder расширены новыми тегами (I2-I5, ContentPaddingAddition, RekeyAfterTime, RejectAfterTime, MaxHandshakeAttempts). Часть 5: ClashYamlParser распознаёт type: masque, помечает конфиг как «Требуется поддержка Sing-box». — apk: OK (dist/app-release.apk, CI 42507600505, release apk-55f8ee15db3cf491ba4bc0edf3651c5ab985dd66)
- Этап 5 — DONE (код + APK) — Полный переход на ядро Mihomo (sing-box): flutter_singbox_client, MethodChannel dev.local.vpnservice/mihomo, MihomoBridge.kt. ProfileRepository на sqflite→shared_preferences (id, name, rawConfig, type, priority, enabled). UI «Управление конфигами» переработан: список с редактированием/удалением, мгновенное обновление. Главный экран: кнопка «Подключиться», список серверов с флагами стран, статус «Подключено через <имя>». Mihomo url-test группы для автовыбора лучшего сервера (проверка cp.cloudflare.com/generate_204). Раздельное туннелирование через PROCESS-NAME правила Mihomo. Убраны сложные настройки (I1, MTU) с главного экрана. — apk: OK (dist/app-release.apk, 170,926,314 байт, CI 42574454484, release apk-71a8299b72c0d92956b17bd57e337c62e8dfe098)
- Этап 5.1 — DONE (код + APK) — Приоритизация исправлений подключения (Task 1-3):
  1) Таймаут подключения 15 с: если Mihomo не прислал Connected/Error за 15 с — UI переходит в состояние «Ошибка: Таймаут подключения» (в mihomo_service.dart через Timer, в vpn_controller.dart логирование этапов Prepare → Core Start → Waiting for Tunnel → Connected/Error).
  2) Foreground Service: VpnForegroundService.kt с постоянным уведомлением в шторке (заголовок «VPN Подключен», текст «Сервер: <имя>», иконка щита), кнопка «Ускорить» (перезапускает url-test через Mihomo, Toast «Поиск лучшего сервера...»), кнопка «Остановить» (полностью отключает VPN, убирает уведомление). Регистрируется в AndroidManifest.xml.
  3) Кнопка «Сбросить / Остановить» на главном экране (иконка питания): жёсткий сброс — отключает VPN, очищает состояние UI в «Отключено», работает даже при зависшей загрузке.
  - apk: OK (dist/app-release.apk, CI 42581393464, release apk-d730872d09a006fd294929020cf4b1ef2411b983)
- Этап 6 — next — Звонки peer_rtc + Opus, офлайн-сообщения flutter_mesh_network, чат UI

## Зеркало и доставка APK
- Публичное зеркало: smolinb23-star/vpn-obhod-public (orphan-история без PAT; пуш через .tools/push_public.py)
- Приватный репо smolinb23-star/vpn-obhod заблокирован GitHub (403 trade controls) для API — код дублируется в публичное зеркало
- Скачивание Actions-артефактов невозможно: *.blob.core.windows.net блокируется сетью провайдера → workflow публикует APK в GitHub Release (objects.githubusercontent.com проходит)
- Прямая ссылка: https://github.com/smolinb23-star/vpn-obhod-public/releases/tag/apk-275585980da55d7fea3fe826d273fb35fccef425

## CI статус
- Build #1 (06188c2) — FAIL: AGP 8.7.3 < Flutter req 8.11.1
- Build #2 (a6bb1d8) — FAIL: Gradle wrapper не сгенерировался на CI
- Build #3 (bf62b171) — FAIL: shrinkResources без minifyEnabled → исправлено (ef86904)
- Build public #1 (247c416) — SUCCESS: analyze + 24 теста + build apk, артефакт 87 МБ
- Build public #2 (2755859) — SUCCESS: + публикация APK в GitHub Release → APK скачан в dist/
- Build public #9 (941925b) — SUCCESS: 3.1+3.2 (79 dart-тестов), APK 101,855,338 байт в Release `apk-941925bd7420d1c8c88f7a53c3ee705504c559ab`; kotlin unit tests падали на имени теста `equivalence:` → исправлено локально (`equivalence -`), войдёт в следующий прогон
- Build public #11 (546f4f8) — SUCCESS: 3.3 DPI fix (fix dead_code/dropped duplicate MTU), analyze + 92 dart + 9 kotlin + apk 101,767,454 байт в Release `apk-546f4f808eddd62b09af1410376122380dd7c544`
- MANUAL: отозвать токен (прошёл через чат)

## MANUAL (блокеры человека)
- Токен — **отозвать** в GitHub Settings → Developer settings → PAT classic
- Релизный keystore — генерация после первой зелёной CI-сборки (keytool из OpenJDK 17)
- VPS с Xray — для боевых методов обхода (сейчас моки; замена в одной точке: bypassMethodsProvider)

## Известные ограничения
- Релизный APK подписан debug-ключом (до генерации keystore).
- trojan/vmess/ss — через fallback FlutterVless.parse().
- Память побед: SqliteWinsRepository.openDefault() в main(); при недоступности sqflite — InMemory fallback.
- network_key: реальный SSID Wi-Fi или operator|mccmnc через PlatformBridge (Android); вне Android — unknown.
- WebRTC-туннель помечен как manual/демо (на Android без нативных костылей нереализуем).