#!/usr/bin/env bash
#
# Instala o hosts-blacklist.
#
# Uso: sudo ./install.sh [--no-enable]
# Variáveis: PREFIX (padrão /usr/local), DESTDIR (para empacotar/testar),
#            SYSTEMD_DIR (padrão /etc/systemd/system)

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
CONF_DIR=/etc/hosts-blacklist
STATE_DIR=/var/lib/hosts-blacklist
ENABLE=1

for arg in "$@"; do
  case $arg in
    --no-enable) ENABLE=0 ;;
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

if [[ -n $DESTDIR ]]; then
  ENABLE=0
elif ((EUID != 0)); then
  echo "execute como root (sudo ./install.sh)" >&2
  exit 1
fi

# Dependências
if ((BASH_VERSINFO[0] < 4)); then
  echo "erro: é preciso bash 4 ou mais novo" >&2
  exit 1
fi
for cmd in awk sed grep curl flock sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || echo "aviso: '$cmd' não encontrado; o programa precisa dele" >&2
done
command -v inotifywait >/dev/null 2>&1 ||
  echo "aviso: 'inotifywait' não encontrado; instale inotify-tools para usar o monitoramento" >&2

echo "Instalando programas em $DESTDIR$PREFIX/bin"
install -D -m 0755 bin/hosts-blacklist "$DESTDIR$PREFIX/bin/hosts-blacklist"
install -D -m 0755 bin/hosts-blacklist-watch "$DESTDIR$PREFIX/bin/hosts-blacklist-watch"

echo "Instalando units do systemd em $DESTDIR$SYSTEMD_DIR"
install -d -m 0755 "$DESTDIR$SYSTEMD_DIR"
for unit in systemd/*.service systemd/*.timer; do
  sed "s#@BINDIR@#$PREFIX/bin#g" "$unit" >"$DESTDIR$SYSTEMD_DIR/$(basename "$unit")"
  chmod 0644 "$DESTDIR$SYSTEMD_DIR/$(basename "$unit")"
done

echo "Configuração em $DESTDIR$CONF_DIR (arquivos existentes não são sobrescritos)"
install -d -m 0755 "$DESTDIR$CONF_DIR"
for f in config.conf sources.txt local.txt allowlist.txt; do
  if [[ -e $DESTDIR$CONF_DIR/$f ]]; then
    echo "  mantido: $f"
  else
    install -m 0644 "etc/$f" "$DESTDIR$CONF_DIR/$f"
    echo "  criado:  $f"
  fi
done

install -d -m 0755 "$DESTDIR$STATE_DIR/cache"

if ((ENABLE)); then
  systemctl daemon-reload
  systemctl enable hosts-blacklist.service >/dev/null
  systemctl enable --now hosts-blacklist.timer hosts-blacklist-update.timer >/dev/null
  if command -v inotifywait >/dev/null 2>&1; then
    systemctl enable --now hosts-blacklist-watch.service >/dev/null
  fi
  systemctl start hosts-blacklist.service || true
  echo
  echo "Pronto. Adicione domínios em $CONF_DIR/local.txt e/ou fontes em $CONF_DIR/sources.txt,"
  echo "depois rode:  sudo hosts-blacklist update   (ou: sudo hosts-blacklist apply)"
  echo "Estado:       hosts-blacklist status"
else
  echo
  echo "Instalado sem ativar os serviços."
fi
