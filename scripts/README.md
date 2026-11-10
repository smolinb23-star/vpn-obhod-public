# Оптимизация сервера (VPS) для VPN

Клиентская часть оптимизирована в приложении автоматически (`XrayTuning`):
TCP Fast Open, `tcpNoDelay`, XTLS Vision для VLESS Reality/TCP, быстрый DNS.

Серверная часть требует root-доступа к VPS и выполняется вручную:

```bash
sudo bash scripts/vps_optimize.sh
```

Скрипт включает:

- BBR (`net.ipv4.tcp_congestion_control = bbr`, `net.core.default_qdisc = fq`);
- увеличенные TCP-буферы (`rmem_max` / `wmem_max` = 16 МиБ);
- TCP keepalive (60 с);
- TCP Fast Open (`net.ipv4.tcp_fastopen = 3`);
- MTU probing.

Проверка:

```bash
sysctl net.ipv4.tcp_congestion_control   # bbr
sysctl net.core.default_qdisc            # fq
sysctl net.ipv4.tcp_fastopen             # 3
```

## Xray на сервере

Для VLESS Reality включите Vision на клиенте — приложение делает это
автоматически для `security=reality` + `network=tcp`, если `flow` не задан.
На сервере inbound должен разрешать `flow: xtls-rprx-vision`.

TCP Fast Open в Xray задаётся в inbound:

```json
"streamSettings": {
  "sockopt": { "tcpFastOpen": true, "tcpNoDelay": true }
}
```

## Ограничение

Доступа к VPS у агента нет, поэтому BBR и серверный Xray нужно применить
владельцу сервера. Без этого клиентские оптимизации работают, но потолок
скорости определяется сервером.
