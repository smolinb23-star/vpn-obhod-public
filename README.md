# VPN Obhod — мультиобход белых списков

Flutter + `flutter_vless` (Xray). Сборка APK — через GitHub Actions (локальный
Flutter/Android SDK не требуются).

## Как запустить сборку (git-команды)

Выполнять из папки проекта `D:\впн сервис` (нужен установленный `git` и
аккаунт на GitHub):

```bat
git init
git add .
git commit -m "Этап 1: VPN-ядро, парсер, валидатор, CI"

:: Создай пустой репозиторий на https://github.com/new (имя, например, vpn-obhod)
git remote add origin https://github.com/<твой-логин>/vpn-obhod.git
git branch -M main
git push -u origin main
```

После push сборка стартует автоматически. Готовые APK — на странице
репозитория: **Actions → Android APK Build → Summary → artifact
`app-release-apks`** (универсальный `app-release.apk` и по-ABI варианты).

Ручной перезапуск: **Actions → Run workflow**.

## Установка на устройство

Скачай `app-release.apk` (универсальный) → перенеси на телефон → разреши
установку из неизвестных источников → установи.

## Проверка работы

1. Вставь `vless://…`-ссылку (или Xray JSON / подписку) в поле на экране.
2. Нажми «Подключиться».
3. Индикатор должен стать зелёным, а внешний IP — измениться
   (приложение само показывает IP до/после).

## Структура

- `lib/core` — модели, парсер профилей, валидатор безопасности
- `lib/features/vpn` — сервис туннеля (flutter_vless) + UI
- `lib/features/bypass` — Этап 2: BypassEngine + авто-переключение
- `test/` — юнит-тесты парсера и валидатора (гоняются в CI)
- `PROGRESS.md`, `STATE.json` — состояние спринта и fallback-выборы

## Статус

См. `PROGRESS.md`. Текущий этап и MANUAL-задачи — в `STATE.json`.
