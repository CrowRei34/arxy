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
    # Sin pipe directo: con pipefail, `prod | grep -q` miente (SIGPIPE
    # 141 cierra el productor antes; regla 5). Capturar y grepear después.
    local _qi
    _qi="$(run_pacman -Qi mesa 2>/dev/null || true)"
    grep -q '^Packager.*Unknown' <<<"$_qi"
}

# --- detecciones Fase 2 (contrato doctor --json / hardware.json, format 1) ---
# Schema mínimo (tipos): format=int, level=int, libc={kind:glibc|musl|unknown,
# version:str|null}, kernel={arch,releasestr|null}, userns/overlayfs_rootless/
# mount_setattr/seccomp/cgroupv2=bool, landlock={available,abi:int|null (null
# hasta Fase 5: bash no consulta la ABI)}, gpu={vendor:amd|nvidia|intel|unknown,
# driver:null (Fase 4), render_node:str|null}, nvidia={present,version|null,
# usable,reason}, kmods=[...ordenado], dev={dri:[...],nvidia:[...],
# fuse:str|null}, rootfs={path,present,version:date|null}, fixes_available=[...],
# fixes_applied=[]. Añadir campos OK; renombrar/quitar no (ver AGENTES.md).
# fixes_available hoy: [hold-mesa]; futuros: nvidia-align, musl-glibc-stack,
# gpu-full-stack (Fase 4). staging-cleanup (Commit 7) lista huerfanos de
# setup/rollback via staging_inventory (la misma que aplica recover_staging).
FIX_IDS=(hold-mesa nvidia-align musl-glibc-stack gpu-full-stack staging-cleanup)
# "fixes" es array de objetos {id,applicable,destructive,requires_root,reason,would_do,phase,opt_in?}; phase null = aplicable hoy.
# Salidas componibles sin jq: kmods en una línea (espacios), dev_nodes una
# ruta por línea, el resto valor único o vacío. Mocks (patrón ARXY_SYS_DRM_PATH):
#   ARXY_SYS_ROOT=""  prefijo de /proc y /sys (falso en tests)
#   ARXY_DEV_PATH="/dev"  dir de dispositivos (falso en tests)
#   ARXY_LIB_DIR="/lib"  dir de loaders (falso en tests)
#   ARXY_LIB64_DIR="/lib64"  idem 64 bits (falso en tests)
detect_libc() { # glibc|musl|unknown (ambos loaders -> decide ldd: el primario)
    local d="${ARXY_LIB_DIR:-/lib}" d64="${ARXY_LIB64_DIR:-/lib64}"
    local musl="" glibc="" m
    for m in "$d"/ld-musl-*.so.1; do [[ -e "$m" ]] && musl=1 && break; done
    [[ -f "$d64/ld-linux-x86-64.so.2" || -f "$d/ld-linux.so.2" ]] && glibc=1
    [[ -n "$musl" && -z "$glibc" ]] && { echo musl; return 0; }
    [[ -n "$glibc" && -z "$musl" ]] && { echo glibc; return 0; }
    local v=""
    if command -v ldd >/dev/null 2>&1; then
        v="$(ldd --version 2>&1 | head -n 1 || true)"
        case "$v" in *musl*) echo musl; return 0 ;; *GLIBC*|*"GNU libc"*) echo glibc; return 0 ;; esac
    fi
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
# Sonda pura de fixes (sin efectos): "estado|razon|would_do|opt".
# Estados: ok (nada que hacer) | todo (pendiente) | skip (no aplica).
# La usan el bloque de texto y el array "fixes" del JSON (una sola logica).
# Razon/would_do nunca traen '|' (separador).
fix_probe() { # <hold-mesa|nvidia-align|musl-glibc-stack|gpu-full-stack>
    local nv inst lc dri g
    case "$1" in
        hold-mesa)
            if image_ok && is_mesa_mini && ! grep -q '^IgnorePkg.*mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null; then
                echo "todo|un update traeria mesa oficial +170MB|añadir 'IgnorePkg = mesa' bajo [options] de pacman.conf|"
            else
                echo "ok|hold activo o innecesario||"
            fi
            ;;
        nvidia-align)
            nv="$(detect_nvidia_ver || true)"
            if [[ -z "$nv" ]]; then
                if [[ -n "$(detect_dev_nodes | grep nvidia || true)" ]]; then
                    echo "skip|nodos nvidia sin versión legible||"
                else
                    echo "skip|sin NVIDIA en host||"
                fi
                return 0
            fi
            if ! image_ok; then
                echo "todo|host $nv, sin rootfs verificado|instalar nvidia-utils=<host> en rootfs (Fase 4)|"
                return 0
            fi
            inst="$(run_pacman -Qi nvidia-utils 2>/dev/null | grep -m1 '^Version' | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
            if [[ -n "$inst" && "$inst" == "$nv" ]]; then
                echo "ok|utils $inst alineados con host||"
            else
                echo "todo|host $nv, rootfs ${inst:-sin nvidia-utils}|instalar nvidia-utils=<host> en rootfs (Fase 4)|"
            fi
            ;;
        musl-glibc-stack)
            lc="$(detect_libc)"
            dri="$(detect_dev_nodes | grep -E '/(card[0-9]+|renderD[0-9]+)$|nvidia' || true)"
            if [[ "$lc" != musl ]]; then echo "skip|libc $lc, no aplica||"; return 0; fi
            if [[ -z "$dri" ]]; then echo "skip|musl sin GPU expuesta||"; return 0; fi
            echo "todo|libc musl con GPU: el stack del host no sirve|instalar en rootfs: $(gpu_stack_pkgs | xargs)|"
            ;;
        gpu-full-stack)
            g="$(detect_gpu || true)"
            if [[ -z "$g" || "$g" == nvidia ]]; then echo "skip|lo cubre nvidia-align o no hay discreta||"; return 0; fi
            if ! image_ok; then echo "skip|sin rootfs verificado||"; return 0; fi
            if ! is_mesa_mini; then echo "ok|stack completo instalado||"; return 0; fi
            echo "todo|GPU $g con mesa-mini (sin LLVM)|instalar mesa completo + vulkan + lib32 (opt-in, Fase 4)|opt-in"
            ;;
        staging-cleanup)
            local inv="" n=0 wd="" w acc p
            inv="$(staging_inventory 2>/dev/null || true)"
            if [[ -z "$inv" ]]; then echo "skip|sin staging huerfano||"; return 0; fi
            n="$(printf '%s\n' "$inv" | grep -c . || true)"
            while IFS=$'\t' read -r acc p; do
                [[ -n "${p:-}" ]] || continue
                case "$acc" in
                    remove) w="borrar ${p##*/}" ;;
                    recover-root) w="recuperar ${p##*/} a root" ;;
                    replace-root) w="reemplazar root con ${p##*/}" ;;
                    rotate-old) w="rotar ${p##*/} a root.old" ;;
                    *) continue ;;
                esac
                wd+="$w; "
            done <<<"$inv"
            wd="${wd%; }"
            if (( n == 1 )); then
                echo "todo|1 entrada de staging huerfana|$wd|"
            else
                echo "todo|$n entradas de staging huerfanas|$wd|"
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

fixes_json() { # array "fixes" para --json (fixes_available sigue siendo [ids])
    local first=1 fid out st reason would opt app dest req phase wd
    printf '['
    for fid in "${FIX_IDS[@]}"; do
        out="$(fix_probe "$fid")"
        IFS='|' read -r st reason would opt <<<"$out"
        if [[ "$st" == skip ]]; then app=false; else app=true; fi
        dest=false; req=true
        case "$fid" in hold-mesa|staging-cleanup) phase=null ;; *) phase=4 ;; esac
        if [[ -n "$would" ]]; then wd="$(json_str "$would")"; else wd=""; fi
        if [[ "$first" == 1 ]]; then first=0; else printf ', '; fi
        printf '{"id": "%s", "applicable": %s, "destructive": %s, "requires_root": %s' "$fid" "$app" "$dest" "$req"
        printf ', "reason": %s' "$(json_str "$reason")"
        if [[ -n "$wd" ]]; then printf ', "would_do": [%s]' "$wd"; else printf ', "would_do": []'; fi
        printf ', "phase": %s' "$phase"
        [[ "$opt" == opt-in ]] && printf ', "opt_in": true'
        printf '}'
    done
    printf ']'
    return 0
}

# Fixes propuestos (Commit 4: informan y proponen; solo hold-mesa aplica).
# Contrato: `doctor --fix` informa (rc 0); `--fix --apply` exige root y
# aplica no-destructivos; `--fix --apply --confirm` + tty para destructivos.
# Ya no toca el `ok` de cmd_doctor: devuelve su propio rc (T20e).
doctor_fix() { # [--fix [--apply [--confirm]]]
    [[ "${1:-}" == "--fix" ]] || return 0
    local apply="" confirm="" fails=0
    [[ "${2:-}" == "--apply" ]] && apply=1
    [[ "${3:-}" == "--confirm" ]] && confirm=1
    if [[ -n "$apply" && "$(id -u)" -ne 0 ]]; then
        die "'$PROG doctor --fix --apply' necesita root (sin root solo informa)"
    fi
    local fid out st reason would opt
    echo "fixes available: ${#FIX_IDS[@]}"
    for fid in "${FIX_IDS[@]}"; do
        out="$(fix_probe "$fid")"
        IFS='|' read -r st reason would opt <<<"$out"
        case "$st" in
            ok) echo "  [ok]   $fid ($reason)" ;;
            todo)
                echo "  [todo] $fid ($reason)"
                [[ -n "$would" ]] && echo "         would_do: $would"
                if [[ "$fid" == hold-mesa && -n "$apply" ]]; then
                    if sed -i '/^\[options\]/a IgnorePkg   = mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null; then
                        echo "  [hecho] $fid aplicado"
                    else
                        echo "  [fallo] $fid no se pudo aplicar" >&2; fails=1
                    fi
                elif [[ "$fid" == staging-cleanup && -n "$apply" ]]; then
                    recover_staging >/dev/null
                    echo "  [hecho] $fid aplicado (ver 'recovered:' arriba)"
                elif [[ "$fid" == musl-glibc-stack && -n "$apply" ]]; then
                    local -a _sp
                    mapfile -t _sp < <(gpu_stack_pkgs)
                    if cmd_install "${_sp[@]}"; then
                        echo "  [hecho] $fid aplicado"
                    else
                        echo "  [fallo] $fid no se pudo aplicar" >&2; fails=1
                    fi
                elif [[ -n "$apply" ]]; then
                    echo "  [skip]  $fid (Fase 4, aún no implementado)"
                fi
                ;;
            *) echo "  [skip]  $fid ($reason)" ;;
        esac
    done
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
            msg "db.lck sin pacman visible: stale probable (destructivo: requiere --apply --confirm + tty)"
            if [[ -n "$apply" && -n "$confirm" ]]; then
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
    if [[ -z "$apply" ]]; then
        echo "informa sin aplicar: repite con --apply (root) para no-destructivos"
    fi
    return $fails
}

# --- doctor / version / ayuda
cmd_doctor() {
    local args=() a use_json=""
    for a in ${1+"$@"}; do
        if [[ "$a" == "--json" ]]; then use_json=1; else args+=("$a"); fi
    done
    if [[ -n "$use_json" ]]; then cmd_doctor_json "${args[@]+"${args[@]}"}"; return $?; fi
    case "${args[*]:-}" in
        ""|"--fix"|"--fix --apply"|"--fix --apply --confirm") ;;
        *) die "uso: $PROG doctor [--fix [--apply [--confirm]] [--json]]" ;;
    esac
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
    [[ -f "$ARXY_VERSION_FILE" ]] && msg "imagen: $(version_line)"
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
    doctor_fix "${args[@]+"${args[@]}"}"
    local frc=$?
    if [[ "${args[0]:-}" == "--fix" ]]; then return $frc; else return $ok; fi
}

cmd_version() {
    echo "$PROG $ARXY_VERSION"
    if [[ -f "$ARXY_VERSION_FILE" ]]; then
        version_line
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
    show_hardware_profile
}

# --- doctor --json (superficie pública versionada, format 1) ---
# Sin jq a propósito (cero dependencias nuevas): printf + escaping mínimo.
# Reglas: orden de campos fijo, arrays ordenados, avisos a stderr,
# stdout = un solo documento JSON, exit igual que doctor en texto.
json_str() { # <texto> -> "texto" con \ " y controles escapados
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
    printf '"%s"' "$s"
}
json_bool() { # 1|0 -> true|false
    if [[ "${1:-0}" == 1 ]]; then printf 'true'; else printf 'false'; fi
}
json_str_or_null() { # "" -> null (campos opcionales nunca se omiten)
    if [[ -z "${1:-}" ]]; then printf 'null'; else json_str "$1"; fi
}
json_arr() { # líneas por stdin -> ["a", "b"] (vacío -> [])
    local first=1 l
    printf '['
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ -z "$l" ]] && continue
        if [[ "$first" == 1 ]]; then first=0; else printf ', '; fi
        json_str "$l"
    done
    printf ']'
    return 0
}

kver_at_least() { # <mayor> <menor> : kernel >= X.Y (heurísticas documentadas)
    local k
    k="$(uname -r 2>/dev/null || true)"
    [[ "$k" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > $1 || (BASH_REMATCH[1] == $1 && BASH_REMATCH[2] >= $2) ))
}
probe_userns() { # 1 si hay namespaces sin root (misma prueba que doctor)
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then echo 1; return 0; fi
    if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / /bin/true 2>/dev/null; then echo 1; return 0; fi
    echo 0
}
probe_overlayfs() { # 1 si overlay rootless monta en userns (best-effort, sin restos)
    # El mount vive en el ns muerto del unshare: nunca cuelga en el host.
    # El RETURN trap cubre la muerte a mitad (solo queda un dir en /tmp).
    command -v unshare >/dev/null 2>&1 || { echo 0; return 0; }
    local t
    t="$(mktemp -d 2>/dev/null || true)"
    [[ -n "$t" && -d "$t" ]] || { echo 0; return 0; }
    trap 'rm -rf "$t"' RETURN
    mkdir -p "$t/l" "$t/u" "$t/w" "$t/m" 2>/dev/null || { echo 0; return 0; }
    local o="lowerdir=$t/l,upperdir=$t/u,workdir=$t/w,userxattr"
    if unshare -Urm mount -t overlay overlay -o "$o" "$t/m" 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
    return 0
}
probe_mount_setattr() { kver_at_least 5 12 && echo 1 || echo 0; } # existe desde 5.12
probe_seccomp() { kver_at_least 3 17 && echo 1 || echo 0; } # seccomp-bpf desde 3.17
probe_landlock() { kver_at_least 5 13 && echo 1 || echo 0; } # landlock desde 5.13
probe_cgroupv2() {
    command -v stat >/dev/null 2>&1 || { echo 0; return 0; }
    [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == cgroup2fs ]] && echo 1 || echo 0
}
detect_libc_ver() { # 2.44|1.2.5|"" (best-effort desde la salida de ldd)
    command -v ldd >/dev/null 2>&1 || return 1
    local v
    v="$(ldd --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
    [[ -n "$v" ]] && echo "$v" || return 1
}

cmd_doctor_json() { # [--fix|--apply] : se ignoran (solo se lista); JSON a stdout
    local a noted=""
    for a in ${1+"$@"}; do
        case "$a" in --fix|--apply) noted=1 ;; *) die "uso: $PROG doctor [--fix [--apply] | --json]" ;; esac
    done
    [[ -n "$noted" ]] && msg "nota: --json lista fixes sin aplicarlos" >&2
    emit_hardware_json
    return $?
}

# Núcleo reutilizable (doctor --json y hardware.json de setup): emite el
# JSON a stdout y devuelve el ok de doctor (para json=$(...) + rc).
emit_hardware_json() {
    local ok=0 c
    for c in bwrap curl tar zstd sha256sum awk sed grep mktemp su; do
        command -v "$c" >/dev/null 2>&1 || ok=1
    done
    level
    [[ "$_ARXY_LEVEL" == 1 || "$_ARXY_LEVEL" == 2 ]] || ok=1
    image_ok || ok=1
    [[ -n "$ARXY_IMAGE_URL" ]] || ok=1
    local lckind lcver karch krel
    lckind="$(detect_libc)"
    lcver="$(detect_libc_ver || true)"
    karch="$(uname -m 2>/dev/null || true)"
    krel="$(uname -r 2>/dev/null || true)"
    local gv rn
    gv="$(detect_gpu || true)"
    if [[ -z "$gv" ]]; then
        if [[ -n "$(detect_dev_nodes | grep -E '/(card[0-9]+|renderD[0-9]+)$' || true)" ]]; then gv=intel; else gv=unknown; fi
    fi
    rn="$(detect_dev_nodes | grep '/renderD' | sort | head -n 1 || true)"
    local nv nv_present=0 nv_usable=0 nv_reason="sin driver en host"
    nv="$(detect_nvidia_ver || true)"
    [[ -n "$nv" ]] && nv_present=1
    if [[ "$nv_present" == 0 ]] && [[ -n "$(detect_dev_nodes | grep nvidia || true)" ]]; then nv_present=1; fi
    if [[ "$nv_present" == 1 ]]; then
        if ! image_ok; then nv_reason="sin rootfs verificado";
        elif is_mesa_mini; then nv_reason="mesa-mini sin LLVM en rootfs (instala gpu-nvidia)";
        else nv_usable=1; nv_reason="stack completo"; fi
    fi
    local fixes="" fid fst
    for fid in "${FIX_IDS[@]}"; do
        fst="$(fix_probe "$fid" | cut -d'|' -f1)"
        [[ "$fst" != skip ]] && fixes+="$fid "
    done
    local rver=""
    [[ -f "$ARXY_VERSION_FILE" ]] && rver="$(version_field date || true)"
    printf '{"format": 1'
    printf ', "level": %s' "$_ARXY_LEVEL"
    printf ', "libc": {"kind": "%s", "version": %s}' "$lckind" "$(json_str_or_null "$lcver")"
    printf ', "kernel": {"arch": %s, "release": %s}' "$(json_str_or_null "$karch")" "$(json_str_or_null "$krel")"
    printf ', "userns": %s' "$(json_bool "$(probe_userns)")"
    printf ', "overlayfs_rootless": %s' "$(json_bool "$(probe_overlayfs)")"
    printf ', "mount_setattr": %s' "$(json_bool "$(probe_mount_setattr)")"
    printf ', "seccomp": %s' "$(json_bool "$(probe_seccomp)")"
    printf ', "mount_setattr_method": "kernel-version>=5.12"'
    printf ', "seccomp_method": "kernel-version>=3.17"'
    printf ', "landlock": {"available": %s, "abi": null}' "$(json_bool "$(probe_landlock)")"
    printf ', "gpu": {"vendor": "%s", "driver": null, "render_node": %s}' "$gv" "$(json_str_or_null "$rn")"
    printf ', "nvidia": {"present": %s, "version": %s, "usable": %s, "reason": %s}' \
        "$(json_bool "$nv_present")" "$(json_str_or_null "$nv")" "$(json_bool "$nv_usable")" "$(json_str "$nv_reason")"
    printf ', "kmods": %s' "$( { tr ' ' '\n' <<<"$(detect_kmods)" | grep . | sort || true; } | json_arr)"
    printf ', "dev": {"dri": %s' "$( { detect_dev_nodes | grep -E '/(card[0-9]+|renderD[0-9]+)$' | sort || true; } | json_arr)"
    printf ', "nvidia": %s' "$( { detect_dev_nodes | grep nvidia | sort || true; } | json_arr)"
    printf ', "fuse": %s}' "$(json_str_or_null "$(detect_dev_nodes | grep '/fuse$' | sort | head -n 1 || true)")"
    printf ', "rootfs": {"path": "%s", "present": %s, "version": %s}' \
        "$ARXY_ROOT" "$(json_bool "$(image_ok && echo 1 || echo 0)")" "$(json_str_or_null "$rver")"
    printf ', "fixes_available": %s' "$( { tr ' ' '\n' <<<"$fixes" | grep . | sort || true; } | json_arr)"
    printf ', "fixes": %s' "$(fixes_json)"
    printf ', "fixes_applied": []}\n'
    return $ok
}

# Perfil persistido (Commit 3): hardware.json es CACHÉ del mismo schema,
# escrita por setup; doctor --json siempre calcula fresco, nunca la lee.
write_hardware_json() { # <json> : atómico + solo-si-cambia; nunca falla setup
    local json="$1" f="$ARXY_DATA/hardware.json" tmp old
    [[ -n "$json" ]] || return 0
    mkdir -p "$ARXY_DATA" 2>/dev/null || { msg "aviso: sin $ARXY_DATA, omito hardware.json" >&2; return 0; }
    if [[ -f "$f" ]]; then
        old="$(cat "$f" 2>/dev/null || true)"
        [[ "$old" == "$json" ]] && return 0 # idéntico: preserva mtime (T13c)
    fi
    tmp="$(mktemp "$ARXY_DATA/.hardware.json.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || { msg "aviso: sin temporal para hardware.json" >&2; return 0; }
    printf '%s\n' "$json" >"$tmp" 2>/dev/null || { rm -f "$tmp"; msg "aviso: no pude escribir hardware.json" >&2; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    sync "$tmp" 2>/dev/null || sync 2>/dev/null || true # durabilidad best-effort
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; msg "aviso: no pude publicar hardware.json" >&2; return 0; }
    return 0
}

print_profile_block() { # <json> <origen> : bloque "hardware:" (grep, sin jq)
    local j="$1" src="$2" v
    echo "hardware: $src (format 1)"
    v="$(sed -n 's/.*"libc": {"kind": "\([^"]*\)", "version": \([^,}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  libc: ${v:-desconocida}"
    v="$(sed -n 's/.*"kernel": {"arch": \([^,}]*\), "release": \([^}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  kernel: ${v:-desconocido}"
    v="$(sed -n 's/.*"gpu": {"vendor": "\([^"]*\)", "driver": [^,]*, "render_node": \([^}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  gpu: ${v:-desconocida}"
    v="$(sed -n 's/.*"nvidia": {"present": \([a-z]*\), "version": \([^,]*\), "usable": \([a-z]*\), "reason": "\([^"]*\)"}.*/\1 \2 \3 \4/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"
    if [[ "$v" == false* ]]; then echo "  nvidia: no presente";
    else echo "  nvidia: ${v#* }"; fi
    v="$(sed -n 's/.*"kmods": \[\([^]]*\)\].*/\1/p' <<<"$j" | head -n 1 | tr -d '"[]' | tr ',' ' ' | tr -s ' ' || true)"
    echo "  kmods:${v:+ $v}"
    return 0
}

show_hardware_profile() { # bloque perfil en version --verbose (fichero o fresco)
    local f="$ARXY_DATA/hardware.json" j="" from=""
    if [[ -f "$f" ]] && j="$(cat "$f" 2>/dev/null)" && [[ "$j" == *'"format": 1'* ]]; then
        from="$f"
        local klive ksaved nlive nsaved
        klive="$(uname -r 2>/dev/null || true)"
        ksaved="$(sed -n 's/.*"kernel": {[^}]*"release": \([^,}]*\)}.*/\1/p' <<<"$j" | head -n 1 | tr -d '"' || true)"
        [[ -n "$klive" && -n "$ksaved" && "$klive" != "$ksaved" ]] && \
            msg "aviso: kernel actual ($klive) difiere del perfil ($ksaved)" >&2
        nlive="$(detect_nvidia_ver || true)"
        nsaved="$(sed -n 's/.*"nvidia": {[^}]*"version": \([^,}]*\)}.*/\1/p' <<<"$j" | head -n 1 | tr -d '"' || true)"
        [[ "$nlive" != "$nsaved" ]] && \
            msg "aviso: nvidia actual (${nlive:-ausente}) difiere del perfil (${nsaved:-ausente})" >&2
    else
        if [[ -f "$f" ]]; then
            msg "aviso: hardware.json corrupto o con otro format; perfil fresco en memoria" >&2
        else
            msg "aviso: sin hardware.json (lo crea setup); perfil fresco en memoria" >&2
        fi
        j="$(emit_hardware_json 2>/dev/null || true)"
        from="memoria"
        [[ -z "$j" ]] && { msg "aviso: no se pudo calcular el perfil" >&2; return 0; }
    fi
    print_profile_block "$j" "$from"
    return 0
}

