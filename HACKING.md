# HACKING.md — Contratos implícitos del código

Este documento lista los contratos arquitectónicos de `arxy` que no resultan evidentes de una lectura rápida pero gobiernan todo el ciclo de ejecución.

## 1. Memoización de `_ARXY_LEVEL`
La función `level()` determina si el entorno permite namespaces de usuario (Nivel 1) o no (Nivel 2). Tras su primera ejecución exitosa, exporta `_ARXY_LEVEL`. El resto de módulos confía ciegamente en esta variable y no vuelve a invocar `level()`.

## 2. Variables Globales Inyectadas
`00-head.sh` asienta las constantes del sistema: `ARXY_DATA`, `ARXY_ROOT`, `ARXY_BUILD`, y `REAL_APPS`. Los demás scripts asumen que estas variables existen, son absolutas y sus directorios son escribibles por su respectivo usuario (root vs $USER). No se re-verifican en cada función.

## 3. Lazy-Init con `ensure_image`
Casi cualquier comando expuesto al usuario que interactúe con el subsistema debe llamar a `ensure_image` antes de actuar. Esta función actúa como un inicializador perezoso que aborta con instrucciones claras si el contenedor no ha sido descargado (`setup`).

## 4. El Router y `cmd_*`
El módulo `zz-dispatch.sh` usa un mecanismo dinámico para mapear el comando introducido por el usuario (ej. `arxy run`) a su función Bash. Para que una función sea invocable públicamente, **debe** prefijarse con `cmd_` (ej. `cmd_run`). Los aliases (como `i` → `cmd_install`) están hardcodeados en este dispatch.
