#!/usr/bin/env bash
#
# install.sh — instalador generico de arxy para cualquier distro.
# (En Void se recomienda el paquete xbps de packaging/void en su lugar.)
#
#   sudo ./install.sh                    # a /usr/local
#   sudo PREFIX=/usr ./install.sh        # a /usr
#   DESTDIR=/tmp/pkg PREFIX=/usr ./install.sh   # empaquetado
#
# Instala: bin/arxy (+ symlink axy) y etc/arxy.conf.
# La configuracion existente NO se sobrescribe (se deja .nuevo al lado).

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
SRC_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"

BIN_DST="$DESTDIR$PREFIX/bin"
CONF_DST="$DESTDIR/etc/arxy"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "falta '$1' en el host" >&2; exit 1; }; }

# Dependencias de runtime de arxy (mismas que el template xbps + sha256sum).
for c in bash bwrap curl tar zstd xz gzip file sha256sum; do
    need_cmd "$c"
done

[[ -f "$SRC_DIR/src/arxy" ]] || { echo "no se encuentra src/arxy (ejecuta desde la raiz del repo)" >&2; exit 1; }
[[ -f "$SRC_DIR/config/arxy.conf" ]] || { echo "no se encuentra config/arxy.conf" >&2; exit 1; }

install -d -m755 "$BIN_DST" "$CONF_DST"
install -m755 "$SRC_DIR/src/arxy" "$BIN_DST/arxy"
ln -sf arxy "$BIN_DST/axy"
if [[ -f "$CONF_DST/arxy.conf" && -z "$DESTDIR" ]]; then
    install -m644 "$SRC_DIR/config/arxy.conf" "$CONF_DST/arxy.conf.nuevo"
    echo "arxy instalado; tu /etc/arxy/arxy.conf se conserva (nuevo en arxy.conf.nuevo)"
else
    install -m644 "$SRC_DIR/config/arxy.conf" "$CONF_DST/arxy.conf"
    echo "arxy instalado en $BIN_DST (arxy + axy)"
fi
echo "Siguiente: sudo arxy setup"
