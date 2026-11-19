#!/usr/bin/env bash
# Testes do hosts-blacklist. Não precisam de root nem tocam no /etc/hosts real:
# tudo roda em diretórios temporários via HB_CONF_DIR / HB_STATE_DIR / HB_HOSTS_FILE.
#
# Uso: bash tests/run.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HB="$ROOT/bin/hosts-blacklist"
WATCH="$ROOT/bin/hosts-blacklist-watch"
unset JOURNAL_STREAM
export HB_TEST_ALLOW_FILE=1

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (esperado '$2', obtido '$3')"; fi; }

sha() { sha256sum <"$1" | cut -d' ' -f1; }
ino() { stat -c %i "$1"; }
cnt() { local n; n=$(grep -c -- "$2" "$1" 2>/dev/null) || true; echo "${n:-0}"; }

setup() {
  D=$(mktemp -d "$TMPROOT/case.XXXXXX")
  export HB_CONF_DIR="$D/conf" HB_STATE_DIR="$D/state" HB_HOSTS_FILE="$D/hosts" HB_LOCK_FILE="$D/lock"
  mkdir -p "$HB_CONF_DIR" "$HB_STATE_DIR"
  printf '%s\n' '127.0.0.1 localhost' '::1 localhost' '192.168.0.10 nas.home' >"$HB_HOSTS_FILE"
  : >"$HB_CONF_DIR/local.txt"
  RC=0
}
hb() { RC=0; "$HB" "$@" >"$D/out" 2>"$D/err" || RC=$?; }
add_local() { printf '%s\n' "$@" >>"$HB_CONF_DIR/local.txt"; }
gen() { local i; for ((i = 1; i <= $2; i++)); do echo "0.0.0.0 $1$i.test.example"; done; }
ORIGINAL=$(printf '%s\n' '127.0.0.1 localhost' '::1 localhost' '192.168.0.10 nas.home')

t_basic() {
  section "aplicação básica e normalização"
  setup
  add_local 'Ads.Example.com' 'tracker.example.net # comentário' 'ads.example.com' \
    '0.0.0.0 hosts.example.org' 'localhost' 'não é domínio!' 'bad_.-x' '8.8.8.8 real.example.com'
  hb apply
  eq "saída 0" 0 "$RC"
  check "marcador BEGIN" grep -qxF '# BEGIN hosts-blacklist' "$HB_HOSTS_FILE"
  check "marcador END" grep -qxF '# END hosts-blacklist' "$HB_HOSTS_FILE"
  eq "3 domínios únicos e válidos" 3 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"
  check "converte para minúsculas e deduplica" grep -qxF '0.0.0.0 ads.example.com' "$HB_HOSTS_FILE"
  check "aceita formato hosts" grep -qxF '0.0.0.0 hosts.example.org' "$HB_HOSTS_FILE"
  check_not "localhost nunca é bloqueado" grep -q '0.0.0.0 localhost' "$HB_HOSTS_FILE"
  check_not "linha com IP real é descartada" grep -q 'real.example.com' "$HB_HOSTS_FILE"
  eq "linhas originais preservadas" "$ORIGINAL" "$(head -n 3 "$HB_HOSTS_FILE")"
  check "hosts.orig criado" test -f "$HB_STATE_DIR/hosts.orig"
  check "merged.txt gravado" test -s "$HB_STATE_DIR/merged.txt"
}

t_idempotent() {
  section "idempotência e preservação de edições externas"
  setup
  add_local 'a.example.com' 'b.example.com'
  hb apply
  local h i
  h=$(sha "$HB_HOSTS_FILE"); i=$(ino "$HB_HOSTS_FILE")
  hb -v apply
  eq "segunda execução: saída 0" 0 "$RC"
  eq "segunda execução não reescreve (inode)" "$i" "$(ino "$HB_HOSTS_FILE")"
  eq "segunda execução não altera o conteúdo" "$h" "$(sha "$HB_HOSTS_FILE")"
  check "log informa 'nada a fazer'" grep -q 'nada a fazer' "$D/err"

  echo '10.0.0.1 servidor.local' >>"$HB_HOSTS_FILE"
  i=$(ino "$HB_HOSTS_FILE")
  hb apply
  eq "edição fora do bloco: não reescreve" "$i" "$(ino "$HB_HOSTS_FILE")"
  check "edição fora do bloco é mantida" grep -qxF '10.0.0.1 servidor.local' "$HB_HOSTS_FILE"
}

t_restore() {
  section "restauração após alterações manuais"
  setup
  add_local 'a.example.com' 'b.example.com'
  hb apply
  local good
  good=$(sed -n '/^# BEGIN/,/^# END/p' "$HB_HOSTS_FILE" | sha256sum | cut -d' ' -f1)

  sed -i '/hosts-blacklist/d;/^0\.0\.0\.0 /d' "$HB_HOSTS_FILE"
  check_not "bloco removido à mão" grep -q 'a.example.com' "$HB_HOSTS_FILE"
  hb apply
  eq "restaurado após remoção" 0 "$RC"
  check "entrada de volta" grep -qxF '0.0.0.0 a.example.com' "$HB_HOSTS_FILE"
  eq "linhas originais intactas" "$ORIGINAL" "$(head -n 3 "$HB_HOSTS_FILE")"

  sed -i 's/^0\.0\.0\.0 a\.example\.com/127.0.0.1 a.example.com/' "$HB_HOSTS_FILE"
  hb apply
  check "restaurado após edição dentro do bloco" grep -qxF '0.0.0.0 a.example.com' "$HB_HOSTS_FILE"
  check "log explica o motivo" grep -q 'diverge' "$D/err"

  : >"$HB_HOSTS_FILE"
  hb apply
  check "restaurado após esvaziarem o arquivo" grep -qxF '0.0.0.0 b.example.com' "$HB_HOSTS_FILE"
  eq "bloco restaurado é idêntico ao original" "$good" "$(sed -n '/^# BEGIN/,/^# END/p' "$HB_HOSTS_FILE" | sha256sum | cut -d' ' -f1)"
}

t_allowlist() {
  section "allowlist e hosts das fontes"
  setup
  add_local 'a.example.com' 'tracker.example.net' 'cdn.example.org' 'ads.listas.example'
  printf '%s\n' 'Tracker.Example.Net' >"$HB_CONF_DIR/allowlist.txt"
  printf '%s\n' 'minha https://ads.listas.example/hosts.txt' >"$HB_CONF_DIR/sources.txt"
  hb apply
  check_not "domínio da allowlist não é bloqueado" grep -q 'tracker.example.net' "$HB_HOSTS_FILE"
  check_not "host de uma fonte nunca é bloqueado" grep -q 'ads.listas.example' "$HB_HOSTS_FILE"
  check "demais domínios continuam" grep -qxF '0.0.0.0 cdn.example.org' "$HB_HOSTS_FILE"
}

t_dryrun() {
  section "dry-run e check"
  setup
  add_local 'a.example.com'
  local h
  h=$(sha "$HB_HOSTS_FILE")
  hb --dry-run apply
  eq "dry-run: saída 0" 0 "$RC"
  eq "dry-run não altera o hosts" "$h" "$(sha "$HB_HOSTS_FILE")"
  check "dry-run mostra o diff" grep -q '^+0.0.0.0 a.example.com' "$D/out"
  check_not "dry-run não grava estado" test -e "$HB_STATE_DIR/merged.txt"
  hb check
  eq "check: bloco ausente = 1" 1 "$RC"
  hb apply
  hb check
  eq "check: bloco íntegro = 0" 0 "$RC"
  sed -i 's/^0\.0\.0\.0 a\.example\.com/0.0.0.0 x.example.com/' "$HB_HOSTS_FILE"
  hb check
  eq "check: bloco adulterado = 1" 1 "$RC"
}

t_markers() {
  section "marcadores corrompidos"
  setup
  add_local 'a.example.com'
  echo '# BEGIN hosts-blacklist' >>"$HB_HOSTS_FILE"
  local h
  h=$(sha "$HB_HOSTS_FILE")
  hb apply
  eq "BEGIN órfão: recusa (saída 3)" 3 "$RC"
  eq "BEGIN órfão: arquivo intacto" "$h" "$(sha "$HB_HOSTS_FILE")"
  hb --force apply
  eq "--force: saída 0" 0 "$RC"
  eq "--force: um único BEGIN" 1 "$(cnt "$HB_HOSTS_FILE" '^# BEGIN hosts-blacklist$')"
  eq "--force: um único END" 1 "$(cnt "$HB_HOSTS_FILE" '^# END hosts-blacklist$')"

  setup
  add_local 'a.example.com'
  hb apply
  sed -n '/^# BEGIN/,/^# END/p' "$HB_HOSTS_FILE" >>"$HB_HOSTS_FILE"
  eq "blocos duplicados criados" 2 "$(cnt "$HB_HOSTS_FILE" '^# BEGIN hosts-blacklist$')"
  hb apply
  eq "duplicados reduzidos a um" 1 "$(cnt "$HB_HOSTS_FILE" '^# BEGIN hosts-blacklist$')"
  eq "linhas originais intactas" "$ORIGINAL" "$(head -n 3 "$HB_HOSTS_FILE")"

  setup
  add_local 'a.example.com'
  hb apply
  { sed -n '/^# BEGIN/,/^# END/p' "$HB_HOSTS_FILE"; echo '10.9.9.9 meu.servidor'; sed -n '/^# BEGIN/,/^# END/p' "$HB_HOSTS_FILE"; } >>"$HB_HOSTS_FILE"
  h=$(sha "$HB_HOSTS_FILE")
  hb apply
  eq "conteúdo do usuário entre blocos: recusa" 3 "$RC"
  eq "conteúdo do usuário preservado" "$h" "$(sha "$HB_HOSTS_FILE")"
}

t_empty() {
  section "trava contra lista vazia e remove"
  setup
  add_local 'a.example.com'
  hb apply
  : >"$HB_CONF_DIR/local.txt"
  local h
  h=$(sha "$HB_HOSTS_FILE")
  hb apply
  eq "lista vazia + bloco existente: recusa (6)" 6 "$RC"
  eq "hosts intacto" "$h" "$(sha "$HB_HOSTS_FILE")"
  hb remove
  eq "remove: saída 0" 0 "$RC"
  check_not "remove: bloco apagado" grep -q 'hosts-blacklist' "$HB_HOSTS_FILE"
  eq "remove: resto do arquivo preservado" "$ORIGINAL" "$(grep -v '^$' "$HB_HOSTS_FILE")"
  hb remove
  eq "remove sem bloco: saída 0" 0 "$RC"
  hb apply
  eq "lista vazia sem bloco: nada a fazer" 0 "$RC"
  check_not "lista vazia sem bloco: não escreve bloco" grep -q 'hosts-blacklist' "$HB_HOSTS_FILE"
}

t_format() {
  section "formato das entradas"
  setup
  printf 'HOSTS_PER_LINE=3\nBLOCK_IPV6=yes\n' >"$HB_CONF_DIR/config.conf"
  add_local 'a.example.com' 'b.example.com' 'c.example.com' 'd.example.com' 'e.example.com'
  hb apply
  eq "saída 0" 0 "$RC"
  check "três domínios por linha" grep -qxF '0.0.0.0 a.example.com b.example.com c.example.com' "$HB_HOSTS_FILE"
  check "linha IPv6 correspondente" grep -qxF ':: a.example.com b.example.com c.example.com' "$HB_HOSTS_FILE"
  check "resto na linha seguinte" grep -qxF '0.0.0.0 d.example.com e.example.com' "$HB_HOSTS_FILE"

  setup
  printf 'HOSTS_PER_LINE=12\n' >"$HB_CONF_DIR/config.conf"
  add_local 'a.example.com'
  hb apply
  eq "config inválida: saída 2" 2 "$RC"
}

t_files() {
  section "arquivos: sem newline final, symlink e permissões"
  setup
  add_local 'a.example.com'
  printf '127.0.0.1 localhost' >"$HB_HOSTS_FILE"
  hb apply
  eq "primeira linha intacta" '127.0.0.1 localhost' "$(head -n 1 "$HB_HOSTS_FILE")"
  check "bloco adicionado em linha própria" grep -qxF '# BEGIN hosts-blacklist' "$HB_HOSTS_FILE"

  setup
  add_local 'a.example.com'
  mv "$HB_HOSTS_FILE" "$D/real_hosts"
  ln -s "$D/real_hosts" "$HB_HOSTS_FILE"
  hb apply
  check "symlink continua symlink" test -L "$HB_HOSTS_FILE"
  check "conteúdo gravado no arquivo de destino" grep -qxF '0.0.0.0 a.example.com' "$D/real_hosts"

  setup
  add_local 'a.example.com'
  chmod 640 "$HB_HOSTS_FILE"
  hb apply
  eq "permissões preservadas" 640 "$(stat -c %a "$HB_HOSTS_FILE")"
  check_not "nenhum temporário sobrando" bash -c "ls -A '$D' | grep -q '^\\.hosts-blacklist\\.'"
}

t_update() {
  section "atualização de fontes"
  setup
  add_local 'keep.example.com'
  gen a 30 >"$D/src.txt"
  printf '%s\n' "lista1 file://$D/src.txt" >"$HB_CONF_DIR/sources.txt"
  hb update
  eq "update: saída 0" 0 "$RC"
  eq "cache com 30 domínios" 30 "$(wc -l <"$HB_STATE_DIR/cache/lista1.list")"
  eq "bloco com 31 entradas" 31 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"
  check "last-update gravado" test -s "$HB_STATE_DIR/last-update"

  gen a 12 >"$D/src.txt"
  hb update
  eq "lista que encolhe demais: saída 7" 7 "$RC"
  eq "cache anterior mantido" 30 "$(wc -l <"$HB_STATE_DIR/cache/lista1.list")"
  eq "hosts mantido" 31 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"

  gen a 5 >"$D/src.txt"
  hb update
  eq "lista pequena demais: saída 7" 7 "$RC"
  eq "cache mantido (pequena)" 30 "$(wc -l <"$HB_STATE_DIR/cache/lista1.list")"

  rm -f "$D/src.txt"
  hb update
  eq "fonte inacessível: saída 7" 7 "$RC"
  eq "cache mantido (inacessível)" 30 "$(wc -l <"$HB_STATE_DIR/cache/lista1.list")"
  eq "hosts mantido (inacessível)" 31 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"

  gen b 20 >"$D/src.txt"
  hb update
  eq "lista menor, mas aceitável: saída 0" 0 "$RC"
  eq "cache atualizado" 20 "$(wc -l <"$HB_STATE_DIR/cache/lista1.list")"
  eq "bloco com 21 entradas" 21 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"
  check "listas locais não foram alteradas" grep -qx 'keep.example.com' "$HB_CONF_DIR/local.txt"

  : >"$HB_CONF_DIR/sources.txt"
  hb update
  eq "fonte removida: saída 0" 0 "$RC"
  check_not "cache da fonte removida apagado" test -e "$HB_STATE_DIR/cache/lista1.list"
  eq "sobra só o domínio local" 1 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"

  printf '%s\n' 'x http://example.com/lista' >"$HB_CONF_DIR/sources.txt"
  hb update
  eq "http:// recusado por padrão: saída 7" 7 "$RC"
  check "aviso sobre http" grep -q 'http' "$D/err"

  gen z 15 >"$D/src2.txt"
  printf '%s\n' "file://$D/src2.txt" >"$HB_CONF_DIR/sources.txt"
  hb update
  eq "fonte sem nome recebe nome automático" 1 "$(ls "$HB_STATE_DIR"/cache | wc -l)"
}

t_status() {
  section "status"
  setup
  add_local 'a.example.com'
  hb apply
  hb status
  eq "status: saída 0" 0 "$RC"
  check "status mostra o estado" grep -q 'Estado do bloco  : ok' "$D/out"
  check "status mostra a contagem" grep -q 'Domínios         : 1' "$D/out"
}

t_concurrency() {
  section "execuções concorrentes"
  setup
  add_local 'a.example.com' 'b.example.com'
  local r1=0 r2=0 r3=0
  "$HB" apply 2>/dev/null & p1=$!
  "$HB" apply 2>/dev/null & p2=$!
  "$HB" apply 2>/dev/null & p3=$!
  wait $p1 || r1=$?
  wait $p2 || r2=$?
  wait $p3 || r3=$?
  eq "todas terminam com 0" "0 0 0" "$r1 $r2 $r3"
  eq "um único bloco" 1 "$(cnt "$HB_HOSTS_FILE" '^# BEGIN hosts-blacklist$')"
  eq "duas entradas" 2 "$(cnt "$HB_HOSTS_FILE" '^0\.0\.0\.0 ')"
}

t_watch() {
  section "watcher (com inotifywait simulado)"
  setup
  mkdir -p "$D/bin"
  cat >"$D/bin/inotifywait" <<'EOF'
#!/bin/sh
echo "$HB_HOSTS_FILE.outro"
echo "$HB_HOSTS_FILE"
sleep 0.3
echo "$HB_HOSTS_FILE"
sleep 0.3
echo "$HB_HOSTS_FILE"
sleep 2.5
echo "$HB_HOSTS_FILE"
sleep 0.5
EOF
  cat >"$D/trigger.sh" <<EOF
#!/bin/sh
echo run >>"$D/runs"
EOF
  chmod +x "$D/bin/inotifywait" "$D/trigger.sh"
  local rc=0
  PATH="$D/bin:$PATH" HB_WATCH_CMD="$D/trigger.sh" HB_WATCH_DEBOUNCE=1 HB_WATCH_INITIAL=0 \
    timeout 30 "$WATCH" >"$D/wout" 2>&1 || rc=$?
  eq "eventos em rajada viram 1 disparo + 1 evento isolado = 2" 2 "$(wc -l <"$D/runs" 2>/dev/null || echo 0)"
  eq "watcher sai com 1 quando o inotifywait termina" 1 "$rc"

  rm -f "$D/runs"
  rc=0
  PATH="$D/bin:$PATH" HB_WATCH_CMD="$D/trigger.sh" HB_WATCH_DEBOUNCE=1 HB_WATCH_INITIAL=1 \
    timeout 30 "$WATCH" >"$D/wout" 2>&1 || rc=$?
  eq "disparo inicial extra" 3 "$(wc -l <"$D/runs" 2>/dev/null || echo 0)"

  rm -f "$D/bin/inotifywait"
  rc=0
  PATH="/usr/bin:/bin" HB_WATCH_CMD="$D/trigger.sh" "$WATCH" >"$D/wout" 2>&1 || rc=$?
  if command -v inotifywait >/dev/null 2>&1; then
    pass "inotifywait real instalado (teste de ausência ignorado)"
  else
    eq "sem inotifywait: saída 78" 78 "$rc"
  fi
}

t_install() {
  section "instalador (DESTDIR)"
  setup
  local root="$D/root"
  DESTDIR="$root" bash "$ROOT/install.sh" >"$D/out" 2>&1
  eq "install: saída 0" 0 "$?"
  check "programa instalado" test -x "$root/usr/local/bin/hosts-blacklist"
  check "watcher instalado" test -x "$root/usr/local/bin/hosts-blacklist-watch"
  check "5 units instaladas" test "$(ls "$root/etc/systemd/system" | wc -l)" -eq 5
  check_not "placeholders substituídos" grep -rq '@BINDIR@' "$root/etc/systemd/system"
  check "ExecStart aponta para o prefixo" grep -q '^ExecStart=/usr/local/bin/hosts-blacklist apply' "$root/etc/systemd/system/hosts-blacklist.service"
  check "config criada" test -f "$root/etc/hosts-blacklist/config.conf"
  echo 'BACKUP=no' >>"$root/etc/hosts-blacklist/config.conf"
  DESTDIR="$root" bash "$ROOT/install.sh" >"$D/out" 2>&1
  check "reinstalar não sobrescreve configuração" grep -q '^BACKUP=no' "$root/etc/hosts-blacklist/config.conf"
}

t_static() {
  section "análise estática"
  local f
  for f in "$HB" "$WATCH" "$ROOT/install.sh" "$ROOT/uninstall.sh" "${BASH_SOURCE[0]}"; do
    check "bash -n $(basename "$f")" bash -n "$f"
  done
  if command -v shellcheck >/dev/null 2>&1; then
    for f in "$HB" "$WATCH" "$ROOT/install.sh" "$ROOT/uninstall.sh"; do
      check "shellcheck $(basename "$f")" shellcheck -x "$f"
    done
  else
    printf '  (shellcheck não instalado; pulando)\n'
  fi
  if command -v systemd-analyze >/dev/null 2>&1; then
    local d
    d=$(mktemp -d "$TMPROOT/units.XXXXXX")
    for f in "$ROOT"/systemd/*; do
      sed 's#@BINDIR@#/bin#g' "$f" >"$d/$(basename "$f")"
    done
    check "units sem erros de sintaxe" bash -c "systemd-analyze verify '$d'/*.service '$d'/*.timer 2>&1 | grep -iv 'not found\\|executable\\|failed to' | grep -qi 'unknown\\|invalid' && exit 1 || exit 0"
  fi
}

for t in t_basic t_idempotent t_restore t_allowlist t_dryrun t_markers t_empty t_format t_files t_update t_status t_concurrency t_watch t_install t_static; do
  "$t"
done

printf '\n%d ok, %d falhas\n' "$PASS" "$FAIL"
((FAIL == 0))
