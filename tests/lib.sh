#!/usr/bin/env bash
# tests/lib.sh — helpers compartidos de tests. Sourcear lo primero (tras HERE).
# ARXY_BIN: CLI bajo prueba. Default: el repo (src/arxy), NO el instalado:
# el instalado puede ir versiones por detras y da falsos rojos (3 veces esta
# sesion). El env sigue mandando para probar otro binario a proposito.
if [[ -z "${ARXY_BIN:-}" ]]; then
    ARXY_BIN="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../src/arxy" 2>/dev/null || echo "$(dirname "${BASH_SOURCE[0]}")/../src/arxy")"
    export ARXY_BIN
fi
