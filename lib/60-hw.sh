# GPU discreta que mesa-mini (sin LLVM) no acelera: amd|nvidia|"". Via /sys
# (lspci puede no existir en hosts minimos). ARXY_SYS_DRM_PATH inyecta un
# /sys falso para tests sin hardware (ver tests/test-gpu-drm.sh).
detect_gpu() {
    local base="${ARXY_SYS_DRM_PATH:-/sys/class/drm}" v
    for v in "$base"/card*/device/vendor; do
        [[ -f "$v" ]] || continue
        case "$(cat "$v" 2>/dev/null)" in
            *1002*) echo amd; return 0 ;;
            *10de*) echo nvidia; return 0 ;;
        esac
    done
    return 1
}

is_mesa_mini() { # mini = build externo sin firma conocida
    run_pacman -Qi mesa 2>/dev/null | grep -q '^Packager.*Unknown'
}

# --- detecciones Fase 2 (contrato doctor --json / hardware.json, format 1) ---
# Schema mínimo (tipos): format=int, level=int, libc=glibc|musl|unknown,
# kernel={arch,releasestr}, userns/overlayfs_rootless/mount_setattr/seccomp/
# cgroupv2=bool, landlock={available,abi}, gpu={vendor,driver}|null,
# nvidia={present,version|null}, kmods=[fuse,userfaultfd,ntsync],
# dev=[rutas], rootfs={path,version}. Añadir campos OK; renombrar/quitar no.
# Salidas de una línea, componibles sin jq. Mocks (patrón ARXY_SYS_DRM_PATH):
#   ARXY_SYS_ROOT=""  prefijo de /proc y /sys (falso en tests)
#   ARXY_DEV_PATH="/dev"  dir de dispositivos (falso en tests)
#   ARXY_LIB_DIR="/lib"  dir de loaders (falso en tests)
#   ARXY_LIB64_DIR="/lib64"  idem 64 bits (falso en tests)
detect_libc() { # glibc|musl|unknown (el loader musl manda: es inequívoco)
    local d="${ARXY_LIB_DIR:-/lib}" m
    for m in "$d"/ld-musl-*.so.1; do
        [[ -e "$m" ]] && { echo musl; return 0; }
    done
    local v=""
    if command -v ldd >/dev/null 2>&1; then
        v="$(ldd --version 2>&1 | head -n 1 || true)"
        case "$v" in *musl*) echo musl; return 0 ;; *GLIBC*|*"GNU libc"*) echo glibc; return 0 ;; esac
    fi
    [[ -f "${ARXY_LIB64_DIR:-/lib64}/ld-linux-x86-64.so.2" || -f "$d/ld-linux.so.2" ]] && { echo glibc; return 0; }
    echo unknown
}

detect_nvidia_ver() { # 550.54.14|"" (vacío = sin driver o sin módulo)
    local base="${ARXY_SYS_ROOT:-}" f v
    for f in "$base/proc/driver/nvidia/version" "$base/sys/module/nvidia/version"; do
        [[ -f "$f" ]] || continue
        v="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' "$f" 2>/dev/null | head -n 1 || true)"
        [[ -n "$v" ]] && { echo "$v"; return 0; }
    done
    return 1
}

detect_kmods() { # sublista presente de: fuse userfaultfd ntsync ("" = ninguno)
    local base="${ARXY_SYS_ROOT:-}" dev="${ARXY_DEV_PATH:-/dev}" out=""
    [[ -d "$base/sys/module/fuse" ]] && out+="fuse "
    [[ -f "$base/proc/sys/vm/unprivileged_userfaultfd" ]] && out+="userfaultfd "
    [[ -e "$dev/ntsync" ]] && out+="ntsync "
    echo "${out% }"
    return 0
}

detect_dev_nodes() { # una ruta por línea: dri/* nvidia* fuse ntsync ("" = nada)
    local dev="${ARXY_DEV_PATH:-/dev}" n
    for n in "$dev"/dri/* "$dev"/nvidia* "$dev"/fuse "$dev"/ntsync; do
        [[ -e "$n" ]] || continue
        echo "$n"
    done
    return 0
}

cmd_quickstart() { # el siguiente paso segun estado (para quien no lee READMEs)
    echo "$PROG $ARXY_VERSION: tu siguiente paso es"
    if ! image_ok; then
        echo "  $PROG setup            # descarga el subsistema (~130MB)"
        echo "Despues: $PROG install firefox && $PROG run firefox"
        return 0
    fi
    local n g
    n="$(ls "$REAL_APPS"/arxy-*.desktop 2>/dev/null | wc -l)"
    if [[ "$n" -eq 0 ]]; then
        echo "  $PROG install <app>    # p. ej. $PROG install firefox"
    else
        echo "  $PROG run <app>        # o desde el menu ($n lanzadores; $PROG list para ver)"
    fi
    g="$(detect_gpu || true)"
    if [[ -n "$g" ]] && is_mesa_mini; then
        echo "  ...y GPU $g: $PROG install gpu-$g para aceleracion HW (+~170MB)"
    fi
}

# Aviso mesa-mini en AMD/NVIDIA (solo informa, nunca falla).
# Funcion separada (no inline en doctor): el $() dentro de cmd_doctor
# dispara un falso positivo SC2319 en shellcheck 0.11.
doctor_gpu() {
    local _g
    _g="$(detect_gpu || true)"
    [[ -n "$_g" ]] || return 0
    image_ok || return 0
    is_mesa_mini || return 0
    if [[ "$_g" == nvidia ]]; then
        msg "aviso GPU NVIDIA: solo nouveau via '$PROG install gpu-nvidia' (+~170MB); propietaria no soportada en v1 (rendimiento limitado)"
    else
        msg "aviso GPU AMD: mesa-mini no acelera HW; '$PROG install gpu-amd' instala el stack completo (+~170MB)"
    fi
}

# Chequeos con arreglo: informan siempre, reparan con --fix. Lo destructivo
# (db.lck) exige tty+confirmacion; rollback pendiente solo se sugiere.
# 'ok' es el local de cmd_doctor (scope dinamico de bash: se ve sin declarar).
doctor_fix() { # [--fix]
    local fix=""
    [[ "${1:-}" == "--fix" ]] && fix=1
    if [[ -n "$fix" && "$(id -u)" -ne 0 ]]; then
        msg "'$PROG doctor --fix' necesita root para aplicar; solo informo"
        fix=""
    fi
    # Hold: solo importa con mini (con mesa oficial sobra a proposito).
    if image_ok && is_mesa_mini && ! grep -q '^IgnorePkg.*mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null; then
        msg "falta hold IgnorePkg=mesa: un update traeria mesa oficial +170MB"
        ok=1
        if [[ -n "$fix" ]]; then
            sed -i '/^\[options\]/a IgnorePkg   = mesa' "$ARXY_ROOT/etc/pacman.conf" && msg "hold añadido (bajo [options])"
        fi
    fi
    local lock="$ARXY_ROOT/var/lib/pacman/db.lck"
    if [[ -f "$lock" ]]; then
        # ¿pacman real en curso? Por comm de /proc, no por cmdline (pgrep -f
        # se auto-detecta: nuestra propia linea de comandos menciona pacman).
        local _run="" _pc
        for _pc in /proc/[0-9]*/comm; do
            [[ -f "$_pc" ]] || continue
            [[ "$(cat "$_pc" 2>/dev/null)" == pacman ]] && { _run=1; break; }
        done
        if [[ -n "$_run" ]]; then
            msg "db.lck presente con pacman en curso: normal"
        else
            msg "db.lck sin pacman visible: stale probable"
            ok=1
            if [[ -n "$fix" ]]; then
                if [[ -t 0 ]]; then
                    local ans
                    read -r -p "¿borrar $lock? [s/N] " ans
                    [[ "$ans" == [sS]* ]] && { rm -f "$lock" && msg "lock borrado"; }
                else
                    msg "sin tty: borralo a mano si ningun pacman corre"
                fi
            fi
        fi
    fi
    if [[ -d "$ARXY_ROOT.old" ]]; then
        msg "rollback pendiente: '$PROG rollback' restaura, o borra $ARXY_ROOT.old"
    fi
}

# --- doctor / version / ayuda
cmd_doctor() {
    local ok=0
    say() { if [[ "$1" -eq 0 ]]; then echo "[OK]   $2"; else echo "[FALTA] $2"; ok=1; fi; }
    command -v bwrap >/dev/null 2>&1; say $? "bwrap en el host"
    command -v curl >/dev/null 2>&1; say $? "curl en el host"
    command -v tar >/dev/null 2>&1; say $? "tar en el host"
    for _c in zstd sha256sum awk sed grep mktemp su; do
        command -v "$_c" >/dev/null 2>&1; say $? "$_c en el host"
    done
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then
        say 0 "user namespaces (unshare -U)"
    elif bwrap --ro-bind / / /bin/true 2>/dev/null; then
        say 0 "user namespaces (bwrap)"
    else
        say 1 "user namespaces (necesarios para correr sin root)"
    fi
    image_ok; say $? "imagen en $ARXY_ROOT"
    [[ -f "$ARXY_VERSION_FILE" ]] && msg "imagen: $(tr '\n' ' ' <"$ARXY_VERSION_FILE")"
    [[ -n "$ARXY_IMAGE_URL" ]]; say $? "ARXY_IMAGE_URL configurada"
    # Deteccion sin dependencias exoticas: solo bwrap funcional (nunca unshare).
    level
    if [[ "$_ARXY_LEVEL" == 1 ]]; then
        echo "[OK]   nivel 1 (bwrap + namespaces)"
    else
        echo "[OK]   nivel 2 (sin namespaces: ld-linux para run, chroot para install)"
    fi
    [[ -n "${ARXY_LEVEL:-}" ]] && msg "override manual: ARXY_LEVEL=$ARXY_LEVEL"
    doctor_gpu
    doctor_fix "${1:-}"
    return $ok
}

cmd_version() {
    echo "$PROG $ARXY_VERSION"
    if [[ -f "$ARXY_VERSION_FILE" ]]; then
        tr '\n' ' ' <"$ARXY_VERSION_FILE"; echo
    fi
    [[ "${1:-}" == "--verbose" ]] || return 0
    [[ -z "${2:-}" ]] || die "uso: $PROG version [--verbose]"
    level
    echo "nivel: $_ARXY_LEVEL (1=bwrap, 2=sin namespaces)"
    echo "gpu: $(detect_gpu || echo 'no discreta (intel o softpipe)')"
    echo "rootfs: $(du -sh "$ARXY_ROOT" 2>/dev/null | cut -f1) en $ARXY_ROOT"
    if grep -q '^IgnorePkg.*mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null; then
        echo "hold mesa-mini: activo"
    else
        echo "hold mesa-mini: ausente"
    fi
}

