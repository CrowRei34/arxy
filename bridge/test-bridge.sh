#!/usr/bin/env bash
# test-bridge.sh — asserts de CONTENIDO para arxy-bridged (spike D1).
# Reglas del repo: set -u SIN pipefail; nada de `prod | grep -q` directo
# (SIGPIPE 141): se captura en variable y se grepea después.
set -u
cd "$(dirname "$0")" || exit 1

FAIL=0
TMPD=""
SRVPID=""
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
cleanup() {
    if test -n "$SRVPID"; then kill "$SRVPID" 2>/dev/null || true; fi
    if test -n "$TMPD"; then rm -rf "$TMPD"; fi
}
trap cleanup EXIT

command -v cc >/dev/null 2>&1 || { echo "FAIL: falta cc"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: falta python3"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/bridge-test.XXXXXX")"
SOCK="$TMPD/br.sock"
LOG="$TMPD/server.log"
BIN="$TMPD/arxy-bridged"

# --- 1. compila sin warnings ---
WARN="$TMPD/warnings.txt"
if cc -O2 -Wall -Wextra -o "$BIN" arxy-bridged.c 2>"$WARN"; then
    w="$(cat "$WARN")"
    if test -z "$w"; then pass "compila sin warnings"; else fail "warnings de cc: $w"; fi
else
    fail "no compila"
    cat "$WARN"
    exit 1
fi

# --- cliente del protocolo en stdlib python3 (se genera en TMP, no en el repo) ---
cat > "$TMPD/bc.py" <<'EOF'
import socket, struct, json, base64, sys
MAXF = 128 * 1024
def send_frame(s, obj):
    b = json.dumps(obj).encode()
    s.sendall(struct.pack('>I', len(b)) + b)
def read_frame(s):
    h = b''
    while len(h) < 4:
        c = s.recv(4 - len(h))
        if not c:
            return None
        h += c
    (n,) = struct.unpack('>I', h)
    if n == 0 or n > MAXF:
        return ('INVALID', n)
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            return None
        b += c
    return ('OK', json.loads(b.decode()))
mode, sock = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock)
def drain(s):
    data = b''
    while True:
        f = read_frame(s)
        if f is None:
            print('EOF')
            break
        k, v = f
        if k == 'INVALID':
            print('INVALID:%d' % v)
            break
        t = v.get('type')
        if t == 'output':
            data += base64.b64decode(v.get('data', ''))
        elif t == 'exit':
            print('OUT:' + base64.b64encode(data).decode())
            print('EXIT:%s' % v.get('code'))
            break
        elif t == 'error':
            print('ERROR:' + v.get('error', ''))
            break
        else:
            print('UNEXPECTED:' + json.dumps(v))
            break
if mode == 'req':
    send_frame(s, json.loads(sys.argv[3]))
    drain(s)
elif mode == 'rawjson':
    raw = sys.argv[3].encode()
    s.sendall(struct.pack('>I', len(raw)) + raw)
    drain(s)
elif mode == 'raw':
    s.sendall(struct.pack('>I', int(sys.argv[3])))
    try:
        f = read_frame(s)
    except socket.timeout:
        print('TIMEOUT')
    else:
        if f is None:
            print('EOF')
        elif f[0] == 'INVALID':
            print('INVALID:%d' % f[1])
        else:
            print('RESP:' + json.dumps(f[1]))
EOF

# --- arranca el servidor ---
"$BIN" --socket "$SOCK" --allowed-cmd /bin/echo --allowed-cmd /bin/sh >"$LOG" 2>&1 &
SRVPID=$!
ready=0
i=0
while test "$i" -lt 50; do
    if test -S "$SOCK"; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
done
if test "$ready" -ne 1; then
    fail "el servidor no arranca"
    cat "$LOG"
    exit 1
fi

# --- 2. comando permitido OK + contenido exacto ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["/bin/echo","hello-bridge-123"]}')"
exp_out="OUT:$(printf 'hello-bridge-123\n' | base64)"
l1="${out%%$'\n'*}"
l2="${out##*$'\n'}"
if test "$l1" = "$exp_out" && test "$l2" = "EXIT:0"; then
    pass "permitido OK con contenido exacto"
else
    fail "permitido: esperado [$exp_out + EXIT:0], obtenido [$out]"
fi

# --- 3. comando fuera de allowlist rechazado con error ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["/bin/ls","/"]}')"
if grep -q 'not allowed' <<<"$out"; then
    pass "fuera de allowlist rechazado con error"
else
    fail "allowlist: esperado error 'not allowed', obtenido [$out]"
fi

# --- 4. frame oversize rechazado ---
out="$(python3 "$TMPD/bc.py" raw "$SOCK" 200000)"
if grep -q 'too large' <<<"$out"; then
    pass "frame oversize rechazado"
else
    fail "oversize: esperado 'too large', obtenido [$out]"
fi

# --- 5. exit-code no-cero propagado (y el servidor sigue vivo tras el oversize) ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["/bin/sh","-c","exit 3"]}')"
if test "$out" = "OUT:
EXIT:3"; then
    pass "exit-code 3 propagado"
else
    fail "exit-code: esperado OUT vacío + EXIT:3, obtenido [$out]"
fi

# --- 6. permisos socket 0600 ---
st="$(stat -c %a "$SOCK")"
if test "$st" = "600"; then
    pass "socket 0600"
else
    fail "permisos socket: esperado 600, obtenido $st"
fi

# --- 7. strict JSON: clave desconocida rechazada ---
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" '{"type":"request","command":["/bin/echo","hi"],"extra":1}')"
if grep -q 'ERROR:bad request' <<<"$out"; then
    pass "clave desconocida rechazada"
else
    fail "strict-unknown: esperado ERROR:bad request, obtenido [$out]"
fi

# --- 8. strict JSON: basura tras '}' rechazada (antes se ejecutaba) ---
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" '{"type":"request","command":["/bin/echo","hi"]} TRAILING')"
if grep -q 'ERROR:bad request' <<<"$out"; then
    pass "basura tras } rechazada"
else
    fail "strict-trailing: esperado ERROR:bad request, obtenido [$out]"
fi

# --- 9. jskip tope: 63 niveles OK (llega a authorize), 65 error ---
deep63="$(python3 -c "print('{\"type\":\"request\",\"command\":[' + '\"x\",'*65 + '['*63 + '1' + ']'*63 + ']}')")"
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" "$deep63")"
if grep -q 'ERROR:too many arguments' <<<"$out"; then
    pass "63 niveles aceptados (authorize decide)"
else
    fail "depth-63: esperado ERROR:too many arguments, obtenido [$out]"
fi
deep65="$(python3 -c "print('{\"type\":\"request\",\"command\":[' + '\"x\",'*65 + '['*65 + '1' + ']'*65 + ']}')")"
out="$(timeout 15 python3 "$TMPD/bc.py" rawjson "$SOCK" "$deep65")"
if grep -q 'ERROR:bad request' <<<"$out"; then
    pass "65 niveles rechazados sin caerse"
else
    fail "depth-65: esperado ERROR:bad request, obtenido [$out]"
fi
# --- 9b. frontera exacta en 64 (semantica del limite: 64 OK, 65 fuera) ---
deep64="$(python3 -c "print('{\"type\":\"request\",\"command\":[' + '\"x\",'*65 + '['*64 + '1' + ']'*64 + ']}')")"
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" "$deep64")"
if grep -q 'ERROR:too many arguments' <<<"$out"; then
    pass "64 niveles exactos aceptados"
else
    fail "depth-64: esperado ERROR:too many arguments, obtenido [$out]"
fi

# --- 10. resolve_cmd: relativo con '/' rechazado ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["./bin/echo","hi"]}')"
if grep -q 'not allowed' <<<"$out"; then
    pass "./bin/echo rechazado"
else
    fail "resolve-dot: esperado not allowed, obtenido [$out]"
fi
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["bin/echo","hi"]}')"
if grep -q 'not allowed' <<<"$out"; then
    pass "bin/echo relativo rechazado"
else
    fail "resolve-rel: esperado not allowed, obtenido [$out]"
fi

# --- 11. resolve_cmd: nombre pelado con PATH limpio OK ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["echo","bare-ok-456"]}')"
exp_out="OUT:$(printf 'bare-ok-456\n' | base64)"
if test "${out%%$'\n'*}" = "$exp_out"; then
    pass "nombre pelado resuelve via PATH"
else
    fail "resolve-bare: esperado [$exp_out], obtenido [$out]"
fi

# --- 12. resolve_cmd: PATH con '.' fail-closed (reinicia daemon) ---
oldpid="$SRVPID"
kill "$SRVPID" 2>/dev/null || true
sleep 0.3
# Sin daemon viejo vivo (si siguiera, el test mentiria con el PATH anterior)
if kill -0 "$oldpid" 2>/dev/null; then
    fail "restart: el daemon viejo no murio"
else
    PATH=".:/usr/local/sbin:/usr/local/bin:/usr/bin:/sbin:/bin" "$BIN" --socket "$SOCK" --allowed-cmd /bin/echo --allowed-cmd /bin/sh >"$LOG" 2>&1 &
    SRVPID=$!
    sleep 0.5
    out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["echo","hi"]}')"
    if grep -q 'not allowed' <<<"$out"; then
        pass "PATH con . rechaza todo lookup"
    else
        fail "resolve-pathdot: esperado not allowed, obtenido [$out]"
    fi
fi
# daemon sano de vuelta (PATH limpio) para lo que sigue
kill "$SRVPID" 2>/dev/null || true
sleep 0.3
"$BIN" --socket "$SOCK" --allowed-cmd /bin/echo --allowed-cmd /bin/sh >"$LOG" 2>&1 &
SRVPID=$!
sleep 0.5

# --- 13. \u subrogados: par completo -> emoji UTF-8 ---
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" '{"type":"request","command":["/bin/echo","\ud83d\ude00"]}')"
exp_out="OUT:$(printf '\360\237\230\200\n' | base64)"
if test "${out%%$'\n'*}" = "$exp_out"; then
    pass "par subrogado combina a emoji"
else
    fail "unicode-pair: esperado [$exp_out], obtenido [$out]"
fi

# --- 14. \u subrogado alto huerfano rechazado ---
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" '{"type":"request","command":["/bin/echo","\ud83d"]}')"
if grep -q 'ERROR:bad request' <<<"$out"; then
    pass "alto huerfano rechazado"
else
    fail "unicode-hi: esperado ERROR:bad request, obtenido [$out]"
fi

# --- 15. \u subrogado bajo huerfano rechazado ---
out="$(python3 "$TMPD/bc.py" rawjson "$SOCK" '{"type":"request","command":["/bin/echo","\ude00"]}')"
if grep -q 'ERROR:bad request' <<<"$out"; then
    pass "bajo huerfano rechazado"
else
    fail "unicode-lo: esperado ERROR:bad request, obtenido [$out]"
fi

# --- 16. supervivencia: el daemon sigue vivo tras los rechazos ---
out="$(python3 "$TMPD/bc.py" req "$SOCK" '{"type":"request","command":["/bin/echo","alive-789"]}')"
exp_out="OUT:$(printf 'alive-789\n' | base64)"
if test "${out%%$'\n'*}" = "$exp_out"; then
    pass "daemon vivo tras rechazos"
else
    fail "liveness: esperado [$exp_out], obtenido [$out]"
fi

# --- 17-19. token del daemon (--token): sin token y mal token fuera ---
"$BIN" --socket "$TMPD/br2.sock" --token deadbeef1234 --allowed-cmd /bin/echo >"$TMPD/s2.log" 2>&1 &
SRV2=$!
sleep 0.5
out="$(python3 "$TMPD/bc.py" rawjson "$TMPD/br2.sock" '{"type":"request","command":["/bin/echo","hi"]}')"
if grep -q 'ERROR:bad token' <<<"$out"; then
    pass "sin token rechazado"
else
    fail "token-missing: esperado ERROR:bad token, obtenido [$out]"
fi
out="$(python3 "$TMPD/bc.py" rawjson "$TMPD/br2.sock" '{"type":"request","command":["/bin/echo","hi"],"token":"mal"}')"
if grep -q 'ERROR:bad token' <<<"$out"; then
    pass "token malo rechazado"
else
    fail "token-wrong: esperado ERROR:bad token, obtenido [$out]"
fi
out="$(python3 "$TMPD/bc.py" rawjson "$TMPD/br2.sock" '{"type":"request","command":["/bin/echo","tok-ok"],"token":"deadbeef1234"}')"
exp_out="OUT:$(printf 'tok-ok\n' | base64)"
if test "${out%%$'\n'*}" = "$exp_out"; then
    pass "token bueno ejecuta"
else
    fail "token-ok: esperado [$exp_out], obtenido [$out]"
fi
kill "$SRV2" 2>/dev/null || true
rm -f "$TMPD/br2.sock"

echo "----"
echo "FAIL=$FAIL"
if test "$FAIL" -ne 0; then
    echo "--- server.log ---"
    cat "$LOG"
    exit 1
fi
echo "ALL PASS"
