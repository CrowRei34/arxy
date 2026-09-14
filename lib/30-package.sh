# --- instalacion / remocion / mantenimiento (corren como root)
# Limpia los .pkg descargados tras operar (cero cache prolongada).
# Best-effort y silencioso; ARXY_KEEP_PKG_CACHE=1 la conserva.
clean_pkg_cache() {
    [[ -n "${ARXY_KEEP_PKG_CACHE:-}" ]] && return 0
    rm -f "$ARXY_ROOT"/var/cache/pacman/pkg/* 2>/dev/null || true
}

# Stack GL completo (mesa oficial + LLVM) sobre mesa-mini, para GPUs AMD
# (radeonsi) o NVIDIA (nouveau) que lo exigen. Solo para quien lo necesita
# (+~170MB): el default ligero no cambia. NVIDIA propietaria queda fuera a
# proposito (exige match exacto con el modulo del host): usa el driver del host.
cmd_gpu_stack() { # <gpu-amd|gpu-nvidia>
    # Quitar el hold de la imagen (sin match = ya quitado: idempotente).
    [[ -f "$ARXY_ROOT/etc/pacman.conf" ]] || return 0
    sed -i -E 's|^#?IgnorePkg[[:space:]]*=[[:space:]]*mesa|#IgnorePkg = mesa|' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || true
    # Sin --needed a proposito: mini y oficial comparten pkgname+version y
    # --needed lo daria por satisfecho. Solo reinstala si falta LLVM.
    local -a nc
    nc_args nc
    if ! run_pacman -Qq llvm-libs >/dev/null 2>&1; then
        pacman_mut -S "${nc[@]}" mesa || die "gpu: pacman fallo"
    fi
    clean_pkg_cache
    msg "gpu: stack completo instalado (${1:-})"
}

# --- meta-paquete gaming: rewrite a dependencias reales (no existe en AUR
# como paquete; los PKGBUILDs de packaging/aur/ son drafts para publicar).
# gpu_stack_pkgs() (doctor --fix) = minimo Vulkan; arxy_gaming_pkgs() =
# gaming completo. Distintas a proposito: no unificar.
arxy_gaming_vendor() { # nvidia|amd|intel ("" + rc 1 = sin GPU decidible)
    local v dri
    v="$(detect_gpu || true)"
    case "$v" in
        nvidia)
            # Propietario solo si el modulo responde (nouveau no sirve).
            [[ -r "${ARXY_SYS_ROOT:-}/proc/driver/nvidia/version" ]] && { echo nvidia; return 0; }
            return 1 ;;
        amd) echo amd; return 0 ;;
        *)
            # Sin discreta con dri expuesto se asume Intel (la iGPU no
            # reporta vendor a drm; mismo criterio que hardware.json).
            dri="$(detect_dev_nodes 2>/dev/null | grep -E '/(card[0-9]+|renderD[0-9]+)$' || true)"
            [[ -n "$dri" ]] && { echo intel; return 0; }
            return 1 ;;
    esac
}

arxy_gaming_pkgs() { # <vendor> : un paquete por linea (gaming completo)
    local v="$1" ver
    # Lista canonica en bash (los PKGBUILDs la espejan para publicar).
    # libva-*/intel-media-driver fuera: decode de video, no rendering.
    printf '%s\n' steam wine vkd3d gamescope mangohud vulkan-icd-loader lib32-vulkan-icd-loader
    case "$v" in
        nvidia)
            ver="$(detect_nvidia_ver || true)"
            [[ -n "$ver" ]] || die "NVIDIA sin version legible (¿nouveau?)"
            printf '%s\n' "nvidia-utils=$ver" "lib32-nvidia-utils=$ver" ;;
        amd) printf '%s\n' mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon ;;
        *) printf '%s\n' mesa lib32-mesa vulkan-intel lib32-vulkan-intel ;;
    esac
    # AUR (-bin) al final: el llamador parte por sufijo (convencion del repo).
    printf '%s\n' proton-ge-custom-bin dxvk-bin
    return 0
}

cmd_gaming() { # [--dry-run] [nvidia|amd|intel] : rama explicita = override
    local dry="" force=""
    [[ "${1:-}" == "--dry-run" ]] && { dry=1; shift; }
    force="${1:-}"
    local vendor
    if [[ -n "$force" ]]; then
        vendor="$force"
    elif ! vendor="$(arxy_gaming_vendor)"; then
        [[ "$(detect_gpu || true)" == nvidia ]] && \
            die "NVIDIA sin driver propietario (¿nouveau?): arxy-gaming exige el modulo propietario"
        die "GPU no detectada (sin drm/dri): instala a mano, p. ej. '$PROG install --aur arxy-gaming-intel'"
    fi
    local -a pkgs=()
    mapfile -t pkgs < <(arxy_gaming_pkgs "$vendor")
    if [[ -n "$dry" ]]; then
        echo "vendor detectado: $vendor"
        [[ "$(detect_libc 2>/dev/null || true)" == musl ]] && echo "host musl: solo devices del host, userspace del rootfs"
        echo "meta-paquete: arxy-gaming -> arxy-gaming-$vendor (draft en packaging/aur/, aun no publicado)"
        echo "paquetes (instalaria):"
        printf '  %s\n' "${pkgs[@]}"
        is_mesa_mini 2>/dev/null && echo "conflictos: mesa-mini seria reemplazado por mesa"
        echo "nada tocado (dry-run)"
        return 0
    fi
    local -a off=() aur=() p
    for p in "${pkgs[@]}"; do case "$p" in *-bin) aur+=("$p") ;; *) off+=("$p") ;; esac; done
    # makepkg prohibe root: la parte AUR se compila como usuario ANTES de
    # elevar (tras need_root ya es tarde). Con ARXY_GAMING_AUR_DONE la
    # re-ejecucion elevada la salta. Root-directo sin usuario que la haga:
    # se instala lo oficial y se dice como completar (mismo limite que
    # 'install --aur' con sudo: nunca funciono).
    if [[ "${#aur[@]}" -gt 0 && -z "${ARXY_GAMING_AUR_DONE:-}" ]]; then
        if [[ "$(id -u)" -ne 0 ]]; then
            cmd_install --aur "${aur[@]}"
            export ARXY_GAMING_AUR_DONE=1
        fi
    fi
    need_root
    ensure_image
    # [multilib] para lib32-* (idempotente; mismo idioma sed que el hold).
    # Guard primero: imagenes frescas ya traen una estanza activa (el
    # builder la añade); sin guard duplicariamos el registro.
    grep -q '^\[multilib\]' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || \
        sed -i -E '/^#\[multilib\]/,/^#?Include/s/^#//' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || true
    cmd_gpu_stack "arxy-gaming-$vendor" # mesa full idempotente (amd/intel/nvidia)
    [[ "${#off[@]}" -gt 0 ]] && cmd_install "${off[@]}"
    if [[ "${#aur[@]}" -gt 0 && -z "${ARXY_GAMING_AUR_DONE:-}" ]]; then
        die "parte AUR pendiente como root (makepkg prohibe root): completala como usuario: $PROG install --aur ${aur[*]}"
    fi
    msg "gaming listo: $vendor (arxy-gaming-$vendor)"
}

cmd_install() {
    # Rewrite arxy-gaming (meta-paquete virtual): va primero para que
    # --dry-run informe sin root (como doctor --fix). El resto de args
    # sigue su curso normal tras el gaming (o se ignora en dry-run).
    local -a _rest=()
    local _g _dry="" _want="" _branch=""
    for _g in ${1+"$@"}; do
        case "$_g" in
            arxy-gaming) _want=1 ;;
            arxy-gaming-nvidia|arxy-gaming-amd|arxy-gaming-intel) _want=1; _branch="${_g##*-}" ;;
            --dry-run) _dry=1 ;;
            *) _rest+=("$_g") ;;
        esac
    done
    if [[ -n "$_want" ]]; then
        local -a _gargs=()
        [[ -n "$_dry" ]] && _gargs+=(--dry-run)
        [[ -n "$_branch" ]] && _gargs+=("$_branch")
        cmd_gaming "${_gargs[@]+"${_gargs[@]}"}"
        local _rc=$?
        [[ -n "$_dry" || "${#_rest[@]}" -eq 0 ]] && return $_rc
        set -- "${_rest[@]}"
    fi
    if [[ "${1:-}" == "--aur" ]]; then
        shift
        cmd_install_aur "$@"
        return
    fi
    need_root
    [[ $# -ge 1 ]] || die "uso: $PROG install <paquete...>  |  $PROG install --aur <paquete...>"
    ensure_image
    # Nombres virtuales GPU (no son paquetes): se resuelven antes de pacman.
    local -a pkgs=()
    local g
    for g in "$@"; do
        case "$g" in gpu-amd|gpu-nvidia) cmd_gpu_stack "$g" ;; *) pkgs+=("$g") ;; esac
    done
    [[ "${#pkgs[@]}" -gt 0 ]] || return 0
    local -a nc
    nc_args nc
    pacman_mut -S --needed "${nc[@]}" "${pkgs[@]}" || die "pacman fallo"
    clean_pkg_cache
    local p
    for p in "${pkgs[@]}"; do
        [[ "$p" == -* ]] && continue
        cmd_export "$p" || true
    done
    update_desktop_db
    [[ -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    msg "instalado: $*"
}

# --- AUR (solo precompilados -bin; motor: paru; makepkg prohibe root,
# --- asi que se compila como usuario y se instala con sudo por separado)
cmd_install_aur() {
    [[ $# -ge 1 ]] || die "uso: $PROG install --aur <paquete...>"
    local _hp
    for _hp in "$@"; do [[ "$_hp" == -* ]] || break; done
    [[ "$_hp" == -* ]] && die "nada que instalar (¿solo flags?)"
    ensure_image
    level
    [[ "$_ARXY_LEVEL" == 2 ]] && die "AUR necesita nivel 1 (compilar exige user namespaces); en nivel 2 solo paquetes oficiales"
    ensure_aur_env
    local p f failed=()
    for p in "$@"; do
        [[ "$p" == -* ]] && continue
        f="$(aur_build "$p")"
        if [[ -z "${f:-}" || ! -f "$f" ]]; then
            msg "error: fallo al construir $p (sigo con el resto)"
            failed+=("$p")
            continue
        fi
        if ! as_root "$SELF" __install-file "$f"; then
            msg "error: fallo al instalar $p (sigo con el resto)"
            failed+=("$p")
            continue
        fi
        # Exito: el workdir ya no sirve (el .pkg esta instalado). En fallo se
        # conserva para depurar. Charset validado: $p podria escapar de aur/.
        [[ "$p" =~ ^[a-zA-Z0-9@._+-]+$ ]] && rm -rf "${ARXY_BUILD:?}/aur/$p" 2>/dev/null || true
    done
    if [[ "${#failed[@]}" -gt 0 ]]; then
        die "fallaron: ${failed[*]}"
    fi
    # Hook como usuario sin $ARXY_DATA escribible: salto silencioso (el proximo
    # install/update como root ya cubre todo /usr; avisar aqui seria ruido).
    [[ -w "$ARXY_DATA" && -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    msg "instalado (AUR): $*"
}

# Dir de build + herramientas makepkg + paru (si funciona). Corre como usuario.
# NOTA (2026-09): paru 2.1.0 enlaza libalpm.so.15 y Arch ya va por .16, asi
# que esta roto en todo Arch hasta que upstream publique release. El flujo
# usa git+RPC mientras tanto y adopta paru solo si responde (--version OK).
ensure_aur_env() {
    [[ -d "$ARXY_BUILD" ]] || die "falta $ARXY_BUILD: ejecuta 'sudo $PROG setup' para crearlo"
    # Herramientas de build: las que falten se instalan solas (una vez).
    # strip vive en binutils (nombre distinto al binario).
    local t missing_tools=()
    for t in fakeroot strip git curl pkgconf patch debugedit jq; do
        in_sys "/usr/bin/$t" --version >/dev/null 2>&1 || {
            [[ "$t" == "strip" ]] && missing_tools+=("binutils") || missing_tools+=("$t")
        }
    done
    # makepkg viene con pacman (siempre presente si la imagen es valida).
    in_sys /usr/bin/makepkg --version >/dev/null 2>&1 || \
        die "imagen rota: sin makepkg"
    if [[ "${#missing_tools[@]}" -gt 0 ]]; then
        msg "herramientas AUR que faltan: ${missing_tools[*]}" >&2
        as_root "$SELF" install "${missing_tools[@]}" >&2 || \
            die "no pude instalar herramientas AUR"
    fi
    if in_sys /usr/bin/paru --version >/dev/null 2>&1; then
        HAVE_PARU=1
    else
        HAVE_PARU=
        msg "aviso: paru no usable (roto con pacman 7.1 hasta nuevo release); usando git+RPC"
    fi
}

# Descarga el PKGBUILD con paru (-G) y compila con makepkg.
# Imprime la ruta del .pkg.tar.zst resultante (en el host).
# OJO: todo el ruido del build va a stderr; por stdout SOLO la ruta final,
# porque el llamador captura con f="$(aur_build ...)" (un subshell).
aur_build() { # <pkg> -> ruta paquete construido
    local pkg="$1" f
    local work_host="$ARXY_BUILD/aur/$pkg" work_ns="$NS_BUILD/aur/$pkg"
    rm -rf "$work_host"
    mkdir -p "$ARXY_BUILD/aur" || die "no puedo escribir en $ARXY_BUILD"
    # OJO: dentro del namespace solo existe la ruta $work_ns ($work_host es del host).
    if [[ -n "${HAVE_PARU:-}" ]]; then
        in_bwrap /usr/bin/paru --noconfirm -G "$pkg" "$work_ns" >&2 2>/dev/null || \
        in_bwrap /usr/bin/git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$work_ns" >&2 || \
            die "no existe en AUR: $pkg (revisa el nombre con '$PROG search-aur $pkg')"
    else
        in_bwrap /usr/bin/git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$work_ns" >&2 || \
            die "no existe en AUR: $pkg (revisa el nombre con '$PROG search-aur $pkg')"
    fi
    # makedepends/depends del AUR (los -bin casi siempre piden cosas
    # oficiales sueltas como gcc): se instalan solos con el flujo oficial
    # antes de compilar (makepkg los exige presentes; pacman -U los
    # traeria igual justo despues, asi que no se instala nada de mas).
    if [[ -f "$work_host/.SRCINFO" ]]; then
        local md missing=() d selfpkgs
        md="$(grep -E '^[[:space:]]*(makedepends?|depends?) =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/^[^=]*=[[:space:]]*//' | sort -u || true)"
        # Subpaquetes del mismo pkgbase (ej. bcompare -> bcompare-kde5) no
        # estan en repos: se excluyen, makepkg/pacman arbitran el resto.
        selfpkgs="$(grep -E '^[[:space:]]*pkgname =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/.*=[[:space:]]*//' | sort -u || true)"
        for d in $md; do
            d="${d%%[<>=]*}" # quita restricciones de version (gcc>=13 -> gcc)
            [[ -z "$d" ]] && continue
            grep -qxF "$d" <<<"$selfpkgs" 2>/dev/null && continue
            in_bwrap /usr/bin/pacman -Q "$d" >/dev/null 2>&1 || missing+=("$d")
        done
        if [[ "${#missing[@]}" -gt 0 ]]; then
            # OJO: esto corre dentro de f="$(aur_build ...)": todo a stderr
            # o el stdout (ruta del .pkg) se contamina y el install falla.
            msg "deps de $pkg: ${missing[*]}" >&2
            as_root "$SELF" install "${missing[@]}" >&2 || \
                msg "aviso: alguna dep no esta en repos oficiales; sigo y que decida makepkg" >&2
        fi
    fi
    # Precompilados -bin: el split de debug (gdb) es inutil y pesado;
    # se compila con una copia del makepkg.conf sin debug ni lto.
    cp "$ARXY_ROOT/etc/makepkg.conf" "$work_host/makepkg-arxy.conf" 2>/dev/null || \
        die "falta /etc/makepkg.conf en la imagen"
    printf '%s\n' 'OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)' \
        >> "$work_host/makepkg-arxy.conf"
    # Los .deb/.rpm de los -bin traen ficheros de root:0 y bsdtar intenta
    # chown dentro del userns (EINVAL fatal). Shim que lo desactiva solo
    # durante este build (el paquete final lo crea makepkg igual).
    mkdir -p "$work_host/bin"
    # Shims: los .deb/.rpm de los -bin traen ficheros de root:0 y tanto
    # bsdtar como tar intentan chown dentro del userns (EINVAL fatal).
    # Se desactivan solo durante este build. El de bsdtar ademas normaliza
    # llamadas estilo viejo ('xf f' sin guion, tipicas en PKGBUILDs): con
    # guion la 'f' se come la siguiente letra ('-xfv' abre 'v'), asi que se
    # separa la operacion y la 'f' va justo antes del fichero (pear-desktop).
    cat > "$work_host/bin/bsdtar" <<'SHIM'
#!/bin/sh
case "$1" in
  -*) exec /usr/bin/bsdtar --no-same-owner "$@" ;;
  [xcrtu]*)
    b="$1"; shift; op="${b%"${b#?}"}"; rest="${b#?}"
    case "$rest" in
      *f*) rest="$(printf '%s' "$rest" | tr -d 'f')"
           if [ -n "$rest" ]; then set -- "-$op" "-$rest" -f "$@";
           else set -- "-$op" -f "$@"; fi ;;
      *) if [ -n "$rest" ]; then set -- "-$op" "-$rest" "$@";
         else set -- "-$op" "$@"; fi ;;
    esac
    exec /usr/bin/bsdtar --no-same-owner "$@" ;;
  *) exec /usr/bin/bsdtar "$@" ;;
esac
SHIM
    # (GNU tar no admite nada antes de la palabra de operacion estilo
    # viejo, asi que va por delante solo si $1 ya empieza por '-'.)
    cat > "$work_host/bin/tar" <<'SHIM'
#!/bin/sh
case "$1" in
  -*) exec /usr/bin/tar --no-same-owner "$@" ;;
  *) exec /usr/bin/tar "$@" --no-same-owner ;;
esac
SHIM
    # Idem para cp: 'cp -a' sobre symlinks intenta lchown bajo fakeroot
    # (EINVAL fatal en userns). Se añade --no-preserve=ownership salvo que
    # el PKGBUILD ya mencione preserve (se respeta su criterio). OJO: va
    # POSPUESTO porque '-a' equivale a --preserve=all y pisa lo anterior.
    cat > "$work_host/bin/cp" <<'SHIM'
#!/bin/sh
for a in "$@"; do
  case "$a" in *preserve*) exec /usr/bin/cp "$@" ;; esac
done
for a in "$@"; do
  case "$a" in -*) case "$a" in *[ap]*) exec /usr/bin/cp "$@" --no-preserve=ownership ;; esac ;; esac
done
exec /usr/bin/cp "$@"
SHIM
    chmod +x "$work_host/bin/bsdtar" "$work_host/bin/tar" "$work_host/bin/cp"
    # Idem para install: 'install -o root -g root' (tipico en package() de
    # los -bin) intenta chown bajo fakeroot/userns (EINVAL fatal). Se pelan
    # -o/-g/--owner/--group en cualquier posicion; el resto intacto.
    cat > "$work_host/bin/install" <<'SHIM'
#!/bin/sh
# Filtro con centinela (rotar sin recentinela reordena/duplica).
sent="__shim_end_$$"
set -- "$@" "$sent"
while [ $# -gt 0 ] && [ "$1" != "$sent" ]; do
    case "$1" in
        -o|-g|--owner|--group) shift; { shift; } 2>/dev/null ;;
        -o?*|-g?*|--owner=*|--group=*) shift ;;
        *) set -- "$@" "$1"; shift ;;
    esac
done
[ "$1" = "$sent" ] && shift
exec /usr/bin/install "$@"
SHIM
    chmod +x "$work_host/bin/install"
    local build_ok=0
    # Sin --skippgpcheck si el usuario lo pide (por defecto se omite: los
    # keyservers caidos rompen builds que por lo demas estan bien).
    local pgp_args="--skippgpcheck"
    [[ -n "${ARXY_GPG_CHECK:-}" ]] && pgp_args=""
    # shellcheck disable=SC2086 # $pgp_args vacio debe desaparecer, no llegar como ""
    in_bwrap /usr/bin/bash -c "export PATH='$work_ns/bin:$PATH'; cd '$work_ns' && exec /usr/bin/makepkg --config '$work_ns/makepkg-arxy.conf' --noconfirm $pgp_args" >&2 && build_ok=1
    rm -rf "${work_host:?}/bin" # shims solo para este build: fuera siempre
    [[ $build_ok -eq 1 ]] || die "fallo al compilar $pkg"
    # Paquetes divididos (pkgbase con subpaquetes como bcompare-mate):
    # elegir el .pkg del nombre pedido, excluyendo a los hermanos. El glob
    # "$pkg-*" casaria tambien con "$pkg-<hermano>-*", asi que se filtra.
    local sibs sib cand ok
    sibs="$(grep -E '^[[:space:]]*pkgname =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/.*=[[:space:]]*//' | sort -u || true)"
    f=""
    while IFS= read -r cand; do
        ok=1
        for sib in $sibs; do
            [[ "$sib" == "$pkg" ]] && continue
            [[ "${cand##*/}" == "$sib"-* ]] && { ok=0; break; }
        done
        [[ $ok -eq 1 ]] && { f="$cand"; break; }
    done < <(ls -t "$work_host"/*.pkg.tar.zst 2>/dev/null || true)
    [[ -n "${f:-}" && -f "$f" ]] || die "makepkg no produjo paquete para $pkg"
    echo "$f"
}

# Paso privilegiado del flujo AUR (interno): instala un .pkg ya construido.
# Deriva el nombre con pacman -Qp para etiquetar el .desktop.
# OJO: el fichero llega con ruta del HOST; dentro del namespace el build
# dir se ve en $NS_BUILD, asi que hay que traducirla.
cmd_install_file() {
    need_root
    [[ $# -eq 1 && -f "${1:-}" ]] || die "uso interno: $PROG __install-file <paquete.pkg.tar.zst>"
    ensure_image
    local file="$1"
    [[ "$file" == "$ARXY_BUILD"/* ]] && file="$NS_BUILD${file#$ARXY_BUILD}"
    local -a nc
    nc_args nc
    pacman_mut -U --needed "${nc[@]}" "$file" || die "pacman -U fallo"
    clean_pkg_cache
    local name
    name="$(in_sys /usr/bin/pacman -Qp "$file" 2>/dev/null | awk '{print $1}')"
    [[ -n "${name:-}" ]] && { cmd_export "$name" || true; }
    update_desktop_db
}

cmd_remove() {
    need_root
    [[ $# -ge 1 ]] || die "uso: $PROG remove <paquete...>"
    ensure_image
    local -a nc
    nc_args nc
    pacman_mut -Rns "${nc[@]}" "$@" || die "pacman fallo"
    local p f
    for p in "$@"; do
        [[ "$p" == -* ]] && continue
        while IFS= read -r f; do
            rm -f "$f" && msg "lanzador borrado: ${f##*/}"
        done < <(grep -rlxF "X-Arxy-Pkg=$p" "$REAL_APPS"/arxy-*.desktop 2>/dev/null || true)
    done
    update_desktop_db
}

cmd_update() {
    need_root
    ensure_image
    local -a nc
    nc_args nc
    pacman_mut -Syu "${nc[@]}" || die "pacman fallo"
    clean_pkg_cache
    [[ -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    return 0 # [[...]] && ... final daria rc=1 con el hook desactivado
}

# Limpieza: dry-run por defecto (informa), --apply ejecuta.
# Solo borra regenerables (cache, builds, restos): jamas toca pacman.conf
# (IgnorePkg y cia sobreviven) ni el rootfs.
cmd_clean() { # [--apply]
    need_root
    ensure_image
    local apply=""
    [[ "${1:-}" == "--apply" ]] && apply=1
    [[ -z "${1:-}" || -n "$apply" ]] || die "uso: $PROG clean [--apply]"
    [[ -z "${2:-}" ]] || die "uso: $PROG clean [--apply]"
    local r p a d o f
    r="$(du -sh "$ARXY_ROOT" 2>/dev/null | cut -f1)"
    p="$(du -sh "$ARXY_ROOT/var/cache/pacman/pkg" 2>/dev/null | cut -f1)"
    a="-"; [[ -d "$ARXY_BUILD/aur" ]] && a="$(du -sh "$ARXY_BUILD/aur" 2>/dev/null | cut -f1)"
    d="-"
    for f in "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.*; do
        [[ -e "$f" ]] || continue
        d="$(du -shc "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.* 2>/dev/null | tail -1 | cut -f1)"
        break
    done
    o="-"; [[ -d "$ARXY_ROOT.old" ]] && o="$(du -sh "$ARXY_ROOT.old" 2>/dev/null | cut -f1)"
    msg "rootfs: $r en $ARXY_ROOT"
    msg "cache pacman: $p"
    msg "builds AUR: $a en $ARXY_BUILD/aur"
    msg "descargas huerfanas: $d"
    msg "rollback: $o en $ARXY_ROOT.old ('$PROG rollback' lo restaura; --apply lo borra)"
    if [[ -z "$apply" ]]; then
        msg "nada tocado (dry-run); '$PROG clean --apply' para limpiar"
        return 0
    fi
    rm -f "$ARXY_ROOT"/var/cache/pacman/pkg/* 2>/dev/null || true
    rm -rf "${ARXY_BUILD:?}/aur" 2>/dev/null || true
    for f in "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.*; do
        [[ -e "$f" ]] || continue
        rm -f "$f"
    done
    rm -rf "${ARXY_ROOT:?}.old" 2>/dev/null || true
    msg "limpieza hecha"
}

# Dedup por hardlinks: runtimes identicos entre apps (Electron) ocupan N
# veces su tamaño; linkearlos ahorra sin coste de lectura ni FUSE.
# pacman reemplaza ficheros al actualizar (no escribe in-place): el link se
# rompe solo y cada app vuelve a ser independiente. Es correcto.
# Si una app modificara un fichero linkeado afectaria a las demas; en /usr
# no ocurre en la practica (ver README).
# ponytail: nombres con \n quiebran el parseo (asumimos que /usr no los tiene); upgrade: find -print0 + cksum --zero.
do_dedup() { # [auto] : auto solo informa si ahorra >=10MB
    local auto="${1:-}"
    local start=$SECONDS saved=0 linked=0
    local work=""
    work="$(mktemp -d "$ARXY_DATA/.arxy-dedup.XXXXXX" 2>/dev/null)" || { msg "aviso: sin dedup (no hay temporal en $ARXY_DATA)"; return 0; }
    trap '[[ -n "${work:-}" ]] && rm -rf "$work"' RETURN EXIT
    # cksum POSIX (stat -c no existe en BSD, find -printf no existe en busybox):
    # CRC+tamaño en una pasada; sha256 solo confirma candidatos.
    # -links 1 = idempotente (lo ya linkeado se salta solo); -type f excluye symlinks.
    find "$ARXY_ROOT/usr" -type f -links 1 -exec cksum {} + 2>/dev/null | sort -k1,1n -k2,2n >"$work/all"
    awk '{print $1, $2}' "$work/all" | uniq -d >"$work/dups"
    local key size line h f first lasth
    while read -r key; do
        [[ -n "$key" ]] || continue
        size="${key#* }"
        awk -v k="$key" '$1" "$2 == k {sub(/^[^ ]+ [^ ]+ /,""); print}' "$work/all" >"$work/group"
        [[ -s "$work/group" ]] || continue # hueco de carrera (fichero borrado entre find y hash): sin entrada no hay xargs colgado
        first=""; lasth=""
        while IFS= read -r line; do
            h="${line%% *}"; f="${line#* }"; f="${f# }"; f="${f#\*}"
            if [[ "$h" == "$lasth" && -n "$first" ]]; then
                # cmp antes de ln: si algo cambio entre cksum y aqui, no linkear distintos.
                if cmp -s "$first" "$f" 2>/dev/null && ln -f "$first" "$f" 2>/dev/null; then
                    saved=$((saved + size)); linked=$((linked + 1))
                fi
            else
                first="$f"; lasth="$h"
            fi
        done < <(tr '\n' '\0' <"$work/group" | xargs -0 sha256sum 2>/dev/null | sort -k1,1)
    done <"$work/dups"
    local mb
    mb="$(awk -v b="$saved" 'BEGIN{printf "%.1f", b/1048576}')"
    if [[ -n "$auto" ]]; then
        [[ "$saved" -ge 10485760 ]] && msg "dedup: $linked archivos linkeados, ${mb} MB ahorrados"
    else
        msg "dedup: $linked archivos linkeados, ${mb} MB ahorrados en $((SECONDS - start))s"
    fi
    return 0 # hook best-effort: un dedup silencioso jamas debe fallar un install/update
}

cmd_dedup() {
    need_root
    ensure_image
    need_cmd find cksum sort awk uniq tr xargs sha256sum ln mktemp cmp
    do_dedup
}

