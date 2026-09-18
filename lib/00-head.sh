#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# arxy — subsistema Arch minimalista para correr software glibc en cualquier distro.
#
# Sin sandbox y sin contenedorizar por app: un mount namespace minimo (bwrap)
# para ver la raiz Arch como / siendo usuario normal. Rendimiento nativo.
# Comparte /home, /tmp, /run, /dev y la GPU con el host. No toca nada del host
# fuera de /var/lib/arxy y ~/.local/share/applications/arxy-*.desktop.
#
# Instalacion (Void): sudo xbps-install arxy -y
# La imagen minima se descarga sola en el primer uso (setup automatico).
# Para administrar dentro (pacman): sudo arxy shell

set -uo pipefail

HOME="${HOME:-/root}"
export LC_ALL=C

ARXY_VERSION="0.6.0"
PROG="arxy"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# --- configuracion (precedencia: env > user-conf > sys-conf > defaults)
# Congelar lo que vino por entorno: ningun fichero puede pisarlo (se
# restauran VALORES tras leerlos, junto al user-conf del usuario real,
# mas abajo; guardar solo nombres no sirve: el source ya los piso).
declare -A _frozen_val=()
while IFS= read -r _n; do _frozen_val["$_n"]="${!_n}"; done < <(compgen -e | grep '^ARXY_' || true)
_restore_frozen() { # el env congelado manda sobre cualquier fichero.
    # OJO: llamarlo ANTES de derivar (ARXY_DATA y cia cuelgan de ARXY_*);
    # restaurar despues deja ROOT y DATA de mundos distintos (split-brain:
    # setup extraia en el root aislado pero escribia version/level2-rc en
    # el vivo, probado con ARXY_ROOT=/tmp/xyz).
    local _n
    if ((${#_frozen_val[@]})); then
        for _n in "${!_frozen_val[@]}"; do
            printf -v "$_n" '%s' "${_frozen_val[$_n]}"
            # shellcheck disable=SC2163 # export indirecto intencionado (NAME=valor)
            export "$_n"
        done
    fi
}
ARXY_ROOT="${ARXY_ROOT:-/var/lib/arxy/root}"
ARXY_IMAGE_URL="${ARXY_IMAGE_URL:-}"
ARXY_IMAGE_SHA256="${ARXY_IMAGE_SHA256:-}"
ARXY_SIGNATURE_POLICY="${ARXY_SIGNATURE_POLICY:-optional}" # required|optional|off

ARXY_SYS_CONF="/etc/arxy/arxy.conf"
ARXY_USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/arxy/config"
# shellcheck source=/dev/null
[[ -r "$ARXY_SYS_CONF" ]] && . "$ARXY_SYS_CONF"
# shellcheck source=/dev/null
[[ -r "$ARXY_USER_CONF" ]] && . "$ARXY_USER_CONF"
_restore_frozen

ARXY_ARGV=("$@")

# --- usuario real (los .desktop van a SU home aunque se use sudo/doas)
if [[ "$(id -u)" -eq 0 ]]; then
    REAL_USER="${SUDO_USER:-${DOAS_USER:-${USER:-$(id -un)}}}"
else
    REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "${REAL_HOME:-}" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
# XDG manda si esta fijado (tests/CI lo aislan en un tmpdir); si no, lo de
# siempre. Sin esto, SUDO_USER filtrado parte los lanzadores del dir que la
# matrix mira (dos tandas de FAILs en falso por el mismo gotcha).
REAL_APPS="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/applications"

# Root via sudo/doas (ej. 'sudo arxy setup'): arriba se leyo el user-conf
# de /root; el del usuario real tambien cuenta. El env congelado manda.
if [[ "$(id -u)" -eq 0 && "$REAL_HOME" != "$HOME" ]]; then
    # shellcheck source=/dev/null
    [[ -r "$REAL_HOME/.config/arxy/config" ]] && . "$REAL_HOME/.config/arxy/config"
    _restore_frozen
fi
unset _frozen_val

# vacio no es "unset" (:- los confunde y DATA/BUILD/VFILE caerian
# a rutas reales creyendo aislar). Tras ambos restores, vacio muere claro
# (die aun no existe aqui: echo+exit con el mismo prefijo).
if [[ -z "${ARXY_ROOT:-}" ]]; then
    echo "arxy: error: ARXY_ROOT vacio (unset para usar el default)" >&2
    exit 1
fi
# Derivados de ARXY_ROOT en UN solo punto, DESPUES de ambas restauraciones.
# Antes se derivaba entre el primer _restore_frozen y el source del usuario
# real: con sudo sin env y ARXY_ROOT en el conf del usuario real, ROOT
# apuntaba al conf pero DATA/VFILE/BUILD seguian del sys-conf (split-brain:
# setup extraia en un root y escribia version/level2-rc en otro).
ARXY_DATA="${ARXY_ROOT%/*}"              # /var/lib/arxy
# version DENTRO del root: nace en el staging y el rename la
# publica junto a la imagen — nunca hay root nuevo con version vieja ni al
# reves, y el rollback la rota sola. El env manda (tests la aislan).
: "${ARXY_VERSION_FILE:=$ARXY_ROOT/var/lib/arxy/version}"
# Ruta del formato anterior (fuera del root): solo se lee para adoptar una vez y
# borrar; el codigo nuevo jamas la escribe (una sola verdad).
: "${ARXY_VERSION_LEGACY:=$ARXY_DATA/version}"
ARXY_BUILD="$ARXY_DATA/build"              # dir de compilacion AUR (1777)
NS_BUILD="/arxy-build"                     # misma dir vista desde dentro

LD_LINUX="$ARXY_ROOT/usr/lib/ld-linux-x86-64.so.2" # interprete ELF del subsistema
ARXY_LIBPATH="$ARXY_ROOT/usr/lib"

# --- utilidades
msg()  { echo "arxy: $*"; }
die()  { echo "arxy: error: $*" >&2; exit 1; }

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "falta '$c' en el host (instalalo con tu gestor de paquetes)"
    done
}

# Env ARXY_* ya resuelto -> comandos elevados (sudo VAR= / doas env VAR=).
# Fuente unica para need_root y as_root: un sudo pelado pierde ARXY_ROOT
# y opera sobre el rootfs por defecto (instalaciones cruzadas).
arxy_env_pass() { # imprime VAR=val por linea (valores: rutas/flags, sin \n)
    # sudo/doas fijan el env en el hijo: sin export basta la asignacion.
    local v
    while IFS= read -r v; do
        [[ "$v" == ARXY_ARGV ]] && continue # array, no escalar
        [[ "$v" == ARXY_LOCK_FD ]] && continue # fd local: el hijo debe tomar su propio lock
        printf '%s=%s\n' "$v" "${!v}"
    done < <(compgen -v | grep '^ARXY_' || true)
}

# sudo/doas segun lo que traiga el host (Void minimo no trae ninguno por defecto).
as_root() {
    local -a pass=()
    mapfile -t pass < <(arxy_env_pass)
    if command -v sudo >/dev/null 2>&1; then
        sudo "${pass[@]}" -- "$@"
    else
        doas env "${pass[@]}" "$@"
    fi
}

# Re-ejecuta todo el argv original como root (los comandos que escriben lo exigen).
# El proceso root no puede releer el user-conf del usuario (tras sudo su
# $HOME es /root): se propaga toda la config ARXY_* ya resuelta arriba
# (precedencia env > user-conf > sys-conf).
need_root() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local -a pass=()
    mapfile -t pass < <(arxy_env_pass)
    if command -v sudo >/dev/null 2>&1; then
        exec sudo "${pass[@]}" -- "$SELF" "${ARXY_ARGV[@]}"
    elif command -v doas >/dev/null 2>&1; then
        exec doas env "${pass[@]}" "$SELF" "${ARXY_ARGV[@]}"
    else
        die "este comando necesita root y no hay sudo/doas. Ejecuta: sudo $PROG ${ARXY_ARGV[*]}"
    fi
}

_image_ok() { # <dir>: valida un rootfs (instalado o en staging)
    [[ -x "$1/usr/bin/bash" && -x "$1/usr/bin/pacman" && -f "$1/etc/arch-release" ]]
}
image_ok() { _image_ok "$ARXY_ROOT"; }

# Lock advisory unico para ops con estado (setup/rollback/gc-apply/
# clean-apply/install/remove/update/doctor-apply corrian sin serializar;
# dos setups peleaban por el unico slot .old con perdida silenciosa).
# flock(1) no-bloqueante sobre ${ARXY_ROOT%/*}/.lock (== $ARXY_DATA/.lock en
# produccion; no usar $ARXY_DATA directo: ver cuerpo): tomado, muere claro.
# Reentrante en el mismo proceso (doctor --apply -> cmd_install comparten
# el fd); el lock vive hasta el exit (cierre implicito). Tomar DESPUES de
# need_root (el re-exec pierde fds... salvo heredados, y el padre-usuario
# no debe bloquear). Fuera: fase AUR como usuario (dirs unicos por PID;
# su fase privilegiada entra por cmd_install_file, que si lo toma).
data_lock() {
    [[ -n "${ARXY_LOCK_FD:-}" ]] && return 0 # ya tomado (anidado)
    # OJO: derivar de ARXY_ROOT, NO de ARXY_DATA (los tests exportan ROOT
    # tras sourcear y DATA queda rancio al default real: el lock caeria en
    # /var/lib/arxy. En produccion son identicos: DATA="${ROOT%/*}").
    local lf="${ARXY_ROOT%/*}/.lock"
    mkdir -p "${ARXY_ROOT%/*}" 2>/dev/null || die "no pude crear ${ARXY_ROOT%/*} (¿permisos?)"
    # OJO: este exec va PELADO (sin 2>/dev/null ni ||): cualquier redireccion
    # extra persistiria en la shell (el stderr moria para siempre y los die
    # salian mudos, cazado en tests). Si no se abre, bash muere con su error
    # (caso ya roto: sin escritura en DATA no hay operacion posible).
    exec {ARXY_LOCK_FD}>"$lf"
    [[ -n "${ARXY_LOCK_FD:-}" ]] || die "no pude abrir lock $lf (¿permisos?)"
    flock -n "$ARXY_LOCK_FD" 2>/dev/null || die "otra operacion arxy en curso (lock $lf); reintenta cuando termine"
}

# Sin tty (scripts, pipes) pacman no puede preguntar: confirmar solo.
# Uso: nc_args <nombre-array>; luego "${arr[@]}".
nc_args() {
    local -n _nc=$1
    _nc=()
    [[ -t 0 ]] || _nc=(--noconfirm)
}

ensure_image() {
    recover_staging || true # huerfanos de kills: reparar nunca bloquea el arranque
    if image_ok; then ensure_version; migrate_version_file; return 0; fi
    msg "imagen no encontrada en $ARXY_ROOT, descargando..."
    cmd_setup
    image_ok || die "la instalacion de la imagen fallo (mira el error de arriba o reintenta 'sudo $PROG setup')"
}

