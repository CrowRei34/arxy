# --- host-bridge: daemon arxy-bridged (Fase 5; binario endurecido Commit 14)
# Sin socket no hay nada: run_in solo monta si existe (degradacion limpia).
# Sin auto-arranque (Commit 16) ni allowlist real (Commit 16): sin
# --allowed-cmd no arranca (default: rechazar todo = no correr).
bridge_bin() { # ruta al daemon (override ARXY_BRIDGE_BIN para tests)
    [[ -n "${ARXY_BRIDGE_BIN:-}" ]] && { echo "$ARXY_BRIDGE_BIN"; return 0; }
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
bridge_pid_alive() { # <pidfile> : 0 si hay daemon vivo
    local pf="$1" pid=""
    [[ -f "$pf" ]] && pid="$(cat "$pf" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
cmd_host_bridge() { # [--daemon|--stop|--status] [--socket P] [--allowed-cmd B...]
    local mode="" sock="" bin=""
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
    local pidf="${sock%.sock}.pid"
    case "$mode" in
        --status)
            if [[ -S "$sock" ]]; then
                if bridge_pid_alive "$pidf"; then echo "activo: $sock (pid $(cat "$pidf"))";
                else echo "socket huerfano (sin pid vivo): $sock"; return 1; fi
            else echo "inactivo (sin socket: $sock)"; return 1; fi
            return 0 ;;
        --stop)
            if bridge_pid_alive "$pidf"; then
                kill "$(cat "$pidf")" 2>/dev/null || true
                rm -f "$pidf"
                echo "detenido"
            else
                rm -f "$pidf"
                die "sin daemon vivo (pidfile ausente o rancio)"
            fi
            return 0 ;;
        "") ;; # foreground: sigue abajo
        --daemon) ;;
    esac
    bin="$(bridge_bin)" || die "sin arxy-bridged (ejecuta 'make bridge' o instala con bridge)"
    [[ "${#allow[@]}" -gt 0 ]] || die "especifica al menos --allowed-cmd (sin allowlist no arranca)"
    local -a bargs=()
    local _a
    for _a in "${allow[@]}"; do bargs+=(--allowed-cmd "$_a"); done
    if [[ "$mode" == "--daemon" ]]; then
        bridge_pid_alive "$pidf" && die "ya corre (pid $(cat "$pidf"))"
        # Fondo simple (&): $! es el pid real (setsid bifurcaria y el
        # pidfile mentiria; systemd vendra en Commit 16 si hace falta).
        "$bin" --socket "$sock" "${bargs[@]}" >/dev/null 2>&1 &
        local pid=$! i=0
        while [[ $i -lt 50 && ! -S "$sock" ]]; do sleep 0.1; i=$((i+1)); done
        if [[ -S "$sock" ]]; then echo "$pid" > "$pidf"; echo "daemon pid $pid: $sock";
        else kill "$pid" 2>/dev/null || true; die "no levanto socket ($sock)"; fi
        return 0
    fi
    exec "$bin" --socket "$sock" "${bargs[@]}"
}
