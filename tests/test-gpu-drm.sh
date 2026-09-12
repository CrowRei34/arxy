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

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
