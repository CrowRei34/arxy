#!/usr/bin/env bash
# test-resolve-musl.sh — puerta musl y resolucion (P4-H8 segunda pasada,
# MEDIA): binario inexistente muere claro, ruta inexistente asume
# subsistema, ELF musl del host muere antes de bwrap, which distingue
# origen. Sin root ni imagen: todo en /tmp, file stubbed.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root"
mkdir -p "$ARXY_ROOT/usr/bin" "$D/hostbin"
: > "$ARXY_ROOT/usr/bin/miprog"; chmod +x "$ARXY_ROOT/usr/bin/miprog"
: > "$D/hostbin/musleep"; chmod +x "$D/hostbin/musleep"

# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/50-run.sh
. "$HERE/../lib/50-run.sh" >/dev/null 2>&1

ensure_image() { return 0; }
_ARXY_LEVEL=1

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: binario inexistente muere con ayuda"
out="$(resolve_target noexiste-xyz 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no encontrado" <<<"$out" && ok "T1 no encontrado" || no "T1 no encontrado (rc=$rc $out)"

echo "== T2: ruta inexistente asume subsistema"
resolve_target /no/existe-xyz
[[ "$RESOLVED_TARGET" == /no/existe-xyz && -z "$RESOLVED_HOST" ]] && ok "T2 subsistema" || no "T2 subsistema ($RESOLVED_TARGET)"

echo "== T3: ELF musl del host muere claro (no llega a bwrap)"
file() { echo "ELF 64-bit LSB pie executable, interpreter /lib/ld-musl-x86_64.so.1"; }
resolve_target "$D/hostbin/musleep"
[[ -n "$RESOLVED_HOST" ]] || { no "T3 setup (sin RESOLVED_HOST)"; }
out="$(check_musl 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "musl" <<<"$out" && ok "T3 musl muere" || no "T3 musl muere (rc=$rc $out)"
unset -f file

echo "== T4: ELF glibc pasa el gate"
file() { echo "ELF 64-bit LSB pie executable, interpreter /lib64/ld-linux-x86-64.so.2"; }
resolve_target "$D/hostbin/musleep"
out="$(check_musl 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "T4 glibc pasa" || no "T4 glibc pasa (rc=$rc $out)"
unset -f file

echo "== T5: which distingue subsistema vs host"
out="$(cmd_which miprog 2>&1)"
grep -q "subsistema" <<<"$out" && ok "T5 subsistema" || no "T5 subsistema ($out)"
out="$(cmd_which "$D/hostbin/musleep" 2>&1)"
grep -q "\[host\]" <<<"$out" && ok "T5 host" || no "T5 host ($out)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
