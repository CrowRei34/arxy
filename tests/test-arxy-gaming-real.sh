#!/usr/bin/env bash
# test-arxy-gaming-real.sh — install arxy-gaming de verdad.
# Lento (~1GB + build AUR) y con root: SOLO con ARXY_GAMING_REAL=1,
# ARXY_ROOT aislado (jamas el de produccion) y uid 0. Sin eso: SKIP.
# Fuera de la puerta rapida; para CI semanal o verificacion manual.
# La mitad AUR se compila como $SUDO_USER (makepkg prohibe root); sin
# usuario invocador ese T se SKIPea (root-directo no puede compilar).
set -uo pipefail
FAIL=0
if [[ "${ARXY_GAMING_REAL:-}" != 1 ]]; then echo "SKIP: exige ARXY_GAMING_REAL=1 (lento, ~1GB)"; exit 0; fi
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: exige root"; exit 0; }
R="${ARXY_ROOT:-}"
[[ -n "$R" && "$R" != /var/lib/arxy/root ]] || { echo "SKIP: exige ARXY_ROOT aislado (no el de produccion)"; exit 0; }
BIN="${ARXY_BIN:-arxy}"

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | tail -3 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "dry-run sin tocar" -- "$BIN" install arxy-gaming --dry-run
echo "== install real como root: oficial OK + AUR pendiente (contrato)"
if out="$("$BIN" install arxy-gaming 2>&1)"; then
    echo "FAIL: root-directo debio avisar AUR pendiente"; FAIL=$((FAIL+1))
else
    grep -q "parte AUR pendiente como root" <<<"$out" && echo "PASS: avisa follow-up" || { echo "FAIL: mensaje follow-up"; FAIL=$((FAIL+1)); }
fi
t "multilib activo" -- sh -c 'grep -q "^\[multilib\]" "$0/etc/pacman.conf"' "$R"
t "mesa full (llvm-libs)" -- "$BIN" run pacman -Qq llvm-libs
t "steam presente" -- "$BIN" run pacman -Qq steam
t "eglinfo Iris" -- sh -c '"$0" run eglinfo -B 2>/dev/null | grep -q "Mesa Intel"' "$BIN"

if [[ -n "${SUDO_USER:-}" ]]; then
    echo "== mitad AUR como $SUDO_USER =="
    UHOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if out="$(su -s /bin/sh "$SUDO_USER" -c "ARXY_ROOT='$R' XDG_DATA_HOME='${XDG_DATA_HOME:-/tmp}' HOME='$UHOME' '$BIN' install --aur proton-ge-custom-bin dxvk-bin" 2>&1)"; then
        echo "PASS: AUR como usuario"
    else
        echo "FAIL(1): AUR como usuario"; printf '%s\n' "$out" | tail -3 | sed 's/^/  /'; FAIL=$((FAIL+1))
    fi
    t "proton presente" -- "$BIN" run pacman -Qq proton-ge-custom-bin
else
    echo "SKIP: mitad AUR (sin SUDO_USER: root-directo no compila)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
