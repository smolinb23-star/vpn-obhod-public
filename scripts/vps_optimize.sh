#!/usr/bin/env bash
# Оптимизация Linux-VPS под VPN/Xray: BBR + TCP-тюнинг.
#
# Запуск (root):
#   sudo bash scripts/vps_optimize.sh
#
# После применения проверить:
#   sysctl net.ipv4.tcp_congestion_control   # должно быть bbr
#   sysctl net.core.default_qdisc            # должно быть fq
#
# Откат: удалить /etc/sysctl.d/99-vpn-optimize.conf и выполнить sysctl --system

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root: sudo bash $0" >&2
  exit 1
fi

CONF=/etc/sysctl.d/99-vpn-optimize.conf

cat > "$CONF" <<'EOF'
# BBR — алгоритм управления перегрузками (критично для мобильных сетей).
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP keepalive: быстрее обрываем мёртвые соединения после смены сети.
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Буферы: больше окно для высокоскоростных каналов.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP Fast Open для клиентских и серверных соединений.
net.ipv4.tcp_fastopen = 3

# MTU probing помогает при PPPoE/мобильных сетях с меньшим MTU.
net.ipv4.tcp_mtu_probing = 1
EOF

# Модуль BBR может быть не загружен — не считаем это фатальным.
modprobe tcp_bbr 2>/dev/null || true

sysctl --system >/dev/null

echo "Готово. Текущие значения:"
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control \
  net.ipv4.tcp_fastopen net.core.rmem_max net.core.wmem_max
