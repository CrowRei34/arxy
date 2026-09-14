#!/usr/bin/env bash
# test-host-bridge.sh — CLI de `arxy host-bridge` sin root ni imagen:
# mecanica --daemon/--stop/--status (el protocolo vive en test-bridge.sh
# y el e2e en test-bridge-in-container.sh). Daemon y socket en TMP.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
SOCK="$D/br.sock"
trap '"$BIN" host-bridge --stop --socket "$SOCK" >/dev/null 2>&1 || true; "$BIN" host-bridge --stop --socket "$D/otro.sock" >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
cc -O2 -Wall -Wextra -Werror -o "$D/arxy-bridged" "$HERE/../bridge/arxy-bridged.c" 2>/dev/null || { echo "FAIL: no compila"; exit 1; }
export ARXY_BRIDGE_BIN="$D/arxy-bridged"
SOCK="$D/br.sock"

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -4 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}
te() { # te <nombre> <grep> -- <cmd...> : debe FALLAR y el texto matchear
    local name="$1" want="$2"; shift 2; shift
    local out
    if out="$("$@" 2>&1)"; then echo "FAIL: $name (rc 0)"; FAIL=$((FAIL+1));
    elif grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want] en [$out])"; FAIL=$((FAIL+1)); fi
}

t "help" -- "$BIN" host-bridge --help
te "status sin daemon" "inactivo" -- "$BIN" host-bridge --status --socket "$SOCK"
# (sin allowlist: el default resuelve en este host; el caso vacio
# determinista vive en T19 con ARXY_BRIDGE_ALLOWLIST imposible)
te "stop sin daemon" "sin daemon vivo" -- "$BIN" host-bridge --stop --socket "$SOCK"
t "daemon arranca" -- "$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo
[[ -S "$SOCK" ]] && echo "PASS: socket existe" || { echo "FAIL: socket existe"; FAIL=$((FAIL+1)); }
[[ -f "${SOCK%.sock}.pid" ]] && echo "PASS: pidfile existe" || { echo "FAIL: pidfile existe"; FAIL=$((FAIL+1)); }
t "status con daemon" -- "$BIN" host-bridge --status --socket "$SOCK"
te "doble daemon falla limpio" "ya corre" -- "$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo
t "stop" -- "$BIN" host-bridge --stop --socket "$SOCK"
[[ ! -e "$SOCK" ]] && echo "PASS: socket borrado" || { echo "FAIL: socket borrado"; FAIL=$((FAIL+1)); }
[[ ! -e "${SOCK%.sock}.pid" ]] && echo "PASS: pidfile borrado" || { echo "FAIL: pidfile borrado"; FAIL=$((FAIL+1)); }
te "status tras stop" "inactivo" -- "$BIN" host-bridge --status --socket "$SOCK"
t "socket custom" -- "$BIN" host-bridge --daemon --socket "$D/otro.sock" --allowed-cmd /bin/echo
t "stop custom" -- "$BIN" host-bridge --stop --socket "$D/otro.sock"

echo "== allowlist por nombre y defaults =="
t "T16 bare name resuelve via PATH" -- "$BIN" host-bridge --daemon --socket "$D/n.sock" --allowed-cmd echo
t "T16 stop" -- "$BIN" host-bridge --stop --socket "$D/n.sock"
te "T17 explicito malo muere claro" "not executable" -- "$BIN" host-bridge --daemon --socket "$D/m.sock" --allowed-cmd nonexistent-binary-xyz
te "T18 allowed-cmd vacio" "falta binario" -- "$BIN" host-bridge --daemon --socket "$D/m.sock" --allowed-cmd ""
t "T19 config lista" -- env ARXY_BRIDGE_ALLOWLIST="echo" "$BIN" host-bridge --daemon --socket "$D/c.sock"
t "T19 stop" -- "$BIN" host-bridge --stop --socket "$D/c.sock"
te "T19 nada resuelve" "allowlist vacia" -- env ARXY_BRIDGE_ALLOWLIST="nonexistent-xyz" "$BIN" host-bridge --daemon --socket "$D/c.sock"
echo "== T20: pid reutilizado no miente =="
"$BIN" host-bridge --daemon --socket "$D/p.sock" --allowed-cmd /bin/echo >/dev/null 2>&1
echo "$$" > "${D}/p.pid"
te "T20 status con pid ajeno" "inactivo" -- "$BIN" host-bridge --status --socket "$D/p.sock"
# Limpieza del daemon huerfano (pidfile pisado): por nombre exacto, nunca -f
for _p in $(pgrep -x arxy-bridged 2>/dev/null || true); do kill "$_p" 2>/dev/null || true; done
rm -f "$D/p.sock" "$D/p.pid"
echo "PASS: T20 limpieza"

echo "== P4: sin flock no hay auto-arranque pero tampoco crash =="
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/80-bridge.sh
. "$HERE/../lib/80-bridge.sh" >/dev/null 2>&1
export XDG_RUNTIME_DIR="$D" ARXY_BRIDGE_BIN="$D/arxy-bridged"
flock() { return 1; }
if ensure_bridge_daemon; then echo "PASS: sin flock rc 0"; else echo "FAIL: sin flock rc"; FAIL=$((FAIL+1)); fi
[[ ! -S "$D/arxy-bridge.sock" ]] && echo "PASS: sin flock no arranca" || { echo "FAIL: sin flock arranco"; FAIL=$((FAIL+1)); }
unset -f flock

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
