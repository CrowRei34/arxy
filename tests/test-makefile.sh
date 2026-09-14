#!/usr/bin/env bash
# test-makefile.sh — el build genera src/arxy byte-idéntico (D9) y válido.
# Sin root. Se corre desde la raíz del repo arxy (o tests/).
set -uo pipefail
FAIL=0
cd "$(dirname "$0")/.." || exit 1

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "make src/arxy sale 0" -- make src/arxy
t "generado == commiteado" -- git diff --exit-code -- src/arxy
h1="$(sha256sum <src/arxy)"
t "make -B idempotente" -- sh -c 'make -B src/arxy >/dev/null && test "$(sha256sum <src/arxy)" = "'"$h1"'"'
t "bash -n generado" -- bash -n src/arxy
t "shebang + cierre" -- sh -c 'test "$(head -1 src/arxy)" = "#!/usr/bin/env bash" && test "$(tail -1 src/arxy)" = "esac"'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
