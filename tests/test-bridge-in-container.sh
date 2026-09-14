#!/usr/bin/env bash
# test-bridge-in-container.sh — e2e bridge dentro del rootfs (Commit 15).
# Lento y con root+imagen: SKIP sin eso. XDG_RUNTIME_DIR aislado a TMP
# (daemon y run_in acuerdan el socket ahi). Requiere `make bridge`.
set -uo pipefail
FAIL=0
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: exige root"; exit 0; }
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
R="${ARXY_ROOT:-/tmp/bridge-root}"
[[ "$R" == /var/lib/arxy/root ]] && { echo "SKIP: exige ARXY_ROOT aislado"; exit 0; }
D="$(mktemp -d)"
export XDG_RUNTIME_DIR="$D" XDG_DATA_HOME="$D/xdg"
# Allowlist determinista (echo siempre resuelve; el default depende del host)
export ARXY_BRIDGE_ALLOWLIST="echo"
mkdir -p "$D/xdg"
# Hermetico: un daemon ambiente en el fallback (/tmp por UID) se montaria
# por diseno (esta vivo); el test exige entorno limpio, no lo ensucia.
if [[ -S "/tmp/arxy-bridge-$(id -u).sock" ]]; then
    echo "SKIP: daemon ambiente en fallback (stop primero)"
    rm -rf "$D"; exit 0
fi
command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
make -C "$HERE/.." bridge >/dev/null 2>&1 || { echo "FAIL: make bridge"; exit 1; }
ARXY_NO_BRIDGE=1 "$BIN" run /bin/true >/dev/null 2>&1 || { echo "SKIP: sin imagen en $R (setup primero)"; exit 0; }
# Probes sin bridge (evitan auto-arrancar antes que T0/T19).

# Orden: --stop ANTES de rm (sin pidfile/socket no hay a quien parar y el
# daemon quedaria huerfano).
trap '"$BIN" host-bridge --stop >/dev/null 2>&1 || true; rm -rf "$D"' EXIT
SOCK="$D/arxy-bridge.sock"

# Cliente minimo del protocolo (stdlib python3 del rootfs).
# Token desde el env si existe (daemon post-16 lo exige).
cat > "$D/client.py" <<'EOF'
import os, socket, struct, json, base64, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(os.environ['ARXY_BRIDGE_SOCKET'])
cmd = json.loads(sys.argv[1])
tok = os.environ.get('ARXY_BRIDGE_TOKEN')
if tok: cmd['token'] = tok
b = json.dumps(cmd).encode()
s.sendall(struct.pack('>I', len(b)) + b)
data = b''
while True:
    h = s.recv(4)
    if not h: print('EOF'); break
    (n,) = struct.unpack('>I', h)
    js = json.loads(s.recv(n).decode())
    t = js.get('type')
    if t == 'output': data += base64.b64decode(js.get('data', ''))
    elif t == 'exit': print('OUT:' + base64.b64encode(data).decode()); print('EXIT:%s' % js.get('code')); break
    elif t == 'error': print('ERROR:' + js.get('error', '')); break
EOF

t() { # t <nombre> <quiero> <comando...>: grep contenido (nunca solo rc)
    local name="$1" want="$2"; shift 3
    local out
    out="$("$@" 2>&1)" || true
    if grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want] en [$out])"; FAIL=$((FAIL+1)); fi
}

t "T0 sin daemon + NO_BRIDGE: sin env dentro" "unset" -- env ARXY_NO_BRIDGE=1 "$BIN" run sh -c 'echo ${ARXY_BRIDGE_SOCKET-unset}'

t "T19 sin binario: limpio sin error" "unset" -- env ARXY_BRIDGE_BIN=/nonexistent "$BIN" run sh -c 'echo ${ARXY_BRIDGE_SOCKET-unset}'

echo "== T16: auto-arranque al primer run =="
"$BIN" run /bin/true >/dev/null 2>&1
[[ -S "$SOCK" ]] && echo "PASS: T16 daemon auto-arrancado" || { echo "FAIL: T16 auto-arranque"; FAIL=$((FAIL+1)); }
t "T16 env dentro tras auto-arranque" "/run/arxy-bridge.sock" -- "$BIN" run sh -c 'echo ${ARXY_BRIDGE_SOCKET-unset}'
out="$("$BIN" run sh -c 'echo "T=${ARXY_BRIDGE_TOKEN:-ausente}"' 2>&1)"
grep -qE "T=[0-9a-f]{16,}" <<<"$out" && echo "PASS: T16 token dentro" || { echo "FAIL: T16 token dentro (tengo [$out])"; FAIL=$((FAIL+1)); }

echo "== T17: concurrentes, un solo daemon =="
"$BIN" run /bin/true >/dev/null 2>&1 & p1=$!
"$BIN" run /bin/true >/dev/null 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
[[ $r1 -eq 0 && $r2 -eq 0 ]] && echo "PASS: T17 ambos rc 0" || { echo "FAIL: T17 rc $r1/$r2"; FAIL=$((FAIL+1)); }
[[ "$(cat "$D/arxy-bridge.pid" 2>/dev/null)" != "" ]] && kill -0 "$(cat "$D/arxy-bridge.pid")" 2>/dev/null && echo "PASS: T17 un daemon vivo" || { echo "FAIL: T17 daemon"; FAIL=$((FAIL+1)); }

t "T1 echo roundtrip" "OUT:aGVsbG8K" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "T1 exit 0" "EXIT:0" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "T2 fuera de allowlist" "ERROR:command not allowed" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/ls","/"]}'

echo "== T20: sin token el daemon rechaza (al final: borra el token) =="
rm -f "$D/arxy-bridge.token" # run_in ya no inyecta (el daemon guarda el suyo)
out="$(env "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hi"]}' 2>&1)"
grep -q "ERROR:bad token" <<<"$out" && echo "PASS: T20 sin token" || { echo "FAIL: T20 sin token (tengo [$out])"; FAIL=$((FAIL+1)); }

echo "== T4: scrub VK_*/LIBGL dentro =="
out="$(VK_DRIVER_FILES=/bogus VK_ICD_FILENAMES=/bogus LIBGL_DRIVERS_PATH=/bogus "$BIN" run sh -c 'echo "${VK_DRIVER_FILES:-limpio} ${VK_ICD_FILENAMES:-limpio} ${LIBGL_DRIVERS_PATH:-limpio}"' 2>&1)"
if [[ "$out" == "limpio limpio limpio" ]]; then echo "PASS: T4 scrub";
else echo "FAIL: T4 scrub (tengo [$out])"; FAIL=$((FAIL+1)); fi

"$BIN" host-bridge --stop >/dev/null 2>&1 || { echo "FAIL: stop"; FAIL=$((FAIL+1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
