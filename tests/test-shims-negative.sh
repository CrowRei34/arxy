#!/usr/bin/env bash
# test-shims-negative.sh — el detector de shims caza (P4-H9 segunda
# pasada, MEDIA): prueba que el grep de test-desktop-shims.sh no es
# tautologico. Fixture con `gio` literal debe matchear; el repo real no.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
REPO="$HERE/.."
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkdir -p "$D/fakelib"
printf '#!/bin/sh\ngio open "$1"\n' > "$D/fakelib/99-fake.sh"

echo "== T1: fixture con gio matchea (el detector lo cazaria)"
if grep -rEqw 'gio' "$D/fakelib" 2>/dev/null; then ok "T1 caza gio";
else no "T1 caza gio"; fi

echo "== T2: repo real no matchea (ancla el positivo)"
if grep -rEqw 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null; then no "T2 repo limpio";
else ok "T2 repo limpio"; fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
