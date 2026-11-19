#!/usr/bin/env bash
#
# Remove o hosts-blacklist.
#
# Uso: sudo ./uninstall.sh [--keep-block] [--purge]
#   --keep-block  não remove o bloco do /etc/hosts
#   --purge       apaga também /etc/hosts-blacklist e /var/lib/hosts-blacklist
# Variáveis: PREFIX (padrão /usr/local), SYSTEMD_DIR (padrão /etc/systemd/system)

set -Eeuo pipefail

PREFIX=${PREFIX:-/usr/local}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
KEEP_BLOCK=0
PURGE=0

for arg in "$@"; do
  case $arg in
    --keep-block) KEEP_BLOCK=1 ;;
    --purge) PURGE=1 ;;
    -h | --help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "opção desconhecida: $arg" >&2
      exit 1
      ;;
  esac
done

if ((EUID != 0)); then
  echo "execute como root (sudo ./uninstall.sh)" >&2
  exit 1
fi

# 1) Para o monitoramento ANTES de mexer no hosts, senão ele restauraria o bloco.
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now hosts-blacklist-watch.service hosts-blacklist.timer \
    hosts-blacklist-update.timer 2>/dev/null || true
  systemctl disable hosts-blacklist.service 2>/dev/null || true
  systemctl stop hosts-blacklist.service hosts-blacklist-update.service 2>/dev/null || true
fi

# 2) Remove o bloco do hosts.
if ((!KEEP_BLOCK)) && [[ -x $PREFIX/bin/hosts-blacklist ]]; then
  "$PREFIX/bin/hosts-blacklist" remove || echo "aviso: não foi possível remover o bloco automaticamente" >&2
fi

# 3) Remove arquivos.
rm -f -- "$PREFIX/bin/hosts-blacklist" "$PREFIX/bin/hosts-blacklist-watch"
rm -f -- "$SYSTEMD_DIR"/hosts-blacklist.service "$SYSTEMD_DIR"/hosts-blacklist.timer \
  "$SYSTEMD_DIR"/hosts-blacklist-update.service "$SYSTEMD_DIR"/hosts-blacklist-update.timer \
  "$SYSTEMD_DIR"/hosts-blacklist-watch.service
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

if ((PURGE)); then
  rm -rf -- /etc/hosts-blacklist /var/lib/hosts-blacklist
  echo "Configuração e estado apagados."
else
  echo "Configuração (/etc/hosts-blacklist) e estado (/var/lib/hosts-blacklist) mantidos; use --purge para apagar."
fi
echo "Desinstalado."
