# PROGRESS

Формат: `Этап N — DONE/BLOCKED — подход — apk ok/fail — следующий шаг`

- Этап 0 — DONE — окружение: локальный Flutter/Android SDK недоступны → сборка через GitHub Actions — следующий шаг: Этап 1
- Этап 1 — DONE (код) — flutter_vless ^1.1.7, парсер vless/hy2/JSON/подписок, валидатор (запрет 0.0.0.0 и noauth), UI + проверка смены IP, CI GitHub Actions — apk: pending (CI) — следующий шаг: push → CI
- Этап 2 — DONE (код, моки) — BypassEngine: интерфейс BypassMethod, 7 моков (детерминированные по seed), BypassOrchestrator (параллельный probe с таймаутом 8с, ранжирование success→история→RTT→wins, проверка смены IP после connect, Degraded RTT>300/потери>2% гистерезис 3, Dead 3 фейла — мгновенно, dwell 5 мин), память побед (абстракция WinsRepository: SQLite + InMemory), экран «Обход» 🟢🟡🔴 + авто-выбор + ручной override — apk: pending (CI) — следующий шаг: тесты в CI
- Этап 3 — next — стабильность: Foreground Service, смена сети, LTE-форсирование, SSID/operator → network_key, SQLite-память вместо in-memory

## CI статус
- Build #1 (06188c2) — FAIL: AGP 8.7.3 < Flutter req 8.11.1
- Build #2 (a6bb1d8) — FAIL: Gradle wrapper не сгенерировался на CI
- Build #3 (bf62b171) — in_progress: AGP 8.11.1 + Gradle 8.13 + committed wrapper + .gitattributes LF
- MANUAL: отозвать токен (прошёл через чат)

## MANUAL (блокеры человека)
- Токен — **отозвать** в GitHub Settings → Developer settings → PAT classic
- Релизный keystore — генерация после первой зелёной CI-сборки (keytool из OpenJDK 17)
- VPS с Xray — для боевых методов обхода (сейчас моки; замена в одной точке: bypassMethodsProvider)

## Известные ограничения
- Релизный APK подписан debug-ключом (до генерации keystore).
- trojan/vmess/ss — через fallback FlutterVless.parse().
- Память побед в рантайме — InMemoryWinsRepository (sqflite требует Flutter-контекста); SQLite-реализация готова и подключается на Этапе 3.
- network_key демо = 'demo_network'; реальный SSID/operator — Этап 3.
- WebRTC-туннель помечен как manual/демо (на Android без нативных костылей нереализуем).
