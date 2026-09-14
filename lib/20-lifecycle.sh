# --- setup: descarga + verifica + extrae la imagen (corre como root)
# version estructurado (Commit 5, format 1). El plano legacy (url=/date=) se
# acepta al leer y se migra al escribir. Sin jq: printf al emitir, grep al leer.
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
cmd_setup() {
    need_root
    need_cmd curl tar sha256sum zstd
    [[ -n "$ARXY_IMAGE_URL" ]] || die "ARXY_IMAGE_URL vacio. Edita $ARXY_SYS_CONF y pon la URL del tarball."
    mkdir -p "$ARXY_DATA"
    install -d -m1777 "$ARXY_BUILD" # compilacion AUR como usuario (makepkg prohibe root)
    install -d -m1777 "$ARXY_BUILD/aur" # idem para workdirs (si lo crea root, el usuario no puede escribir)
    local tmp sha_tmp img_sha=""
    tmp="$(mktemp "$ARXY_DATA/.arxy-dl.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    sha_tmp="$(mktemp "$ARXY_DATA/.arxy-sha.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' '$sha_tmp'" EXIT
    msg "descargando imagen..."
    curl -fL --retry 3 -o "$tmp" "$ARXY_IMAGE_URL" || die "no se pudo descargar la imagen (¿red? reintenta, o usa ARXY_IMAGE_URL=file:///ruta/al/tarball)"
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
            msg "aviso: sin ARXY_IMAGE_SHA256 ni .sha256 en el release, omitiendo verificacion"
        fi
    fi
    # Extraer a staging y validar ANTES de tocar lo instalado: setup atomico.
    # Si algo falla aqui, la instalacion actual sigue intacta.
    local stage="$ARXY_ROOT.new.$$"
    rm -rf "$stage"
    mkdir -p "$stage" || die "no pude crear staging en $stage (¿~1GB libre?)"
    msg "extrayendo en $stage..."
    if ! tar -xpf "$tmp" -C "$stage" 2>/dev/null; then
        # busybox-tar sin soporte zstd: descomprimir con zstd primero
        zstd -dc "$tmp" | tar -xp -C "$stage" || { rm -rf "$stage"; die "extraccion fallo"; }
    fi
    rm -f "$tmp" "$sha_tmp"
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
    _image_ok "$stage" || { rm -rf "$stage"; die "imagen corrupta: sin bash/pacman/arch-release"; }
    # Rotar: actual -> .old (rollback de una generacion), staging -> actual.
    rm -rf "$ARXY_ROOT.old" 2>/dev/null || true
    if [[ -d "$ARXY_ROOT" ]]; then
        mv "$ARXY_ROOT" "$ARXY_ROOT.old" || { rm -rf "$stage"; die "no pude apartar la instalacion actual"; }
    fi
    mv "$stage" "$ARXY_ROOT" || die "rotacion fallo (la anterior esta en $ARXY_ROOT.old)"
    # rc para la shell de nivel 2: resuelve en el subsistema lo que el host
    # no conoce (rutas horneadas; se regenera en cada setup).
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
    [[ -z "$img_sha" ]] && img_sha="$ARXY_IMAGE_SHA256"
    write_version "$ARXY_IMAGE_URL" "$img_sha" || die "no pude escribir version"
    # Copia dentro del rootfs: el rollback rota dirs pero no este fichero;
    # sin la copia, `version` mentiria tras un rollback (regla 3).
    mkdir -p "$ARXY_ROOT/var/lib/arxy" || die "no pude registrar version en el rootfs"
    cp -f "$ARXY_VERSION_FILE" "$ARXY_ROOT/var/lib/arxy/version" || die "no pude registrar version en el rootfs"
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
    # El version file vive fuera del root y el swap no lo mueve: restaurar
    # la copia que viajo dentro del rootfs (regla 3 tambien vale tras
    # rollback). Sin fuente (rootfs viejo o borrado a mano), se conserva
    # el actual sin avisar: uso manual fuera de contrato.
    if [[ -f "$ARXY_ROOT/var/lib/arxy/version" ]]; then
        cp -f "$ARXY_ROOT/var/lib/arxy/version" "$ARXY_VERSION_FILE" 2>/dev/null || \
            msg "aviso: rollback hecho pero no pude restaurar el version file"
    fi
    msg "rollback completo: imagen anterior restaurada en $ARXY_ROOT"
}

