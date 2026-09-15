#!/usr/bin/env bash
# test-desktop-shims.sh — sin shims en el rootfs por diseño (Fase 6a):
# las apps llegan al host vía ARXY_BRIDGE_SOCKET/TOKEN + allowlist del
# daemon (e2e T0/T16/T19); xdg-open cubre gio. Sin root ni imagen: grep
# al repo (contrato, no comportamiento).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
REPO="$HERE/.."

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1${2:+ (tengo '$2')}"; FAIL=$((FAIL+1)); }

grep -q 'xdg-open' "$REPO/lib/80-bridge.sh" && ok "allowlist trae xdg-open" || no "allowlist trae xdg-open"
grep -q 'notify-send' "$REPO/lib/80-bridge.sh" && ok "allowlist trae notify-send" || no "allowlist trae notify-send"
[[ "$(grep -l 'xdg-open' "$REPO"/lib/*.sh)" == "$REPO/lib/80-bridge.sh" ]] \
    && ok "xdg-open solo en allowlist (sin shim)" || no "xdg-open solo en allowlist" "$(grep -l 'xdg-open' "$REPO"/lib/*.sh | tr '\n' ' ')"
[[ "$(grep -l 'notify-send' "$REPO"/lib/*.sh)" == "$REPO/lib/80-bridge.sh" ]] \
    && ok "notify-send solo en allowlist (sin shim)" || no "notify-send solo en allowlist" "$(grep -l 'notify-send' "$REPO"/lib/*.sh | tr '\n' ' ')"
if grep -rEqw 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null; then
    no "gio ausente (xdg-open lo cubre)" "$(grep -rEow 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null | head -n 2 | tr '\n' ' ')"
else
    ok "gio ausente (xdg-open lo cubre)"
fi
grep -q 'ARXY_BRIDGE_SOCKET' "$REPO/lib/10-level.sh" && ok "run_in expone SOCKET" || no "run_in expone SOCKET"
grep -q 'ARXY_BRIDGE_TOKEN' "$REPO/lib/10-level.sh" && ok "run_in expone TOKEN" || no "run_in expone TOKEN"
for _t in T0 T16 T19; do
    if grep -q "\"$_t" "$REPO/tests/test-bridge-in-container.sh"; then ok "e2e cubre $_t"; else no "e2e cubre $_t"; fi
done

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
