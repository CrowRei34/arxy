#!/usr/bin/env bash
# test-detect.sh — unitarias de detect_libc/nvidia_ver/kmods/dev_nodes.
# Sourcea lib/ (solo definiciones + config de solo-lectura): sin root,
# sin imagen. Funciones exportadas (-f) para los subshells; mocks via
# ARXY_SYS_ROOT/ARXY_DEV_PATH/ARXY_LIB_DIR (patrón ARXY_SYS_DRM_PATH).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-hw.sh
. "$HERE/../lib/60-hw.sh" >/dev/null 2>&1
export -f detect_libc detect_nvidia_ver detect_kmods detect_dev_nodes
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

t() { # t <nombre> <esperado> -- <bash -c ...>
    local name="$1" want="$2"; shift 2; shift
    local got
    got="$("$@" 2>/dev/null || true)"
    if [[ "$got" == "$want" ]]; then echo "PASS: $name";
    else echo "FAIL: $name (quiero '$want', tengo '$got')"; FAIL=$((FAIL+1)); fi
}

# --- libc: el host dice la verdad; los mocks fuerzan cada rama
t "libc host válida" "ok" -- bash -c 'case "$(detect_libc)" in glibc|musl|unknown) echo ok;; *) echo MAL;; esac'
mkdir -p "$D/lib" && touch "$D/lib/ld-musl-x86_64.so.1"
t "libc mock musl" "musl" -- bash -c 'ARXY_LIB_DIR="'"$D"'/lib" detect_libc'
mkdir -p "$D/empty"
t "libc mock unknown" "unknown" -- bash -c 'PATH=/nonexistent ARXY_LIB_DIR="'"$D"'/empty" ARXY_LIB64_DIR="'"$D"'/empty" detect_libc'

# --- nvidia: /proc y /sys, formato real del driver
mkdir -p "$D/nv1/proc/driver/nvidia" "$D/nv2/sys/module/nvidia"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14  ...\n' > "$D/nv1/proc/driver/nvidia/version"
printf '550.54.14\n' > "$D/nv2/sys/module/nvidia/version"
t "nvidia desde proc" "550.54.14" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv1" detect_nvidia_ver'
t "nvidia desde sys" "550.54.14" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv2" detect_nvidia_ver'
t "nvidia ausente vacía" "" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/empty" detect_nvidia_ver || true'
r="$(ARXY_SYS_ROOT="$D/empty" detect_nvidia_ver 2>/dev/null; echo "rc=$?")"
if [[ "$r" == "rc=1" ]]; then echo "PASS: nvidia ausente rc=1";
else echo "FAIL: nvidia ausente rc=1 (tengo '$r')"; FAIL=$((FAIL+1)); fi

# --- kmods y dev nodes
mkdir -p "$D/k1/sys/module/fuse" "$D/k1/proc/sys/vm" "$D/k1dev"
touch "$D/k1/proc/sys/vm/unprivileged_userfaultfd"
t "kmods fuse+userfaultfd" "fuse userfaultfd" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/k1" ARXY_DEV_PATH="'"$D"'/k1dev" detect_kmods'
t "kmods vacío" "" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/empty" ARXY_DEV_PATH="'"$D"'/empty" detect_kmods'
mkdir -p "$D/dev/dri"
touch "$D/dev/dri/card0" "$D/dev/dri/renderD128" "$D/dev/nvidia0" "$D/dev/fuse"
t "dev nodes" "$D/dev/dri/card0
$D/dev/dri/renderD128
$D/dev/nvidia0
$D/dev/fuse" -- bash -c 'ARXY_DEV_PATH="'"$D"'/dev" detect_dev_nodes'
t "dev vacío" "" -- bash -c 'ARXY_DEV_PATH="'"$D"'/empty" detect_dev_nodes'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
