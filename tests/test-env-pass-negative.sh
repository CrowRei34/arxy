#!/usr/bin/env bash
# test-env-pass-negative.sh — sin elevador no se eleva: sin sudo ni doas,
# as_root debe fallar (no operar sobre el rootfs por defecto en silencio). PATH minimo sin elevador.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkdir -p "$D/empty"
# id SÍ (sin el, $(id -u) da "" y [[ "" -eq 0 ]] miente root); sudo/doas NO.
ln -s "$(command -v grep)" "$D/empty/grep" 2>/dev/null || true
ln -s "$(command -v id)" "$D/empty/id" 2>/dev/null || true

echo "== T1: sin sudo ni doas, as_root falla (rc!=0)"
out="$( ( unset -f sudo doas 2>/dev/null; PATH="$D/empty" as_root true anything ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && ok "T1 falla sin elevador" || no "T1 falla sin elevador (rc=$rc $out)"

echo "== T2: need_root sin elevador muere claro"
out="$( ( unset -f sudo doas 2>/dev/null; PATH="$D/empty" ARXY_ARGV=(shell) need_root ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && grep -q "necesita root" <<<"$out" && ok "T2 need_root claro" || no "T2 need_root claro (rc=$rc $out)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
