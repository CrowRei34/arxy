#!/usr/bin/env bash
# test-input-e2e.sh — input visible en el sandbox. Sin root+
# imagen: SKIP. Rootfs sin evtest: se instala (--needed, diminuto).
set -uo pipefail
FAIL=0
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: exige root"; exit 0; }
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
BIN="$ARXY_BIN"
R="${ARXY_ROOT:-/tmp/input-root}"
[[ "$R" == /var/lib/arxy/root ]] && { echo "SKIP: exige ARXY_ROOT aislado"; exit 0; }
# El rootfs aislado por defecto es desechable: limpiar siempre al salir
# (el guard de arriba garantiza que nunca es el real; con ARXY_ROOT
# propio no se toca nada).
[[ "$R" == /tmp/input-root ]] && trap 'rm -rf /tmp/input-root' EXIT INT TERM HUP
export ARXY_ROOT="$R"

t() { # t <nombre> <quiero> -- <cmd...>
    local name="$1" want="$2"; shift 3
    local out
    out="$("$@" 2>&1)" || true
    if grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want])"; printf '%s\n' "$out" | head -3 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "event nodes visibles" "event0" -- "$BIN" run sh -c 'ls /dev/input/ | grep event'
"$BIN" run sh -c 'command -v evtest' >/dev/null 2>&1 || "$BIN" install evtest >/dev/null 2>&1 || { echo "SKIP: sin evtest (ni red)"; exit 0; }
t "evtest presente" "evtest" -- "$BIN" run evtest --version

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
