#!/usr/bin/env bash
# test-chroot-dns.sh — fallback DNS en chroot avisa (M5 backlog, MEDIA):
# si bind+copia de resolv.conf fallan, in_chroot avisa a stderr (antes:
# chroot sin DNS y pacman moria con error de red confuso). mount/chroot/
# umount stubbed; rootfs y etc en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"; chmod -R u+w "$D" 2>/dev/null || true' EXIT
export ARXY_ROOT="$D/root"
mkdir -p "$ARXY_ROOT/proc" "$ARXY_ROOT/sys" "$ARXY_ROOT/dev" "$ARXY_ROOT/etc"

# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1

mount() { return 1; }
umount() { return 0; }
chroot() { return 0; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: copia imposible -> avisa y sigue (rc 0)"
chmod 555 "$ARXY_ROOT/etc"
out="$(in_chroot /usr/bin/true 2>&1)"; rc=$?
chmod 755 "$ARXY_ROOT/etc"
[[ $rc -eq 0 ]] && grep -q "DNS del host no disponible" <<<"$out" && ok "T1 avisa" || no "T1 avisa (rc=$rc $out)"

echo "== T2: copia OK -> sin ruido"
rm -f "$ARXY_ROOT/etc/resolv.conf"
out="$(in_chroot /usr/bin/true 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q "DNS del host" <<<"$out" && ok "T2 calla" || no "T2 calla (rc=$rc $out)"
[[ ! -e "$ARXY_ROOT/etc/resolv.conf" ]] && ok "T2 limpia lo creado" || no "T2 limpia lo creado"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
