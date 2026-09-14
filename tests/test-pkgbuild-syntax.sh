#!/usr/bin/env bash
# test-pkgbuild-syntax.sh — los PKGBUILDs de packaging/aur/ son bash valido
# (drafts aun no publicados). namcap si existe (Arch), si no SKIP honesto.
set -uo pipefail
FAIL=0
cd "$(dirname "$0")/.." || exit 1
for p in packaging/aur/*/PKGBUILD; do
    if bash -n "$p" 2>/dev/null; then echo "PASS: bash -n $p";
    else echo "FAIL: bash -n $p"; FAIL=$((FAIL+1)); fi
done
if command -v namcap >/dev/null 2>&1; then
    for p in packaging/aur/*/PKGBUILD; do
        if namcap "$p" 2>&1 | grep -qE "^(E|W).*PKGBUILD"; then
            echo "FAIL: namcap $p"; FAIL=$((FAIL+1))
        else echo "PASS: namcap $p"; fi
    done
else
    echo "SKIP: namcap ausente (solo bash -n)"
fi
echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
