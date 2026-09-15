# --- host-bridge: daemon arxy-bridged (Fase 5; binario endurecido Commit 14)
# Sin socket no hay nada: run_in solo monta si existe (degradacion limpia).
# Sin auto-arranque salvo que el binario exista y ARXY_NO_BRIDGE no este.
# Sin allowlist no arranca (default en bash; el C sigue fail-closed).
bridge_bin() { # ruta al daemon (override ARXY_BRIDGE_BIN para tests)
    if [[ -n "${ARXY_BRIDGE_BIN:-}" ]]; then
        [[ -x "$ARXY_BRIDGE_BIN" ]] || return 1
        echo "$ARXY_BRIDGE_BIN"; return 0
    fi
    local d
    d="$(dirname "$SELF")"
    [[ -x "$d/../lib/arxy/arxy-bridged" ]] && { echo "$d/../lib/arxy/arxy-bridged"; return 0; }
    [[ -x "$d/../bridge/arxy-bridged" ]] && { echo "$d/../bridge/arxy-bridged"; return 0; }
    return 1
}
bridge_sock_path() { # path del socket (XDG o /tmp por UID)
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then echo "$XDG_RUNTIME_DIR/arxy-bridge.sock"; return 0; fi
    echo "/tmp/arxy-bridge-$(id -u).sock"
}
bridge_pid_path() { # <sock> : pidfile al lado (misma base)
    echo "${1%.sock}.pid"
}
bridge_token_path() { # <sock> : token al lado (0600, del daemon)
    echo "${1%.sock}.token"
}
bridge_pid_alive() { # <pidfile> : 0 si hay daemon vivo Y es el nuestro
    local pf="$1" pid=""
    [[ -f "$pf" ]] && pid="$(cat "$pf" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # PID reutilizado por otro proceso: el cmdline delata
    grep -qa 'arxy-bridged' "/proc/$pid/cmdline" 2>/dev/null
}
bridge_default_allowlist() { # nombres (proton no es binario PATH: va por steam)
    printf '%s\n' steam wine gamescope mangohud xdg-open notify-send
}
bridge_resolve_allowlist() { # nombres -> paths absolutos (avisa y salta)
    # Busqueda manual en PATH (command -v devuelve builtins/funciones,
    # que no son ficheros ejecutables: 'echo' no resolveria nunca).
    # IFS acotado con local (el unset global destruia el IFS del llamador).
    local n d p
    local IFS=':'
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        p=""
        # shellcheck disable=SC2086 # split de PATH por : intencionado
        for d in ${PATH:-/usr/bin:/bin}; do
            [[ -n "$d" && -x "$d/$n" && ! -d "$d/$n" ]] && { p="$d/$n"; break; }
        done
        [[ -n "$p" ]] || { msg "aviso bridge: '$n' no resuelve, se omite" >&2; continue; }
        p="$(readlink -f "$p" 2>/dev/null || true)"
        [[ -n "$p" && -x "$p" ]] || { msg "aviso bridge: '$n' no ejecutable, se omite" >&2; continue; }
        printf '%s\n' "$p"
    done
    return 0
}
bridge_token_new() { # 64 hex de /dev/urandom (del daemon, Commit 17 lo refina)
    head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || true
}
ensure_bridge_daemon() { # arranca si no hay vivo (best-effort: nunca falla run)
    local bin sock pidf
    bin="$(bridge_bin)" || return 0 # sin binario: silencio (estado normal)
    [[ -z "${ARXY_NO_BRIDGE:-}" ]] || return 0
    sock="$(bridge_sock_path)"
    pidf="$(bridge_pid_path "$sock")"
    bridge_pid_alive "$pidf" && return 0
    command -v flock >/dev/null 2>&1 || return 0 # sin flock: no auto-arranque
    local lock="${pidf}.lock"
    exec 9>"$lock" 2>/dev/null || return 0
    flock -w 10 9 2>/dev/null || { exec 9>&-; return 0; } # otro arranca: el sigue sin socket esta vez
    bridge_pid_alive "$pidf" && { exec 9>&-; return 0; } # re-check tras lock
    # FD 9 se cierra ANTES del exec bwrap del llamador (si sobreviviera,
    # el sandbox heredaria el lock hasta que la app muera). El arranque
    # hijo no hereda el FD: cmd_host_bridge reabre lo que necesite.
    "$SELF" host-bridge --daemon >/dev/null 2>&1
    local rc=$?
    exec 9>&-
    return $rc
}
cmd_host_bridge() { # [--daemon|--stop|--status] [--socket P] [--allowed-cmd B...]
    local mode="" sock="" bin="" tokf=""
    local -a allow=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --daemon|--stop|--status) mode="$1"; shift ;;
            --socket) sock="${2:?falta path de --socket}"; shift 2 ;;
            --allowed-cmd) allow+=("${2:?falta binario de --allowed-cmd}"); shift 2 ;;
            -h|--help) echo "uso: $PROG host-bridge [--daemon|--stop|--status] [--socket P] [--allowed-cmd BIN...]"; return 0 ;;
            *) die "uso: $PROG host-bridge [--daemon|--stop|--status] [--socket P] [--allowed-cmd BIN...]" ;;
        esac
    done
    [[ -z "$sock" ]] && sock="$(bridge_sock_path)"
    local pidf
    pidf="$(bridge_pid_path "$sock")"
    case "$mode" in
        --status)
            if [[ -S "$sock" ]] && bridge_pid_alive "$pidf"; then
                echo "activo: $sock (pid $(cat "$pidf"))"; return 0
            fi
            echo "inactivo (buscado en $sock)"; return 1 ;;
        --stop)
            if bridge_pid_alive "$pidf"; then
                kill "$(cat "$pidf")" 2>/dev/null || true
                rm -f "$pidf" "${pidf}.lock"
                echo "detenido"
            else
                rm -f "$pidf"
                die "sin daemon vivo (buscado en $sock)"
            fi
            return 0 ;;
        "") ;; # foreground: sigue abajo
        --daemon) ;;
    esac
    bin="$(bridge_bin)" || die "sin arxy-bridged (ejecuta 'make bridge' o instala con bridge)"
    if [[ "${#allow[@]}" -eq 0 ]]; then
        # Config o default (nombres); el C recibe paths ya resueltos.
        # shellcheck disable=SC2086 # split intencionado de la lista
        if [[ -n "${ARXY_BRIDGE_ALLOWLIST:-}" ]]; then
            mapfile -t allow < <(printf '%s\n' ${ARXY_BRIDGE_ALLOWLIST} | bridge_resolve_allowlist)
        else
            mapfile -t allow < <(bridge_default_allowlist | bridge_resolve_allowlist)
        fi
    fi
    [[ "${#allow[@]}" -gt 0 ]] || die "allowlist vacia (nada resolvio; especifica --allowed-cmd)"
    local -a bargs=()
    local _a
    for _a in "${allow[@]}"; do bargs+=(--allowed-cmd "$_a"); done
    tokf="$(bridge_token_path "$sock")"
    if [[ "$mode" == "--daemon" ]]; then
        bridge_pid_alive "$pidf" && die "ya corre (pid $(cat "$pidf"))"
        local tok
        tok="$(bridge_token_new)"
        [[ -n "$tok" ]] || die "sin entropia para token (/dev/urandom)"
        # Token en argv (visible en ps): alcance UID por socket 0600 +
        # SO_PEERCRED; otro UID no puede usarlo aunque lo lea.
        # Fondo simple (&): $! es el pid real (setsid bifurcaria y el
        # pidfile mentiria). stderr a log efimero: si no levanta, el
        # motivo del C (p. ej. not executable) llega al die.
        local _blog
        _blog="$(mktemp "${sock%.sock}.blog.XXXXXX" 2>/dev/null || true)"
        "$bin" --socket "$sock" --token "$tok" "${bargs[@]}" >"$_blog" 2>&1 &
        local pid=$! i=0
        while [[ $i -lt 50 && ! -S "$sock" ]]; do sleep 0.1; i=$((i+1)); done
        if [[ -S "$sock" ]]; then
            echo "$pid" > "$pidf"; chmod 600 "$pidf"
            printf '%s' "$tok" > "$tokf"; chmod 600 "$tokf"
            rm -f "$_blog"
            echo "daemon pid $pid: $sock"
        else
            kill "$pid" 2>/dev/null || true
            local _why=""
            [[ -n "$_blog" && -f "$_blog" ]] && _why="$(tail -n 1 "$_blog" 2>/dev/null || true)"
            rm -f "$_blog"
            die "no levanto socket ($sock)${_why:+: $_why}"
        fi
        return 0
    fi
    # Foreground: token efimero solo para esta sesion (mismo archivo).
    local tok
    tok="$(bridge_token_new)"
    [[ -n "$tok" ]] || die "sin entropia para token (/dev/urandom)"
    printf '%s' "$tok" > "$tokf"; chmod 600 "$tokf"
    exec "$bin" --socket "$sock" --token "$tok" "${bargs[@]}"
}
