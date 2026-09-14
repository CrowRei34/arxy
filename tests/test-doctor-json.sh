#!/usr/bin/env bash
# test-doctor-json.sh — contrato público doctor --json (format 1).
# Asserts grep (valen sin jq/python) + parseo estricto con python3 si está.
# Mocks via ARXY_SYS_ROOT/ARXY_DEV_PATH (la rama musl vive en test-detect.sh).
# Uso: ./tests/test-doctor-json.sh  (repo por defecto; no necesita imagen ni root)
#   ARXY_BIN=/ruta/a/arxy ./tests/test-doctor-json.sh  (otro binario)
set -uo pipefail
FAIL=0
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

fake() { # fake <vendor|-> : prepara un card0 con ese vendor (o sin cards)
    rm -rf "${D:?}"/*
    if [[ "${1:-}" != "-" ]]; then
        mkdir -p "$D/card0/device"
        printf '%s' "$1" > "$D/card0/device/vendor"
    fi
}

v() { # v <nombre> <vendor|-> <grep-E> : pin del contrato en texto
    fake "$2"
    local out
    out="$(ARXY_SYS_DRM_PATH="$D" "$BIN" version --verbose 2>/dev/null || true)"
    if grep -Eq "$3" <<<"$out"; then echo "PASS: $1";
    else echo "FAIL: $1 (patrón '$3')"; FAIL=$((FAIL+1)); fi
}

v "verbose trae nivel" "-" "^nivel: [12] \(1=bwrap, 2=sin namespaces\)$"
v "verbose gpu amd" "0x1002" "^gpu: amd$"
v "verbose gpu nvidia" "0x10de" "^gpu: nvidia$"
v "verbose gpu intel calla" "0x8086" "^gpu: no discreta"
v "verbose trae rootfs" "-" "^rootfs: .* en .+"
v "verbose trae hold" "-" "^hold mesa-mini: (activo|ausente)$"

_doc="$("$BIN" doctor 2>&1 || true)"
_trc=0; "$BIN" doctor >/dev/null 2>&1 || _trc=$?
if grep -q "nivel [12]" <<<"$_doc" && grep -Eq "\[OK\]|\[FALTA\]" <<<"$_doc"; then
    echo "PASS: doctor informa nivel y checks"
else
    echo "FAIL: doctor informa nivel y checks"; FAIL=$((FAIL+1))
fi

# --- --json: un solo documento, claves fijas, exit igual que texto
_json="$("$BIN" doctor --json 2>/dev/null)"; _jrc=$?
if [[ "$_jrc" == "$_trc" ]]; then echo "PASS: json exit == texto ($_jrc)";
else echo "FAIL: json exit ($_jrc) != texto ($_trc)"; FAIL=$((FAIL+1)); fi
if grep -q '"format": 1' <<<"$_json"; then echo "PASS: json format 1";
else echo "FAIL: json format 1"; FAIL=$((FAIL+1)); fi
for _k in level libc kernel userns overlayfs_rootless mount_setattr seccomp \
          mount_setattr_method seccomp_method \
          landlock gpu nvidia kmods dev rootfs fixes_available fixes_applied fixes; do
    if grep -q "\"$_k\":" <<<"$_json"; then echo "PASS: json key $_k";
    else echo "FAIL: json key $_k"; FAIL=$((FAIL+1)); fi
done
if grep -Eq '"kind": "(glibc|musl|unknown)"' <<<"$_json"; then echo "PASS: json libc.kind válido";
else echo "FAIL: json libc.kind válido"; FAIL=$((FAIL+1)); fi
if grep -Eq '"level": [12]' <<<"$_json"; then echo "PASS: json level válido";
else echo "FAIL: json level válido"; FAIL=$((FAIL+1)); fi
_j2="$("$BIN" doctor --json 2>/dev/null || true)"
if [[ "$_json" == "$_j2" ]]; then echo "PASS: json determinista";
else echo "FAIL: json determinista"; FAIL=$((FAIL+1)); fi
_err="$("$BIN" doctor --json 2>&1 >/dev/null || true)"
if [[ -z "$_err" ]]; then echo "PASS: json stderr limpio";
else echo "FAIL: json stderr limpio (tengo '$_err')"; FAIL=$((FAIL+1)); fi

# --- mocks: sysroot/dev vacíos → kmods/dev vacíos (prueba la redirección:
# el host SÍ tiene fuse y dri, así que "" solo sale del mock)
_json_empty="$(ARXY_SYS_ROOT="$D/empty" ARXY_DEV_PATH="$D/empty" "$BIN" doctor --json 2>/dev/null || true)"
for _pat in '"kmods": []' '"dri": []' '"nvidia": []' '"fuse": null'; do
    if grep -Fq "$_pat" <<<"$_json_empty"; then echo "PASS: json mock $_pat";
    else echo "FAIL: json mock $_pat"; FAIL=$((FAIL+1)); fi
done

# --- parseo estricto + tipos + orden (solo si hay python3)
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["format"] == 1, "format"
assert d["level"] in (1, 2), "level"
assert d["libc"]["kind"] in ("glibc", "musl", "unknown"), "libc.kind"
assert isinstance(d["userns"], bool), "userns"
assert isinstance(d["kmods"], list) and d["kmods"] == sorted(d["kmods"]), "kmods ordenado"
assert isinstance(d["dev"]["dri"], list) and d["dev"]["dri"] == sorted(d["dev"]["dri"]), "dri ordenado"
assert isinstance(d["fixes_available"], list) and isinstance(d["fixes_applied"], list), "fixes"
assert isinstance(d["landlock"], dict) and d["landlock"]["abi"] is None, "landlock"
assert isinstance(d["nvidia"], dict) and isinstance(d["nvidia"]["usable"], bool), "nvidia"
' 2>/dev/null; then echo "PASS: json parseo estricto + tipos";
    else echo "FAIL: json parseo estricto + tipos"; FAIL=$((FAIL+1)); fi
else
    echo "SKIP: parseo estricto (sin python3; los asserts grep ya corrieron)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
