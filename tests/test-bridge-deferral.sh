#!/usr/bin/env bash
# test-bridge-deferral.sh — regresion del diferimiento C17 (OUT-OF-SCOPE.md §12):
# el token ambiente NO confina (mismo UID: nada distingue por env a `arxy run`
# de la app que corre dentro, asi que un auto-estrechamiento seria auto-otorgado).
# La frontera real es la allowlist del daemon y el parser C estricto rechaza
# claves desconocidas (bridge/arxy-bridged.c:352,360). Sin root ni HW.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
SOCK="$D/br.sock"
trap '"$BIN" host-bridge --stop --socket "$SOCK" >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: falta python3"; exit 0; }
cc -O2 -Wall -Wextra -Werror -o "$D/arxy-bridged" "$HERE/../bridge/arxy-bridged.c" 2>/dev/null || { echo "FAIL: no compila"; exit 1; }
export ARXY_BRIDGE_BIN="$D/arxy-bridged"

# Cliente minimo del protocolo (patron test-bridge-in-container.sh:37-57:
# token desde el env si existe).
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

t() { # t <nombre> <quiero> -- <comando...>: grep contenido (nunca solo rc)
    local name="$1" want="$2"; shift 3
    local out
    out="$("$@" 2>&1)" || true
    if grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want] en [$out])"; FAIL=$((FAIL+1)); fi
}

"$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo >/dev/null 2>&1 \
    || { echo "FAIL: daemon no arranca"; exit 1; }
export ARXY_BRIDGE_SOCKET="$SOCK"
ARXY_BRIDGE_TOKEN="$(cat "${SOCK%.sock}.token" 2>/dev/null || true)"
export ARXY_BRIDGE_TOKEN
[[ -n "${ARXY_BRIDGE_TOKEN:-}" ]] || { echo "FAIL: sin token del daemon"; exit 1; }

echo "== D1+D2: el mismo hijo con el mismo token =="
t "D1 echo OUT" "OUT:aGVsbG8K" -- python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "D1 echo EXIT" "EXIT:0" -- python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "D2 fuera de allowlist" "ERROR:command not allowed" -- python3 "$D/client.py" '{"type":"request","command":["/bin/ls","/"]}'

echo "== D3: no existe via de auto-estrechamiento (el estricto lo garantiza) =="
# type register con token BUENO (el cliente lo inyecta): ni asi hay via.
t "D3 register sin via" "ERROR:bad request" -- python3 "$D/client.py" '{"type":"register","token":"x"}'
# narrowedTo es clave desconocida para el parser C: fuera.
t "D3 narrowedTo sin via" "ERROR:bad request" -- python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hi"],"narrowedTo":["/bin/echo"]}'

echo "== D4: token copiado = identico poder (sin aislamiento por instancia) =="
tok_copy="$ARXY_BRIDGE_TOKEN"
t "D4 copia ejecuta" "EXIT:0" -- env ARXY_BRIDGE_TOKEN="$tok_copy" python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hello"]}'
t "D4 copia sin aislamiento" "ERROR:command not allowed" -- env ARXY_BRIDGE_TOKEN="$tok_copy" python3 "$D/client.py" '{"type":"request","command":["/bin/ls","/"]}'

echo "== D0: control negativo sin token =="
t "D0 sin token" "ERROR:bad token" -- env -u ARXY_BRIDGE_TOKEN python3 "$D/client.py" '{"type":"request","command":["/bin/echo","hi"]}'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
