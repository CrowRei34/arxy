#!/usr/bin/env bash
# test-bridge-kill.sh — daemon asesinado:
# kill -9 al daemon deja pidfile+socket huerfanos; --status debe decir
# inactivo (no mentir) y el siguiente --daemon levantar sin "ya corre".
# Daemon y socket en TMP (el daemon real del usuario no se toca).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
SOCK="$D/k.sock"
trap '"$BIN" host-bridge --stop --socket "$SOCK" >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
cc -O2 -Wall -Wextra -Werror -o "$D/arxy-bridged" "$HERE/../bridge/arxy-bridged.c" 2>/dev/null || { echo "FAIL: no compila"; exit 1; }
export ARXY_BRIDGE_BIN="$D/arxy-bridged"

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: daemon arranca"
out="$("$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo 2>&1)" || { no "T1 arranca ($out)"; }
[[ -S "$SOCK" ]] && ok "T1 arranca" || no "T1 arranca ($out)"

echo "== T2: kill -9 y status dice inactivo"
pid="$(cat "${SOCK%.sock}.pid")"
kill -9 "$pid" 2>/dev/null
for _i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
out="$("$BIN" host-bridge --status --socket "$SOCK" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "inactivo" <<<"$out" && ok "T2 inactivo" || no "T2 inactivo (rc=$rc $out)"

echo "== T3: re-daemon levanta sin 'ya corre'"
out="$("$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q "ya corre" <<<"$out" && [[ -S "$SOCK" ]] && ok "T3 re-daemon" || no "T3 re-daemon (rc=$rc $out)"

echo "== T4: status activo de nuevo"
out="$("$BIN" host-bridge --status --socket "$SOCK" 2>&1)" && grep -q "^activo:" <<<"$out" && ok "T4 activo" || no "T4 activo ($out)"

echo "== T5: stop limpia"
"$BIN" host-bridge --stop --socket "$SOCK" >/dev/null 2>&1
[[ ! -e "$SOCK" ]] && [[ ! -e "${SOCK%.sock}.pid" ]] && ok "T5 limpia" || no "T5 limpia"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
