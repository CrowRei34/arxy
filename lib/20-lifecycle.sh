# --- setup: descarga + verifica + extrae la imagen (corre como root)
# version estructurado (Commit 5, format 1). El plano legacy (url=/date=) se
# acepta al leer y se migra al escribir. Sin jq: printf al emitir, grep al leer.
# --- setup atomico (Commit 6): invariante = SIGKILL en cualquier punto deja
# el sistema recuperable en la siguiente invocacion (ver recover_staging).
# Orden: descarga -> fsync -> sha -> staging -> fsync -> version DENTRO del
# staging -> fsync -> rotacion via .old.tmp.$$ -> rename (publica imagen+
# version juntas) -> fsync -> rotar .old -> fsync. Red (-Sy) al final: si
# muere ahi, el root ya es valido y el proximo setup reintenta.
data_sync() { # <paths...> : fsync best-effort; nunca falla setup
    # sync con operandos (coreutils) vacia los filesystems que los contienen
    # (syncfs); sin operandos o en busybox es global. Correcto en ambos
    # casos, mas caro en el segundo. Orden de llamada: fichero -> dir.
    sync "$@" 2>/dev/null || sync 2>/dev/null || true
}
_newest_first() { # <prefijo> : "$prefijo"* mas reciente primero (una linea)
    local p
    for p in "$1"*; do [[ -e "$p" ]] || continue
        printf '%s\t%s\n' "$(stat -c %Y "$p" 2>/dev/null || echo 0)" "$p"
    done | sort -rn | cut -f2-
}
staging_inventory() { # huerfanos de setup/rollback: "<accion>\t<path>"; pura
    # Una sola logica para recover_staging (aplica) y fix_probe (lista): un
    # fix en uno se refleja en el otro. Acciones: remove | recover-root
    # (R ausente) | replace-root (R invalido) | rotate-old (R valido).
    # Orden: .old.tmp estuvo VIVO (staging nunca); el mas reciente gana.
    local D="$ARXY_DATA" R="$ARXY_ROOT" p
    local r_exists=0 r_valid=0 filled_root=0 filled_old=0
    [[ -e "$R" ]] && r_exists=1
    image_ok 2>/dev/null && r_valid=1
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if (( ! r_exists && ! filled_root )) && _image_ok "$p"; then
            printf 'recover-root\t%s\n' "$p"; filled_root=1; r_exists=1; r_valid=1
        elif (( r_valid && ! filled_old )) && _image_ok "$p"; then
            printf 'rotate-old\t%s\n' "$p"; filled_old=1
        elif (( r_exists && ! r_valid && ! filled_root )) && _image_ok "$p"; then
            printf 'replace-root\t%s\n' "$p"; filled_root=1; r_valid=1
        else
            printf 'remove\t%s\n' "$p"
        fi
    done < <(_newest_first "$R.old.tmp.")
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if (( r_valid || filled_root )); then
            printf 'remove\t%s\n' "$p"
        elif (( ! filled_root )) && _image_ok "$p"; then
            if (( r_exists )); then
                printf 'replace-root\t%s\n' "$p"
            else
                printf 'recover-root\t%s\n' "$p"
            fi
            filled_root=1; r_exists=1; r_valid=1
        else
            printf 'remove\t%s\n' "$p"
        fi
    done < <(_newest_first "$R.new.")
    local s
    for s in "$D"/.image.partial.*; do
        [[ -e "$s" ]] || continue
        printf 'remove\t%s\n' "$s"
    done
    for s in "$R".swap.*; do
        [[ -e "$s" ]] || continue
        # Swap = root ex-vivo completo: nunca se borra si es lo mejor
        # disponible; solo sobra con un root valido ya en su sitio.
        if (( ! r_exists && ! filled_root )); then
            printf 'recover-root\t%s\n' "$s"; filled_root=1
        elif (( r_exists && ! r_valid && ! filled_root )); then
            printf 'replace-root\t%s\n' "$s"; filled_root=1
        else
            printf 'remove\t%s\n' "$s"
        fi
    done
    return 0
}
recover_staging() { # aplica staging_inventory; log a stderr; rc 0 siempre
    local acc path R="$ARXY_ROOT"
    while IFS=$'\t' read -r acc path; do
        [[ -n "${path:-}" ]] || continue
        case "$acc" in
            remove) if rm -rf "${path:?}" 2>/dev/null; then msg "recuperado: huerfano borrado de $path" >&2;
                else msg "aviso: no pude recuperar $path (huerfano no borrado)" >&2; fi ;;
            recover-root) if mv "$path" "$R" 2>/dev/null; then msg "recuperado: root restaurado de $path" >&2;
                else msg "aviso: no pude recuperar $path (root no restaurado)" >&2; fi ;;
            replace-root) rm -rf "${R:?}" 2>/dev/null || msg "aviso: no pude borrar root invalido $R" >&2
                if mv "$path" "$R" 2>/dev/null; then msg "recuperado: root invalido reemplazado de $path" >&2;
                else msg "aviso: no pude recuperar $path (root invalido no reemplazado)" >&2; fi ;;
            rotate-old) rm -rf "${R:?}.old" 2>/dev/null || msg "aviso: no pude borrar $R.old" >&2
                if mv "$path" "$R.old" 2>/dev/null; then msg "recuperado: rotado a .old de $path" >&2;
                else msg "aviso: no pude recuperar $path (no rotado a .old)" >&2; fi ;;
        esac
    done < <(staging_inventory)
    return 0
}
ensure_version() { # root valido sin version util: regenera; rc 0 siempre
    image_ok || return 0
    local f="$ARXY_VERSION_FILE" legacy="$ARXY_VERSION_LEGACY"
    if [[ -f "$f" ]] && { grep -q '"format": 1' "$f" 2>/dev/null || grep -q '^url=' "$f" 2>/dev/null; }; then
        [[ "$legacy" != "$f" ]] && rm -f "$legacy" 2>/dev/null || true
        return 0
    fi
    [[ -f "$f" ]] && msg "aviso: version ilegible, regenero" >&2
    # Sin permiso (usuario normal en root real): callar, setup como root
    # regenera. El mkdir distingue: si el puede crear, el write puede escribir.
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    write_version "${ARXY_IMAGE_URL:-}" "${ARXY_IMAGE_SHA256:-}" >/dev/null 2>&1 \
        || { msg "aviso: no pude regenerar version" >&2; return 0; }
    [[ "$legacy" != "$f" ]] && rm -f "$legacy" 2>/dev/null || true
    return 0
}
write_version() { # <image-url> <sha256> [created_at] : JSON atomico (0|1)
    local url="$1" sha="${2:-}" now="${3:-}" tmp
    [[ -z "$now" ]] && now="$(date -u +%FT%TZ 2>/dev/null || true)"
    tmp="$(mktemp "${ARXY_VERSION_FILE%/*}/.version.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 1
    {
        printf '{"format": 1'
        printf ', "image": %s' "$(json_str "$url")"
        printf ', "sha256": %s' "$(json_str_or_null "$sha")"
        printf ', "created_at": %s' "$(json_str_or_null "$now")"
        printf ', "arxy_version": %s}\n' "$(json_str "$ARXY_VERSION")"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$ARXY_VERSION_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}
version_field() { # <url|date> : valor (JSON o plano); rc 1 si falta
    local k="$1" f="$ARXY_VERSION_FILE" jk line
    [[ -f "$f" ]] || return 1
    case "$k" in url) jk=image ;; date) jk=created_at ;; *) return 1 ;; esac
    line="$(grep -m1 -oE "\"$jk\": \"[^\"]*\"" "$f" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then cut -d'"' -f4 <<<"$line"; return 0; fi
    grep -m1 "^$k=" "$f" 2>/dev/null | cut -d= -f2- || return 1
}
version_line() { # "url=... date=..." (ambos formatos; vacio si falta)
    local u d
    u="$(version_field url || true)"; d="$(version_field date || true)"
    echo "url=$u date=$d"
}
migrate_version_file() { # plano -> JSON atomico; idempotente; rc 0 (avisa)
    local f="$ARXY_VERSION_FILE"
    [[ -f "$f" ]] || return 0
    grep -q '"format": 1' "$f" 2>/dev/null && return 0
    local url="" date=""
    url="$(grep -m1 '^url=' "$f" 2>/dev/null | cut -d= -f2- || true)"
    date="$(grep -m1 '^date=' "$f" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -z "$url$date" ]]; then
        msg "aviso: version corrupto (ni JSON ni plano), no migro" >&2
        return 0
    fi
    if [[ ! -w "$f" && ! -w "${f%/*}" ]]; then
        return 0 # sin permiso (usuario normal): setup como root migrará; callar
    fi
    write_version "$url" "" "$date" 2>/dev/null || msg "aviso: no pude migrar version a JSON" >&2
    return 0
}

verify_signature() { # <tarball> <sig> <pub> -> 0 ok, 1 invalida, 2 sin minisign, 3 sin pub, 4 sin sig
    local tarball="$1" sig="$2" pub="$3"
    command -v minisign >/dev/null 2>&1 || return 2
    [[ -n "${pub:-}" && -f "$pub" ]] || return 3
    [[ -n "${sig:-}" && -f "$sig" && -s "$sig" ]] || return 4
    minisign -V -p "$pub" -m "$tarball" -x "$sig" >/dev/null 2>&1 || return 1
    return 0
}

enforce_signature_policy() { # <rc> : aplica ARXY_SIGNATURE_POLICY (die, warn o sigue)
    local rc="${1:-1}" pol="${ARXY_SIGNATURE_POLICY:-optional}"
    case "$pol" in
        required)
            [[ "$rc" == 0 ]] || die "firma minisign no valida (rc=$rc, policy=required)" ;;
        optional)
            case "$rc" in
                0) : ;;
                2) msg "aviso: sin minisign en el host, omitiendo verificacion de firma" >&2 ;;
                *) die "firma minisign no valida (rc=$rc, policy=optional)" ;;
            esac ;;
        off) : ;;
        *) die "ARXY_SIGNATURE_POLICY invalida: '$pol' (required|optional|off)" ;;
    esac
    return 0
}

sig_should_verify() { # 0 = descargar .minisig y verificar, 1 = omitir
    local pol="${ARXY_SIGNATURE_POLICY:-optional}"
    [[ "$pol" == off ]] && return 1
    [[ -n "${ARXY_IMAGE_SHA256:-}" ]] && return 1 # el pin ya ancla
    case "${ARXY_IMAGE_URL:-}" in http://*|https://*) return 0 ;; esac
    return 1 # file:// y demas: desarrollo local, sin release que firmarlo
}

sig_check_compat() { # die si pin + required (fail closed: required exige firma)
    [[ "${ARXY_SIGNATURE_POLICY:-optional}" == required && -n "${ARXY_IMAGE_SHA256:-}" ]] \
        || return 0
    die "ARXY_IMAGE_SHA256 pineado incompatible con ARXY_SIGNATURE_POLICY=required (el pin omite la firma; quita el pin o pon optional)"
}
cmd_setup() {
    need_root
    need_cmd curl tar sha256sum zstd
    [[ -n "$ARXY_IMAGE_URL" ]] || die "ARXY_IMAGE_URL vacio. Edita $ARXY_SYS_CONF y pon la URL del tarball."
    mkdir -p "$ARXY_DATA"
    install -d -m1777 "$ARXY_BUILD" # compilacion AUR como usuario (makepkg prohibe root)
    install -d -m1777 "$ARXY_BUILD/aur" # idem para workdirs (si lo crea root, el usuario no puede escribir)
    local tmp sha_tmp sig_tmp img_sha=""
    tmp="$(mktemp "$ARXY_DATA/.image.partial.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    sha_tmp="$(mktemp "$ARXY_DATA/.arxy-sha.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    sig_tmp="$(mktemp "$ARXY_DATA/.arxy-sig.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' '$sha_tmp' '$sig_tmp'" EXIT
    msg "descargando imagen..."
    curl -fL --retry 3 -o "$tmp" "$ARXY_IMAGE_URL" || die "no se pudo descargar la imagen (¿red? reintenta, o usa ARXY_IMAGE_URL=file:///ruta/al/tarball)"
    data_sync "$tmp" "$ARXY_DATA" # lo hasheado es lo que hay en disco
    if [[ -n "$ARXY_IMAGE_SHA256" ]]; then
        [[ "$(sha256sum <"$tmp" | awk '{print $1}')" == "$ARXY_IMAGE_SHA256" ]] || die "sha256 no coincide, abortando (¿descarga truncada? reintenta o revisa ARXY_IMAGE_SHA256)"
    else
        # Sin hash fijado: intentar el .sha256 publicado junto al tarball
        # en el release (arxy-image lo sube siempre). La URL puede traer
        # ?query/#fragmento: se recortan antes de añadir .sha256.
        # Si no existe, avisar y seguir sin verificar (historico).
        local sha_url="${ARXY_IMAGE_URL%%\?*}"
        sha_url="${sha_url%%\#*}.sha256"
        if curl -fLs --retry 2 -o "$sha_tmp" "$sha_url" 2>/dev/null && [[ -s "$sha_tmp" ]]; then
            local sha_rel
            sha_rel="$(grep -Eo '[0-9a-f]{64}' "$sha_tmp" | head -n 1)"
            [[ -n "$sha_rel" && "$(sha256sum <"$tmp" | awk '{print $1}')" == "$sha_rel" ]] \
                || die "sha256 del release no coincide, abortando (¿descarga truncada? reintenta)"
            msg "verificado contra .sha256 del release"
            img_sha="$sha_rel"
        else
            msg "aviso: sin ARXY_IMAGE_SHA256 ni .sha256 en el release, omitiendo verificacion" >&2
        fi
    fi
    # Firma minisign (Fase 7): segundo factor sobre sha256. Solo http(s) sin
    # pin (.minisig publicado junto al tarball; arxy-image lo firma en CI).
    # file:// es desarrollo local y el pin ya ancla: se omiten con aviso.
    local sig_policy="${ARXY_SIGNATURE_POLICY:-optional}" sig_verified=0
    case "$sig_policy" in
        required|optional|off) : ;;
        *) die "ARXY_SIGNATURE_POLICY invalida: '$sig_policy' (required|optional|off)" ;;
    esac
    sig_check_compat
    if sig_should_verify; then
        local sig_url="${ARXY_IMAGE_URL%%\?*}"
        sig_url="${sig_url%%\#*}.minisig"
        local sig_pub="${ARXY_SYS_CONF%/*}/arxy.pub" sig_rc=0
        if curl -fLs --retry 2 -o "$sig_tmp" "$sig_url" 2>/dev/null && [[ -s "$sig_tmp" ]]; then
            verify_signature "$tmp" "$sig_tmp" "$sig_pub" || sig_rc=$?
            enforce_signature_policy "$sig_rc"
            if [[ "$sig_rc" == 0 ]]; then
                msg "firma minisign valida"
                sig_verified=1
            fi
        else
            # Sin .minisig publicado: como "ausente" (rc 4).
            enforce_signature_policy 4
        fi
    elif [[ "$sig_policy" == off ]]; then
        msg "firmas: omitidas (ARXY_SIGNATURE_POLICY=off)"
    elif [[ -n "$ARXY_IMAGE_SHA256" ]]; then
        msg "firmas: omitidas (ARXY_IMAGE_SHA256 pineado ya ancla)"
    else
        msg "firmas: omitidas (URL no http(s), desarrollo local)"
    fi
    printf '%s' "$sig_verified" >"$ARXY_DATA/.arxy-sig" 2>/dev/null || true
    # Extraer a staging y validar ANTES de tocar lo instalado: setup atomico.
    # Si algo falla aqui, la instalacion actual sigue intacta.
    local stage="$ARXY_ROOT.new.$$"
    rm -rf "${stage:?}"
    mkdir -p "$stage" || die "no pude crear staging en $stage (¿~1GB libre?)"
    msg "extrayendo en $stage..."
    if ! tar -xpf "$tmp" -C "$stage" 2>/dev/null; then
        # busybox-tar sin soporte zstd: descomprimir con zstd primero
        zstd -dc "$tmp" | tar -xp -C "$stage" || { rm -rf "${stage:?}"; die "extraccion fallo"; }
    fi
    rm -f "$tmp" "$sha_tmp" "$sig_tmp"
    trap - EXIT
    # Destinos de bind que la imagen quiza no trae (bwrap exige que existan
    # dentro): /host y el build dir AUR. Sin esto TODO falla en bwrap.
    mkdir -p "$stage/host" "$stage$NS_BUILD"
    # Nodos /dev estaticos para chroot pelado (sin mounts gpg no funciona:
    # exige /dev/null+urandom). Best-effort: en hosts restringidos falla
    # mknod y se sigue (los binds de in_chroot lo cubren si hay privilegios).
    local dev name dtype maj min
    for dev in "null c 1 3" "zero c 1 5" "full c 1 7" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
        read -r name dtype maj min <<<"$dev"
        # Sin -m (no existe en chimerautils): mknod pelado + chmod.
        if [[ ! -e "$stage/dev/$name" ]]; then
            mknod "$stage/dev/$name" "$dtype" "$maj" "$min" 2>/dev/null && \
                chmod 666 "$stage/dev/$name" 2>/dev/null || true
        fi
    done
    # El usuario real debe resolverse dentro (getpwuid): Electron y varias
    # apps abortan si su uid no esta en /etc/passwd (pear-desktop:
    # uv_os_get_passwd ENOENT). Se copia su linea del host al staging
    # (virgen: sin riesgo de duplicados). Solo passwd+grupo primario.
    if [[ "$REAL_USER" != "root" ]]; then
        local _hu _hg _gid
        _hu="$(grep "^$REAL_USER:" /etc/passwd 2>/dev/null || true)"
        if [[ -n "$_hu" ]] && ! grep -q "^$REAL_USER:" "$stage/etc/passwd" 2>/dev/null; then
            printf '%s\n' "$_hu" >> "$stage/etc/passwd"
        fi
        _gid="$(id -g "$REAL_USER" 2>/dev/null || true)"
        _hg="$(getent group "${_gid:-}" 2>/dev/null || true)"
        if [[ -n "$_hg" ]] && ! grep -q "^${_hg%%:*}:" "$stage/etc/group" 2>/dev/null; then
            printf '%s\n' "$_hg" >> "$stage/etc/group"
        fi
    fi
    _image_ok "$stage" || { rm -rf "${stage:?}"; die "imagen corrupta: sin bash/pacman/arch-release"; }
    [[ -z "$img_sha" ]] && img_sha="$ARXY_IMAGE_SHA256"
    # version DENTRO del staging: nace con la imagen y el rename la publica
    # junta — nunca hay root nuevo con version vieja ni al reves. El subshell
    # contiene el override (sin save/restore); die ahi sale del subshell.
    mkdir -p "$stage/var/lib/arxy" || { rm -rf "${stage:?}"; die "no pude registrar version en el staging"; }
    ( export ARXY_VERSION_FILE="$stage/var/lib/arxy/version"
      write_version "$ARXY_IMAGE_URL" "$img_sha" ) || { rm -rf "${stage:?}"; die "no pude escribir version"; }
    data_sync "$stage" "$ARXY_DATA"
    # rc para la shell de nivel 2: resuelve en el subsistema lo que el host
    # no conoce (rutas horneadas; se regenera en cada setup). Antes del
    # rename: su contenido no depende de que root este publicado.
    {
        echo "# generado por '$PROG setup' — no editar"
        echo 'command_not_found_handle() {'
        echo "    if [[ -x \"$ARXY_ROOT/usr/bin/\$1\" ]]; then"
        echo "        \"$LD_LINUX\" --library-path \"$ARXY_LIBPATH\" \"$ARXY_ROOT/usr/bin/\$1\" \"\${@:2}\""
        echo '        return $?'
        echo '    fi'
        echo '    echo "bash: $1: orden no encontrada" >&2'
        echo '    return 127'
        echo '}'
        echo 'pacman() {'
        echo '    # En nivel 2 pacman opera sobre el subsistema, nunca sobre el host.'
        echo '    # Solo invocacion por nombre (/usr/bin/pacman directo no intercepta).'
        echo '    [[ -n "${ARXY_ALLOW_RAW_PACMAN:-}" ]] && { command pacman "$@"; return $?; }'
        echo '    local a'
        echo '    for a in "$@"; do'
        echo '        case "$a" in --root|--config|--dbpath)'
        echo '            command pacman "$@"; return $? ;; esac'
        echo '    done'
        echo '    for a in "$@"; do'
        echo '        case "$a" in -S|-Su*|-Sy*|-Sw*|-Sc*|-U*|-R*|-D*|-F*|--sync|--upgrade|--remove|--database)'
        echo '            echo "arxy (nivel 2): esa operacion escribe; usa arxy install/remove/update en el host" >&2'
        echo '            return 1 ;; esac'
        echo '    done'
        echo "    command pacman --root \"$ARXY_ROOT\" --config \"$ARXY_ROOT/etc/pacman.conf\" --dbpath \"$ARXY_ROOT/var/lib/pacman\" \"\$@\""
        echo '}'
    } > "$ARXY_DATA/level2-rc"
    data_sync "$ARXY_DATA"
    # Rotacion via .old.tmp.$$ : el rename publica imagen+version juntas
    # (atomico). Kill aqui deja .old.tmp.$$ y lo resuelve recover_staging.
    local old_tmp="$ARXY_ROOT.old.tmp.$$"
    rm -rf "${old_tmp:?}" 2>/dev/null || true
    if [[ -d "$ARXY_ROOT" ]]; then
        mv "$ARXY_ROOT" "$old_tmp" || { rm -rf "${stage:?}"; die "no pude apartar la instalacion actual"; }
    fi
    mv "$stage" "$ARXY_ROOT" || die "rotacion fallo (la anterior esta en $old_tmp; el proximo arranque la rescata)"
    data_sync "$ARXY_ROOT" "$ARXY_DATA"
    if [[ -d "$old_tmp" ]]; then
        rm -rf "${ARXY_ROOT:?}.old" 2>/dev/null || true
        mv "$old_tmp" "$ARXY_ROOT.old" || msg "aviso: no pude rotar $old_tmp a rollback (el proximo arranque lo rescata)" >&2
    fi
    data_sync "$ARXY_DATA"
    # Una sola verdad: el legacy fuera del root ya no se escribe ni se lee.
    [[ "$ARXY_VERSION_LEGACY" != "$ARXY_VERSION_FILE" ]] && rm -f "$ARXY_VERSION_LEGACY" 2>/dev/null || true
    # Perfil HW persistido (caché del mismo schema; doctor calcula fresco).
    # Antes del -Sy: describe lo instalado aunque falle la red. Nunca falla setup.
    write_hardware_json "$(emit_hardware_json 2>/dev/null || true)"
    msg "sincronizando bases de pacman..."
    pacman_mut -Sy || die "pacman -Sy fallo"
    msg "imagen lista en $ARXY_ROOT"
}

# Restaura la imagen anterior guardada por setup (una generacion).
cmd_rollback() {
    need_root
    [[ -d "$ARXY_ROOT.old" ]] || die "no hay rollback pendiente (falta ${ARXY_ROOT}.old)"
    if [[ -d "$ARXY_ROOT" ]]; then
        local aside="$ARXY_ROOT.swap.$$"
        mv "$ARXY_ROOT" "$aside" || die "no pude apartar la instalacion actual"
        mv "$ARXY_ROOT.old" "$ARXY_ROOT" || { mv "$aside" "$ARXY_ROOT"; die "rollback a medias: original restaurado"; }
        mv "$aside" "$ARXY_ROOT.old"
    else
        mv "$ARXY_ROOT.old" "$ARXY_ROOT" || die "rollback fallo"
    fi
    # version viaja DENTRO del root (Commit 6): el swap la rota sola, sin
    # copias. Si el root restaurado es pre-Commit 6 (sin version dentro),
    # ensure_version la regenera en el proximo uso.
    msg "rollback completo: imagen anterior restaurada en $ARXY_ROOT"
}

_gc_bytes() { # <path> : bytes en disco (0 si falta)
    local b
    b="$(du -sb "$1" 2>/dev/null | cut -f1)"
    echo "${b:-0}"
}

# Limpieza con JSON (Commit 8): informa siempre (exit 0); --apply purga.
# root.old VALIDO exige prompt tty (puede resucitarse) salvo --yes;
# root.old CORRUPTO se purga sin preguntar (no hay nada que recuperar).
cmd_gc() { # [--json] [--apply [--yes]]
    local use_json="" apply="" yes="" a
    for a in ${1+"$@"}; do
        case "$a" in
            --json) use_json=1 ;;
            --apply) apply=1 ;;
            --yes) yes=1 ;;
            *) die "uso: $PROG gc [--json] [--apply [--yes]]" ;;
        esac
    done
    [[ -n "$apply" ]] && need_root
    local pkgdir="$ARXY_ROOT/var/cache/pacman/pkg"
    local old="$ARXY_ROOT.old"
    local old_present=false old_valid=false old_size=0
    if [[ -d "$old" ]]; then
        old_present=true; old_size="$(_gc_bytes "$old")"
        _image_ok "$old" 2>/dev/null && old_valid=true
    fi
    local cache_size build_size
    cache_size="$(_gc_bytes "$pkgdir")"
    build_size="$(_gc_bytes "$ARXY_BUILD")"
    local st_n=0 st_size=0 _sacc st_path st_b
    while IFS=$'\t' read -r _sacc st_path; do
        [[ -n "${st_path:-}" ]] || continue
        st_n=$((st_n + 1))
        st_b="$(_gc_bytes "$st_path")"
        st_size=$((st_size + st_b))
    done < <(staging_inventory)
    local total=$((old_size + cache_size + build_size + st_size))
    local applied=false applied_bytes=0
    if [[ -n "$apply" ]]; then
        if [[ "$old_present" == true && "$old_valid" == true && -z "$yes" ]]; then
            [[ -t 0 ]] || die "gc --apply con rollback válido exige tty (repite con --yes)"
            local ans=""
            read -r -p "¿purgar $total bytes (incluye $old, recuperable con rollback)? [s/N] " ans
            if [[ "$ans" != [sS]* ]]; then msg "nada purgado"; return 0; fi
        elif (( total > 104857600 )) && [[ -z "$yes" ]]; then
            [[ -t 0 ]] || die "gc --apply de mas de 100 MB exige tty (repite con --yes)"
            local ans=""
            read -r -p "¿purgar $total bytes? [s/N] " ans
            if [[ "$ans" != [sS]* ]]; then msg "nada purgado"; return 0; fi
        fi
        recover_staging >/dev/null 2>&1
        [[ -d "$old" ]] && rm -rf "${old:?}" 2>/dev/null || true
        rm -f "$pkgdir"/* 2>/dev/null || true
        rm -rf "${ARXY_BUILD:?}" 2>/dev/null || true
        # gc --apply garantiza ARXY_BUILD existente (1777, como setup): el
        # siguiente build no depende de que setup haya corrido antes.
        install -d -m1777 "$ARXY_BUILD" 2>/dev/null || true
        local post s2=0 _acc
        post=$(( $(_gc_bytes "$old") + $(_gc_bytes "$pkgdir") + $(_gc_bytes "$ARXY_BUILD") ))
        while IFS=$'\t' read -r _acc st_path; do
            [[ -n "${st_path:-}" ]] || continue
            s2=$((s2 + $(_gc_bytes "$st_path")))
        done < <(staging_inventory)
        applied=true
        applied_bytes=$((total - post - s2))
        (( applied_bytes >= 0 )) || applied_bytes=0
    fi
    if [[ -n "$use_json" ]]; then
        local hint="nada que limpiar"
        if (( total > 0 )) && [[ "$old_present" == true ]]; then
            hint="arxy gc --apply libera $total bytes (incluye rollback recuperable)"
        elif (( total > 0 )); then
            hint="arxy gc --apply libera $total bytes"
        fi
        printf '{"format": 1'
        printf ', "root_old": {"present": %s, "valid": %s, "size": %s}' \
            "$(json_bool "$([[ "$old_present" == true ]] && echo 1 || echo 0)")" \
            "$(json_bool "$([[ "$old_valid" == true ]] && echo 1 || echo 0)")" "$old_size"
        printf ', "cache": {"path": %s, "size": %s}' "$(json_str "$pkgdir")" "$cache_size"
        printf ', "build": {"path": %s, "size": %s}' "$(json_str "$ARXY_BUILD")" "$build_size"
        printf ', "staging": {"entries": %s, "size": %s}' "$st_n" "$st_size"
        printf ', "total_bytes": %s' "$total"
        printf ', "hint": %s' "$(json_str "$hint")"
        printf ', "applied": %s, "applied_bytes": %s}\n' \
            "$(json_bool "$([[ "$applied" == true ]] && echo 1 || echo 0)")" "$applied_bytes"
        return 0
    fi
    msg "rollback: $old_size bytes en $old (presente: $old_present, válido: $old_valid)"
    msg "cache pacman: $cache_size bytes en $pkgdir"
    msg "builds: $build_size bytes en $ARXY_BUILD"
    msg "staging: $st_n entradas ($st_size bytes)"
    msg "total: $total bytes"
    if [[ -n "$apply" ]]; then
        msg "gc aplicado: $applied_bytes bytes liberados"
    else
        msg "nada tocado (dry-run); '$PROG gc --apply' para limpiar"
    fi
    return 0
}

