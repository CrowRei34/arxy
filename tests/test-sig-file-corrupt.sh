#!/usr/bin/env bash
# test-sig-file-corrupt.sh — .arxy-sig corrupto: "", "2" o basura deben leerse
# como no-verificado (false), con rc 0 y stderr limpio; "1" sigue dando true. Via binario con root
# valido en /tmp (sin root real ni red).
set -uo pipefail
FAIL=0
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
R="$D/root"
mkdir -p "$R/usr/bin" "$R/etc"
: > "$R/usr/bin/bash"; : > "$R/usr/bin/pacman"
chmod +x "$R/usr/bin/bash" "$R/usr/bin/pacman"
echo "NAME=Arch Linux" > "$R/etc/arch-release"

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: corrupto -> false, rc 0, stderr limpio"
for sig in "" "2" "x"; do
    printf '%s' "$sig" > "$D/.arxy-sig"
    out="$(ARXY_ROOT="$R" ARXY_IMAGE_URL="http://ejemplo.invalid/y" "$BIN" doctor --json 2>"$D/err")"; rc=$?
    if [[ $rc -eq 0 ]] && grep -q '"last_setup_verified": false' <<<"$out" && [[ ! -s "$D/err" ]]; then ok "T1 sig='$sig'";
    else no "T1 sig='$sig' (rc=$rc err=$(cat "$D/err"))"; fi
done

echo "== T2: '1' -> true (sin regresion)"
printf '1' > "$D/.arxy-sig"
out="$(ARXY_ROOT="$R" ARXY_IMAGE_URL="http://ejemplo.invalid/y" "$BIN" doctor --json 2>"$D/err")"; rc=$?
[[ $rc -eq 0 ]] && grep -q '"last_setup_verified": true' <<<"$out" && [[ ! -s "$D/err" ]] && ok "T2 true" || no "T2 true (rc=$rc)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
