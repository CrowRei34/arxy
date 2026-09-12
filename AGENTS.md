# AGENTS.md — memoria operativa del proyecto Arxy

Arxy corre un subsistema Arch aislado: bwrap en L1 (sandbox minimo
de namespaces), `ld-linux`+chroot en L2 (sin namespaces). Rendimiento
nativo, sin sandbox de seguridad por app. Escribe en `/var/lib/arxy`
(rootfs, builds AUR, estado, `root.old` de rollback tras cada setup)
y `~/.local/share/applications/arxy-*.desktop` (lanzadores); lee
`~/.config/arxy/config` si existe. El instalador anade
`/usr/local/bin/arxy` (+ `axy`) y `/etc/arxy/arxy.conf`. Nada mas.

## Los 2 niveles

- **L1**: bwrap funcional. Binarios y pacman dentro del namespace.
- **L2**: sin user namespaces (hosts/containers restringidos, musl).
  Binarios via `ld-linux` del subsistema (`in_sys`), escrituras pacman
  via chroot con sudo (`pacman_mut`). L2 existe porque hay hosts donde
  bwrap no puede correr; `ARXY_LEVEL=1|2` lo fuerza (`level()`).

## La matrix

Vive en el repo `arxy-image`: `tests/matrix.sh` (+ `tests/README.md`
con que asserta cada check y por que). El CI la corre en cada build
como puerta de publicacion. Manual 5 distros pre-release:

```bash
docker cp <tarball> <c>:/image.tar.zst
docker cp src/arxy <c>:/usr/local/bin/arxy
docker cp <arxy-image>/tests/matrix.sh <c>:/matrix.sh
docker exec <c> /matrix.sh   # como root directo; a mano con sudo en host: sudo -E
```

Hardware real (Intel): `tests/test-hardware.sh` en este repo.

## Reglas (cada una cita el bug que la motivo; sin el porque, caducan)

1. Releer la funcion entera tras cada edit; probar el path tocado,
   no solo el que editaste.
   ← Fase 4: un edit en `cmd_remove` matcheo un bloque de `install`.

2. Antes de commit, correr matrix v2 con assertions de contenido,
   no solo rc.
   ← Fase 4: bugs mudos con rc=0 (L2 reads, AUR roto).

3. Tras `setup`, `arxy version --verbose | grep url=` y confirmar
   que es lo que crees que instalaste (fuente cruda si sospechas del
   CLI: `cat $ARXY_DATA/version`). El env puede haber sido pisado por
   sys-conf/user-conf sin aviso. La matrix no lo caza (containers sin
   conf); solo se ve en host real.
   ← Fase 5 bug 3: `ARXY_IMAGE_URL=file://` ignorado; todos los tests
   "en la mini" corrieron contra el release de 946M.

4. Los shims que envuelven binarios con `getopt` necesitan test propio
   (stub que ejercite el parseo real, no solo `--help`). `-f` se come
   la letra siguiente; `'xfv'` no es `-xfv`.
   ← Fase 5 bug 1: shim `bsdtar` rompia compilacion AUR ("Failed to open 'v'").

5. La matrix no caza bugs de sys-conf/user-conf (containers limpios);
   esos van en host real con conf presente.
   ← Fase 5, limite estructural.

6a. Con `pipefail`, `productor | grep -q` miente: `grep` cierra el
    pipe, el productor muere 141. Capturar en variable y grepear despues.
6b. `--version` no es sonda de presencia: `dbus-send --version` da rc=1
    siempre. Usar `test -x`.
    ← Fase 5, del propio `test-hardware.sh`.

7. Despues de tocar resolucion de paths o env, verificar **mtimes del
   estado vivo** (`$ARXY_DATA/*`). Los tests pasan con estado envenenado;
   solo las mtimes lo delatan.
   ← Fase 6 split-brain: `restore` tras derivar `ARXY_DATA/BUILD/VERSION_FILE`
   → setup aislado escribia `version` y `level2-rc` en `/var/lib/arxy` vivo.
   Reparado con `restore` como funcion tras cada `source`.

## Convenciones del repo `arxy` (el CLI)

- Un commit por tarea, mensaje con el porque (no solo el que).
- `src/arxy` y `packaging/void/arxy/files/arxy` van sincronizados
  (copia manual; el CI de Void empaqueta la copia).
- Puerta de lint: `bash -n` + `shellcheck -S warning` antes de commit.
- `pacman` siempre `--noconfirm` (via `nc_args`); sin tty no pregunta.
- Nunca `LD_LIBRARY_PATH` para el subsistema (solo `ld-linux`
  + `--library-path`); el del host lo envenenaria.

## Convenciones del repo `arxy-image` (la imagen + matrix)

- El CI reconstruye semanalmente y publica en el release `latest`;
  `tests/matrix.sh` es la puerta (si falla, no se publica).
- Cambios de tamano con numero medido (antes/despues en el commit).

## Decisiones enterradas (no resucitar sin contexto)

- **Imagen plana `.tar.zst`, sin DwarFS/SquashFS/FUSE**: complejidad y
  dependencias a cambio de nada que `zstd` no de.
- **`conty-minimal.sh`**: descartado (otra arquitectura, otro mantenimiento).
- **NVIDIA propietaria fuera de v1**: solo nouveau; el blob no es
  empaquetable ni testeable aqui.
- **Pin de hash mesa-mini**: no (toil semanal sin dato que lo pida).
- **`s` no es alias de `shell`**: `s=search` esta publicado; `sh` existe.
- **Hardlinks de `dedup`**: dos archivos identicos comparten inodo.
  Modificar uno afecta a los demas. En `/usr` no ocurre: pacman
  reemplaza, no escribe in-place (verificado en Fase 1, Q1).

## Estado actual

CLI `0.4.0` → tag `v1.0.0`. Imagen mini ~491MB (`IgnorePkg=mesa` hold).
Intel validado en hardware; AMD/NVIDIA via `install gpu-amd|gpu-nvidia`
disponible pero no probada en HW. AUR solo en nivel 1 (por diseno).
