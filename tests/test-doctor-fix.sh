#!/usr/bin/env bash
# test-doctor-fix.sh — contrato --fix sin root (Commit 4): informa y propone,
# nunca aplica. Sin imagen (ARXY_ROOT falso): determinista en cualquier host.
# Uso: ./tests/test-doctor-fix.sh  (repo por defecto, sin root)
#   ARXY_BIN=/ruta/a/arxy ./tests/test-doctor-fix.sh  (otro binario)
set -uo pipefail
FAIL=0
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/noroot"   # sin imagen: todos los fixes penden de mocks

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "fix informa rc 0 + contenido" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "fixes available:"' "$BIN"
t "fix lista 5" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "fixes available: 5"' "$BIN"
t "fix lista staging-cleanup" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "staging-cleanup"' "$BIN"
t "fix hint sin aplicar" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "repite con --apply"' "$BIN"
t "fix --json rc == json" -- sh -c '"$0" doctor --fix --json >/dev/null 2>&1; a=$?; "$0" doctor --json >/dev/null 2>&1; test "$a" -eq "$?"' "$BIN"
# Mock glibc aislado del host (Void musl + /dev/dri haría aplicable
# musl-glibc-stack y el array dejaría de ser ["hold-mesa"]): dir con
# ld-linux y sin ld-musl fuerza detect_libc=glibc; DEV/SYS vacíos ocultan
# dri/nvidia del host. Si hold-mesa desaparece, el grep sigue fallando.
mkdir -p "$D/glibclib" "$D/glibclib64" "$D/emptydev" "$D/emptyroot"
touch "$D/glibclib64/ld-linux-x86-64.so.2"
# R5-H8: sin rootfs no hay fixes disponibles (hold-mesa y musl son skip,
# no ok/todo). Con mocks glibc + dev vacio, todo es skip -> [].
t "fix --json fixes_available vacio sin rootfs" -- sh -c 'ARXY_LIB_DIR="'"$D"'/glibclib" ARXY_LIB64_DIR="'"$D"'/glibclib64" ARXY_DEV_PATH="'"$D"'/emptydev" ARXY_SYS_ROOT="'"$D"'/emptyroot" ARXY_SYS_DRM_PATH="'"$D"'/emptyroot/drm" "$0" doctor --fix --json 2>/dev/null | grep -q "\"fixes_available\": \[\]"' "$BIN"
t "fix --json objetos phase" -- sh -c '"$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"nvidia-align\", \"applicable\": [a-z]*, \"destructive\": false, \"requires_root\": true"' "$BIN"
t "fix --json staging-cleanup phase null" -- sh -c '"$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"staging-cleanup\", \"applicable\": false.*\"phase\": null"' "$BIN"
t "fix --apply --json avisa" -- sh -c '"$0" doctor --fix --apply --json 2>/dev/null >/dev/null; "$0" doctor --fix --apply --json 2>&1 >/dev/null | grep -q "lista fixes sin aplicarlos"' "$BIN"
# R5-H3: sin imagen, doctor sugiere siguiente paso (la via xbps no muestra
# el eco de install.sh).
t "doctor sin imagen sugiere setup" -- sh -c '"$0" doctor 2>&1 | grep -q "siguiente: .* setup"' "$BIN"

# Mocks: nvidia presente (sin rootfs -> aplicable) y musl con dri (aplicable
# solo con rootfs: R5-H8 marca skip sin rootfs verificado).
mkdir -p "$D/nv/proc/driver/nvidia" "$D/nvdev"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14\n' > "$D/nv/proc/driver/nvidia/version"
touch "$D/nvdev/nvidia0"
mkdir -p "$D/musllib" "$D/musllib64" "$D/muslidev/dri"
touch "$D/musllib/ld-musl-x86_64.so.1" "$D/muslidev/dri/card0"
# Fake rootfs minimo para image_ok (R5-H8: musl exige rootfs verificado).
mkdir -p "$D/fakeroot/usr/bin" "$D/fakeroot/etc"
touch "$D/fakeroot/usr/bin/bash" "$D/fakeroot/usr/bin/pacman" "$D/fakeroot/etc/arch-release"
chmod +x "$D/fakeroot/usr/bin/bash" "$D/fakeroot/usr/bin/pacman"
t "nvidia-align aplicable con mock" -- sh -c 'ARXY_SYS_ROOT="'"$D"'/nv" ARXY_DEV_PATH="'"$D"'/nvdev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"nvidia-align\", \"applicable\": false, \"destructive\": false, \"requires_root\": true.*\"phase\": 4"' "$BIN"
t "nvidia-align info texto" -- sh -c 'ARXY_SYS_ROOT="'"$D"'/nv" ARXY_DEV_PATH="'"$D"'/nvdev" "$0" doctor --fix 2>/dev/null | grep -q "\[info\].*nvidia-align"' "$BIN"
t "musl-stack aplicable con mock+rootfs" -- sh -c 'ARXY_ROOT="'"$D"'/fakeroot" ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" ARXY_DEV_PATH="'"$D"'/muslidev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"musl-glibc-stack\", \"applicable\": true"' "$BIN"
t "musl-stack skip sin rootfs" -- sh -c 'ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" ARXY_DEV_PATH="'"$D"'/muslidev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"musl-glibc-stack\", \"applicable\": false"' "$BIN"
mkdir -p "$D/nvonlydev"
touch "$D/nvonlydev/nvidia0"
t "nvidia nodos-sin-version skip preciso" -- sh -c 'ARXY_SYS_ROOT="'"$D"'/empty" ARXY_DEV_PATH="'"$D"'/nvonlydev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"id\": \"nvidia-align\", \"applicable\": false" && ARXY_SYS_ROOT="'"$D"'/empty" ARXY_DEV_PATH="'"$D"'/nvonlydev" "$0" doctor --fix --json 2>/dev/null | grep -q "\"reason\": \"nodos nvidia"' "$BIN"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: fix --apply sin root exige no-root (este shell es root)"
else
    t "fix --apply sin root falla claro" -- sh -c '! "$0" doctor --fix --apply 2>/dev/null; "$0" doctor --fix --apply 2>&1 | grep -q "necesita root"' "$BIN"
fi
# musl-glibc-stack: would_do preciso por vendor (usa gpu_stack_pkgs).
mkdir -p "$D/drmA/card0/device"
printf '0x1002' > "$D/drmA/card0/device/vendor"
t "musl would_do intel por defecto" -- sh -c 'ARXY_ROOT="'"$D"'/fakeroot" ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" ARXY_DEV_PATH="'"$D"'/muslidev" "$0" doctor --fix --json 2>/dev/null | grep -q "musl-glibc-stack.*vulkan-intel lib32-vulkan-intel"' "$BIN"
t "musl would_do amd con drm" -- sh -c 'ARXY_ROOT="'"$D"'/fakeroot" ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" ARXY_DEV_PATH="'"$D"'/muslidev" ARXY_SYS_DRM_PATH="'"$D"'/drmA" "$0" doctor --fix --json 2>/dev/null | grep -q "musl-glibc-stack.*vulkan-radeon lib32-vulkan-radeon"' "$BIN"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
