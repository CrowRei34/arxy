#!/usr/bin/env bash
# test-audio-e2e.sh — audio visible en el sandbox (Commit 18). Silencioso:
# solo lista e inspecciona, nunca emite sonido. Sin root+imagen: SKIP.
# Rootfs sin alsa-utils: se instala (--needed, rapido) en root aislado.
set -uo pipefail
FAIL=0
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: exige root"; exit 0; }
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
BIN="$ARXY_BIN"
R="${ARXY_ROOT:-/tmp/audio-root}"
[[ "$R" == /var/lib/arxy/root ]] && { echo "SKIP: exige ARXY_ROOT aislado"; exit 0; }
# El rootfs aislado por defecto es desechable: limpiar siempre al salir
# (el guard de arriba garantiza que nunca es el real; con ARXY_ROOT
# propio no se toca nada).
[[ "$R" == /tmp/audio-root ]] && trap 'rm -rf /tmp/audio-root' EXIT INT TERM HUP
export ARXY_ROOT="$R"

t() { # t <nombre> <quiero> -- <cmd...>
    local name="$1" want="$2"; shift 3
    local out
    out="$("$@" 2>&1)" || true
    if grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want])"; printf '%s\n' "$out" | head -3 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

"$BIN" run sh -c 'command -v aplay' >/dev/null 2>&1 || "$BIN" install alsa-utils >/dev/null 2>&1 || { echo "SKIP: sin alsa-utils (ni red)"; exit 0; }
t "aplay lista tarjetas" "card" -- "$BIN" run aplay -l
t "controlC0 visible" "controlC0" -- "$BIN" run sh -c 'ls /dev/snd/ | grep control'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
