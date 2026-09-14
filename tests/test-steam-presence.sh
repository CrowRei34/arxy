#!/usr/bin/env bash
# test-steam-presence.sh — presencia de Steam en el rootfs real.
# NUNCA lanza UI ni ejecuta el binario (ni `steam --help`: se cuelga):
# presencia = test -x, nunca --version (AGENTS.md regla 5). Sin root ni HW:
# sin rootfs real, SKIP honesto (no FAIL).
set -uo pipefail
FAIL=0
R="${ARXY_ROOT:-/var/lib/arxy/root}"

[[ -d "$R/usr/bin" ]] || { echo "SKIP: sin rootfs real en $R"; exit 0; }
[[ -f "$R/usr/share/applications/steam.desktop" ]] || { echo "SKIP: sin steam.desktop en $R"; exit 0; }

if [[ -x "$R/usr/bin/steam" ]]; then echo "PASS: steam presente (+x)";
else echo "FAIL: steam ausente en $R/usr/bin/steam"; FAIL=$((FAIL+1)); fi

# Regla 5 (pipefail): capturar en variable y grepear despues.
desk_out="$(grep -E '^Exec=' "$R/usr/share/applications/steam.desktop" 2>&1 || true)"
if grep -q '^Exec=/usr/bin/steam' <<<"$desk_out"; then echo "PASS: steam.desktop Exec";
else echo "FAIL: steam.desktop sin Exec=/usr/bin/steam (tengo [$desk_out])"; FAIL=$((FAIL+1)); fi

if [[ -e "$R/usr/bin/proton-ge" ]]; then
    if [[ -x "$R/usr/bin/proton-ge" ]]; then echo "PASS: proton-ge presente (+x)";
    else echo "FAIL: proton-ge sin +x en $R/usr/bin/proton-ge"; FAIL=$((FAIL+1)); fi
else
    echo "INFO: proton-ge ausente (opcional, no bloquea)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
