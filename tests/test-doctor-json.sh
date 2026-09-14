#!/usr/bin/env bash
# test-doctor-json.sh — red mínima para doctor --json (Fase 2).
# Hoy: asserts verdes sobre `version --verbose` y `doctor` en texto
# (campos que --json deberá exponer), con mocks via ARXY_SYS_DRM_PATH.
# La sección --json queda en SKIP honesto hasta que el flag exista.
# Uso: ./tests/test-doctor-json.sh  (no necesita imagen ni root)
#   ARXY_BIN=./src/arxy ./tests/test-doctor-json.sh  (probar el repo)
# NOTA (P2): el nombre adelanta el contrato de Fase 2 (doctor --json); hoy
# cubre esos mismos campos en texto (nivel/gpu/rootfs/hold) + SKIP honesto.
set -uo pipefail
FAIL=0
BIN="${ARXY_BIN:-arxy}"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

fake() { # fake <vendor|-> : prepara un card0 con ese vendor (o sin cards)
    rm -rf "${D:?}"/*
    if [[ "${1:-}" != "-" ]]; then
        mkdir -p "$D/card0/device"
        printf '%s' "$1" > "$D/card0/device/vendor"
    fi
}

v() { # v <nombre> <vendor|-> <grep-E>
    fake "$2"
    local out
    out="$(ARXY_SYS_DRM_PATH="$D" "$BIN" version --verbose 2>/dev/null || true)"
    if grep -Eq "$3" <<<"$out"; then echo "PASS: $1";
    else echo "FAIL: $1 (patrón '$3')"; FAIL=$((FAIL+1)); fi
}

# Campos que --json deberá exponer: si cambian en texto, el contrato cambia.
v "verbose trae nivel" "-" "^nivel: [12] \(1=bwrap, 2=sin namespaces\)$"
v "verbose gpu amd" "0x1002" "^gpu: amd$"
v "verbose gpu nvidia" "0x10de" "^gpu: nvidia$"
v "verbose gpu intel calla" "0x8086" "^gpu: no discreta"
v "verbose trae rootfs" "-" "^rootfs: .* en .+"
v "verbose trae hold" "-" "^hold mesa-mini: (activo|ausente)$"

_doc="$("$BIN" doctor 2>&1 || true)"
if grep -q "nivel [12]" <<<"$_doc" && grep -Eq "\[OK\]|\[FALTA\]" <<<"$_doc"; then
    echo "PASS: doctor informa nivel y checks"
else
    echo "FAIL: doctor informa nivel y checks"; FAIL=$((FAIL+1))
fi

# --json (Fase 2): hoy el flag no existe (doctor ignora el arg y habla
# texto). Si algún día sale JSON con level+gpu, se aserta; si no, SKIP.
_json="$("$BIN" doctor --json 2>/dev/null || true)"
if command -v python3 >/dev/null 2>&1 \
    && printf '%s' "$_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "level" in d and "gpu" in d' 2>/dev/null; then
    echo "PASS: doctor --json trae level+gpu"
else
    echo "SKIP: doctor --json (pendiente Fase 2)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
