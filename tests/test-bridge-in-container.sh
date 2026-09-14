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
command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
make -C "$HERE/.." bridge >/dev/null 2>&1 || { echo "FAIL: make bridge"; exit 1; }
"$BIN" run /bin/true >/dev/null 2>&1 || { echo "SKIP: sin imagen en $R (setup primero)"; exit 0; }
"$BIN" run /usr/bin/python3 --version >/dev/null 2>&1 || { echo "SKIP: rootfs sin python3"; exit 0; }

D="$(mktemp -d)"
trap 'rm -rf "$D"; "$BIN" host-bridge --stop >/dev/null 2>&1 || true' EXIT
export XDG_RUNTIME_DIR="$D" XDG_DATA_HOME="$D/xdg"
mkdir -p "$D/xdg"
SOCK="$D/arxy-bridge.sock"

# Cliente minimo del protocolo (stdlib python3 del rootfs).
cat > "$D/client.py" <<'EOF'
import os, socket, struct, json, base64, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(os.environ['ARXY_BRIDGE_SOCKET'])
cmd = json.loads(sys.argv[1])
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

t "T0 sin daemon: sin env dentro" "unset" -- "$BIN" run sh -c 'echo ${ARXY_BRIDGE_SOCKET-unset}'

"$BIN" host-bridge --daemon --allowed-cmd /bin/echo >/dev/null 2>&1 || { echo "FAIL: no arranca daemon"; exit 1; }
t "T1 echo roundtrip" "OUT:aGVsbG8K" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "T1 exit 0" "EXIT:0" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "T2 fuera de allowlist" "ERROR:command not allowed" -- "$BIN" run /usr/bin/python3 "$D/client.py" '{"type":"request","command":["/bin/ls","/"]}'

echo "== T4: scrub VK_*/LIBGL dentro =="
out="$(VK_DRIVER_FILES=/bogus VK_ICD_FILENAMES=/bogus LIBGL_DRIVERS_PATH=/bogus "$BIN" run sh -c 'echo "${VK_DRIVER_FILES:-limpio} ${VK_ICD_FILENAMES:-limpio} ${LIBGL_DRIVERS_PATH:-limpio}"' 2>&1)"
if [[ "$out" == "limpio limpio limpio" ]]; then echo "PASS: T4 scrub";
else echo "FAIL: T4 scrub (tengo [$out])"; FAIL=$((FAIL+1)); fi

"$BIN" host-bridge --stop >/dev/null 2>&1 || { echo "FAIL: stop"; FAIL=$((FAIL+1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
