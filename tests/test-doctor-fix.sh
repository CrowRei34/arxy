#!/usr/bin/env bash
# test-doctor-fix.sh — contrato --fix sin root (Commit 4): informa y propone,
# nunca aplica. Sin imagen (ARXY_ROOT falso): determinista en cualquier host.
# Uso: ./tests/test-doctor-fix.sh  (sin root)
#   ARXY_BIN=./src/arxy ./tests/test-doctor-fix.sh  (probar el repo)
set -uo pipefail
FAIL=0
BIN="${ARXY_BIN:-arxy}"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/noroot"   # sin imagen: todos los fixes penden de mocks

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "fix informa rc 0" -- sh -c '"$0" doctor --fix >/dev/null' "$BIN"
t "fix lista 4" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "fixes available: 4"' "$BIN"
t "fix hint sin aplicar" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "repite con --apply"' "$BIN"
t "fix --json rc == json" -- sh -c '"$0" doctor --fix --json >/dev/null 2>&1; a=$?; "$0" doctor --json >/dev/null 2>&1; test "$a" -eq "$?"' "$BIN"
t "fix --json fixes_available" -- sh -c '"$0" doctor --fix --json 2>/dev/null | grep -q "\"fixes_available\": \[\"hold-mesa\"\]"' "$BIN"
t "fix --json objetos phase" -- sh -c '"$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"nvidia-align\", \"applicable\": [a-z]*, \"destructive\": false, \"requires_root\": true"' "$BIN"
t "fix --apply --json avisa" -- sh -c '"$0" doctor --fix --apply --json 2>/dev/null >/dev/null; "$0" doctor --fix --apply --json 2>&1 >/dev/null | grep -q "lista fixes sin aplicarlos"' "$BIN"

# Mocks: nvidia presente (sin rootfs -> aplicable) y musl con dri (aplicable).
mkdir -p "$D/nv/proc/driver/nvidia" "$D/nvdev"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14\n' > "$D/nv/proc/driver/nvidia/version"
touch "$D/nvdev/nvidia0"
mkdir -p "$D/musllib" "$D/musllib64" "$D/muslidev/dri"
touch "$D/musllib/ld-musl-x86_64.so.1" "$D/muslidev/dri/card0"
t "nvidia-align aplicable con mock" -- sh -c 'ARXY_SYS_ROOT="'"$D"'/nv" ARXY_DEV_PATH="'"$D"'/nvdev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"nvidia-align\", \"applicable\": true, \"destructive\": false, \"requires_root\": true.*\"phase\": 4"' "$BIN"
t "musl-stack aplicable con mock" -- sh -c 'ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" ARXY_DEV_PATH="'"$D"'/muslidev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"musl-glibc-stack\", \"applicable\": true"' "$BIN"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: fix --apply sin root exige no-root (este shell es root)"
else
    t "fix --apply sin root falla claro" -- sh -c '! "$0" doctor --fix --apply 2>/dev/null; "$0" doctor --fix --apply 2>&1 | grep -q "necesita root"' "$BIN"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
