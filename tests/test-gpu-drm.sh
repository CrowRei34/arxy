#!/usr/bin/env bash
# test-gpu-drm.sh — GPU detectada sin hardware, via ARXY_SYS_DRM_PATH.
# Uso: ./tests/test-gpu-drm.sh  (arxy en PATH; no necesita imagen)
set -uo pipefail
FAIL=0
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

fake() { # fake <vendor|-> : prepara un card0 con ese vendor (o sin cards)
    rm -rf "${D:?}"/*
    if [[ "${1:-}" != "-" ]]; then
        mkdir -p "$D/card0/device"
        printf '%s' "$1" > "$D/card0/device/vendor"
    fi
}

t() { # t <nombre> <vendor|-> <esperado>
    fake "$2"
    local got
    got="$(ARXY_SYS_DRM_PATH="$D" arxy version --verbose 2>/dev/null | sed -n 's/^gpu: //p')"
    if [[ "$got" == "$3"* ]]; then echo "PASS: $1";
    else echo "FAIL: $1 (quiero '$3*', tengo '$got')"; FAIL=$((FAIL+1)); fi
}

t "AMD 1002" "0x1002" "amd"
t "NVIDIA 10de" "0x10de" "nvidia"
t "Intel 8086 calla" "0x8086" "no discreta"
t "sin cards calla" "-" "no discreta"
# doctor usa el mismo detect_gpu (con imagen mini avisa de verdad).
# Ojo pipefail: doctor retorna 1 si falta algo (bwrap en containers), asi
# que se captura la salida (|| true) y decide el grep, no el rc.
fake "0x1002"
_doc="$(ARXY_SYS_DRM_PATH="$D" arxy doctor 2>&1 || true)"
if grep -q "aviso GPU AMD" <<<"$_doc"; then echo "PASS: doctor avisa con AMD";
else echo "FAIL: doctor avisa con AMD"; FAIL=$((FAIL+1)); fi

# --- Commit 9: heuristica NVIDIA pura, con mocks (sin root ni GPU real) ---
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/35-gpu.sh
. "$HERE/../lib/35-gpu.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-hw.sh
. "$HERE/../lib/60-hw.sh" >/dev/null 2>&1

g() { # g <nombre> <quiero> <tengo>
    if [[ "$3" == "$2" ]]; then echo "PASS: $1";
    else echo "FAIL: $1 (quiero '$2', tengo '$3')"; FAIL=$((FAIL+1)); fi
}

echo "== elf_class (file real + fallback)"
g "elf 64 real" "64" "$(elf_class /bin/true)"
g "elf texto vacio" "" "$(elf_class /etc/hostname 2>/dev/null || echo X)"
( file() { echo "foo ELF 32-bit LSB shared object"; } >/dev/null 2>&1
  : ) # subshell no puede tocar FAIL: capturar fuera
fm32="$(file() { echo "foo ELF 32-bit LSB shared object"; }; elf_class /x/libc.so)"
g "elf 32 mock" "32" "$fm32"
g "elf fallback lib32 sin file" "32" "$(PATH=/nonexistent elf_class /x/lib32/fake.so)"
g "elf fallback resto sin file" "" "$(PATH=/nonexistent elf_class /x/lib/fake.so)"

echo "== nvidia_libs (mocks probativos)"
E="$D/empty"; mkdir -p "$E/r" "$E/r64" "$E/r32"
out="$(ARXY_NVIDIA_LIB_ROOT="$E/r" ARXY_NVIDIA_LIB_ROOT64="$E/r64" ARXY_NVIDIA_LIB_ROOT32="$E/r32" nvidia_libs)"
g "libs vacio con mocks vacios" "" "$out"
M="$D/nv"; mkdir -p "$M/r64" "$M/r32"
cp /bin/true "$M/r64/libcuda.so.550.54.14"
ln -s libcuda.so.550.54.14 "$M/r64/libcuda.so.1"
cp /bin/true "$M/r64/libGLX_nvidia.so.0"
cp /bin/true "$M/r64/libGLESv2.so.0" # mesa: sin 'nvidia', no debe salir
cp /bin/true "$M/r32/libnvidia-glcore.so.550.54.14"
out="$(ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" nvidia_libs)"
[[ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]] && echo "PASS: libs 3 lineas (dedup link)" || { echo "FAIL: libs 3 lineas (tengo '$out')"; FAIL=$((FAIL+1)); }
grep -qE "^64[[:space:]]+.*libcuda" <<<"$out" && echo "PASS: libs libcuda 64" || { echo "FAIL: libs libcuda 64"; FAIL=$((FAIL+1)); }
grep -q "libGLESv2" <<<"$out" && { echo "FAIL: libs mesa excluida"; FAIL=$((FAIL+1)); } || echo "PASS: libs mesa excluida"
grep -q "libnvidia-glcore" <<<"$out" && echo "PASS: libs lib32 detectada" || { echo "FAIL: libs lib32"; FAIL=$((FAIL+1)); }
nvidia_libs >/dev/null 2>&1
[[ $? -eq 0 ]] && echo "PASS: libs sin mock no falla" || { echo "FAIL: libs sin mock rc"; FAIL=$((FAIL+1)); }

echo "== nvidia_icds + rewrite"
V="$D/icd"; mkdir -p "$V/vk" "$V/egl"
printf '{\n "file_format_version": "1.0.0",\n "ICD": { "library_path": "/usr/lib/libGLX_nvidia.so.0" }\n}\n' > "$V/vk/nvidia_icd.json"
printf '{ "ICD": { "library_path": "/usr/lib/libEGL_nvidia.so.0" } }\n' > "$V/egl/10_nvidia.json"
out="$(ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" nvidia_icds)"
[[ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ]] && echo "PASS: icds 2" || { echo "FAIL: icds 2 (tengo '$out')"; FAIL=$((FAIL+1)); }
grep -q "^vulkan" <<<"$out" && grep -q "^egl" <<<"$out" && echo "PASS: icds kinds" || { echo "FAIL: icds kinds"; FAIL=$((FAIL+1)); }
out="$(nvidia_icd_rewrite "$V/vk/nvidia_icd.json" /usr/lib/arxy-nvidia/lib64/libGLX_nvidia.so.0)"
grep -q '"/usr/lib/arxy-nvidia/lib64/libGLX_nvidia.so.0"' <<<"$out" && echo "PASS: rewrite cambia path" || { echo "FAIL: rewrite cambia path"; FAIL=$((FAIL+1)); }
grep -q '"/usr/lib/libGLX_nvidia.so.0"' <<<"$out" && { echo "FAIL: rewrite quita viejo"; FAIL=$((FAIL+1)); } || echo "PASS: rewrite quita viejo"
printf '{ "sin": "library" }\n' > "$V/vk/otro.json"
g "rewrite sin library passthrough" '{ "sin": "library" }' "$(nvidia_icd_rewrite "$V/vk/otro.json" /x/y)"

echo "== nvidia_guest_path"
g "guest 64" "/usr/lib/arxy-nvidia/lib64/libcuda.so.1" "$(nvidia_guest_path /usr/lib64/libcuda.so.1 64)"
g "guest 32" "/usr/lib/arxy-nvidia/lib32/libcuda.so.1" "$(nvidia_guest_path /usr/lib/libcuda.so.1 32)"
g "guest plugin xorg" "/usr/lib/arxy-nvidia/lib64/xorg/modules/drivers/nvidia_drv.so" "$(nvidia_guest_path /usr/lib/xorg/modules/drivers/nvidia_drv.so 64)"
g "guest sin clase vacio" "" "$(nvidia_guest_path /usr/lib/libcuda.so.1 "")"

echo "== nvidia_mounts (mock integral)"
MD="$D/nvdev"; mkdir -p "$MD"; touch "$MD/nvidia0"
out="$(ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" ARXY_DEV_PATH="$MD" nvidia_mounts)"
grep -q "libcuda.*arxy-nvidia" <<<"$out" && echo "PASS: mounts lib" || { echo "FAIL: mounts lib"; FAIL=$((FAIL+1)); }
grep -q "nvidia_icd.json.*/usr/share/vulkan/icd.d/nvidia_icd.json" <<<"$out" && echo "PASS: mounts icd" || { echo "FAIL: mounts icd"; FAIL=$((FAIL+1)); }
grep -q "nvidia0.*nvidia0" <<<"$out" && echo "PASS: mounts device identidad" || { echo "FAIL: mounts device"; FAIL=$((FAIL+1)); }
nvidia_mounts >/dev/null 2>&1
[[ $? -eq 0 ]] && echo "PASS: mounts sin mock no falla" || { echo "FAIL: mounts sin mock rc"; FAIL=$((FAIL+1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
