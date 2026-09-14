# AGENTS.md — arxy (CLI)

Arch conviviente en `/var/lib/arxy/root` (ficheros normales, sin
squashfs/FUSE), comparte `/home /tmp /run /dev` + GPU. **Sin sandbox
de seguridad** (compat-glibc, no aislamiento). Escribe solo en
`/var/lib/arxy` (rootfs, `root.old` de rollback, `version`, estado) y
`~/.local/share/applications/arxy-*.desktop`; lee `/etc/arxy/arxy.conf`
y `~/.config/arxy/config`. Precedencia: **env > user-conf > sys-conf**
(env congelado en `_restore_frozen`, `lib/00-head.sh:29`).

## Puerta antes de commit

```bash
make src/arxy && git diff --exit-code src/arxy   # D9: lib/ genera src/arxy byte-idéntico
bash -n lib/*.sh src/arxy install.sh && shellcheck -S warning src/arxy install.sh
cmp src/arxy packaging/void/arxy/files/arxy && cmp config/arxy.conf packaging/void/arxy/files/arxy.conf  # lo verifica lint.yml
```

- Un commit por tarea, mensaje con el porqué.
- `lib/*.sh` son canónicos (`src/arxy` es generado y commiteado porque el
  instalador lo lee del clon); `config/arxy.conf` canónico;
  `packaging/void/…/files/` son copias manuales para xbps.
- Flujo: editar solo lib/ → `make sync` (regenera + copia a packaging) →
  commitear todo junto (lint falla si algo va desfasado).
- Matrix con assertions de **contenido** (`grep`), nunca solo rc
  ← Fase 4: bugs mudos con rc=0 (lecturas L2, AUR roto).
- `pacman` siempre `--noconfirm` vía `nc_args`; nunca `LD_LIBRARY_PATH`
  (envenena al subsistema: solo `ld-linux --library-path`, y se hace
  `unset` explícito).

## Los 2 niveles

- **L1** (habitual): bwrap + user namespaces, todo dentro del namespace.
- **L2** (kernels hardened/containers/musl sin userns): `run` vía
  `ld-linux` del subsistema (`in_sys`), escrituras pacman vía chroot con
  sudo (`pacman_mut`). `ARXY_LEVEL=1|2` fuerza uno; `level()` lo detecta.
- AUR solo en L1 y solo `-bin` (nunca toolchains); `--skippgpcheck` por
  defecto (`ARXY_GPG_CHECK=1` lo exige).

## Invariantes del ciclo de vida

- SIGKILL en cualquier punto deja el sistema recuperable en la siguiente
  invocación (ver `recover_staging` en `lib/20-lifecycle.sh`).
- `version` vive dentro del root: el rename publica imagen+versión juntas;
  el rollback la rota sola (sin copias).

## Fase 4: decisiones (GPU real + arxy-gaming)

- Meta-paquete en AUR, no reinventar pacman: `arxy-gaming` (base: steam,
  proton-ge-custom-bin, wine, dxvk-bin, vkd3d, gamescope, mangohud,
  lib32-mesa, lib32-vulkan-*) + ramas `-nvidia` (nvidia-utils alineados
  con host), `-amd` (mesa, vulkan-radeon…), `-intel` (mesa, vulkan-intel…).
  `arxy install arxy-gaming` detecta vendor (`detect_gpu()`) y elige rama.
- musl: `--no-host-gpu` en `bwrap_base()`; stack gráfico completo DENTRO
  del rootfs (ya es Arch glibc); binds solo `/dev/dri*`, `/dev/nvidia*`,
  `/dev/fuse`, `/dev/ntsync`.
- NVIDIA en bash con `file -b` (ya es dependencia declarada del paquete);
  NUNCA parsear ELF a mano; fallback por path solo si `file` falla.
- Montaje solo en `run_in()` (run/shell; pacman via `in_bwrap` intacto).
  ICDs por `--ro-bind-data` desde FD (sin tmpdirs ni traps; requiere
  bwrap con `--ro-bind-data`). Sin NVIDIA, args identicos a antes.
- Mocks GPU (patrón `ARXY_SYS_DRM_PATH`, probativos: sin mock → vacío):
  `ARXY_SYS_ROOT` (reutilizado para `/proc/driver/nvidia` y
  `/sys/module/nvidia`; NO hay `ARXY_NVIDIA_SYSFS_PATH` separado),
  `ARXY_NVIDIA_LIB_ROOT` (`/usr/lib`), `ARXY_NVIDIA_LIB_ROOT64`
  (`/usr/lib64`), `ARXY_NVIDIA_LIB_ROOT32` (`/usr/lib32`),
  `ARXY_VULKAN_ICD_PATH` (`/usr/share/vulkan/icd.d`),
  `ARXY_EGL_PLATFORM_PATH` (`/usr/share/egl/egl_external_platform.d`).

## La matrix (repo hermano `arxy-image`)

Puerta de publicación: `tests/matrix.sh` (+ `tests/README.md`: qué
asserta cada check). El CI la corre en cada build; manual pre-release:

```bash
docker cp <tarball> <c>:/image.tar.zst
docker cp src/arxy <c>:/usr/local/bin/arxy
docker cp <arxy-image>/tests/matrix.sh <c>:/matrix.sh
docker exec <c> /matrix.sh   # root directo; en host con sudo: sudo -E
```

Vars: `MATRIX_IMAGE`, `ARXY_ROOT` (aislar rootfs), `MATRIX_WRITE2=1`
(escrituras L2, solo CI/host con montajes). Hardware real (Intel):
`./tests/test-hardware.sh` **en el host, nunca en container**.
Build imagen: `sudo -n PROFILE=arxy ./create-*.sh` (asignar tras sudo:
`PROFILE=x sudo…` pierde el env porque sudo lo limpia).

## Reglas (cada una cita el bug; sin el porqué, caducan)

1. Releer la función entera tras cada edit; probar el path tocado, no
   solo el editado ← Fase 4: un edit en `cmd_remove` matcheó `install`.
2. Tras `setup`, `arxy version --verbose | grep url=` (crudo:
   `cat /var/lib/arxy/version`): el env pudo ser pisado por una conf
   sin aviso; la matrix no lo caza (containers limpios)
   ← Fase 5: `ARXY_IMAGE_URL=file://` ignorado, tests contra el release.
3. Bugs de sys-conf/user-conf no van en matrix: solo en host real con
   conf presente ← límite estructural Fase 5.
4. Tras tocar paths/env, mirar **mtimes de `/var/lib/arxy/*`**: los tests
   pasan con estado envenenado ← Fase 6 split-brain (`_restore_frozen`
   debe correr ANTES de derivar `ARXY_DATA`).
5. Con `pipefail`, `prod | grep -q` miente (SIGPIPE 141): capturar en
   variable y grepear después. Presencia = `test -x`, nunca `--version`
   (`dbus-send --version` da rc=1 siempre) ← `test-hardware.sh`.
6. Shims con `getopt`: test propio con stub que ejercite el parseo real
   (`-f` se come la letra siguiente; `'xfv'` ≠ `-xfv`)
   ← Fase 5: shim `bsdtar` rompía AUR ("Failed to open 'v'").
7. `file://` no acepta espacios en la ruta
   ← 6.1: la matrix falló 21 checks por espacios en el path local.
8. L2 rompe asunciones de L1 sobre formato de output de herramientas
   (rutas prefijadas por `--root`, etc.). Todo path parsing en
   `pkg_desktops` y similares debe funcionar en ambas formas
   ← 6.5.5: `-Qlq` con `--root` devuelve `/var/lib/arxy/root/usr/…`;
   `grep ^/usr/` ciego en L2. En L1 pelado. Matrix L1 jamás lo vio.

**Cobertura pendiente post-v1.0.0:** la matrix no ejercita `export`
bajo L2 ni instala paquetes con `.desktop` en L2. El caso se validó
en el ciclo 6.5.5 a mano; endurecer la matrix es tarea de v1.0.x.
*← 3884404 se cazó por ciclo desde cero, no por CI.*

## No resucitar sin contexto

- Imagen plana `.tar.zst` (DwarFS/SquashFS descartados: complejidad sin
  ganancia sobre `zstd`); NVIDIA propietaria fuera de v1 (solo nouveau);
  `IgnorePkg=mesa` hold en la mini (quitarlo suma ~170MB).
- `dedup` solo en `/usr` por hardlinks (comparten inodo); seguro porque
  pacman reemplaza, no escribe in-place. Auto solo si ahorra ≥10MB
  (`ARXY_NO_AUTO_DEDUP=1` lo desactiva).
- `s=search` publicado (`sh` existe): `s` no es `shell`.

## Contratos Fase 2+ (bridge y --json)

- Fase 5 no integra el bridge sin resolver antes sus 4 bloqueantes
  (lista en el header de `bridge/arxy-bridged.c`).
- `doctor --json` lleva `"format": 1` desde el día 1; añadir campos es
  compatible, renombrar/quitar exige `format: 2`. Schema exacto: comentario
  en `lib/60-hw.sh` (única fuente, sin `.md` que derive).
- `reason`/`would_do` del JSON en español (idioma del repo; verificado: no
  hay mezcla con inglés en el código).
- `hardware.json` es caché, no fuente: `doctor --json` calcula fresco.
- `--fix` informa por defecto; `--apply` exige root; destructivos exigen `--confirm` + tty.
- Mocks de detección (tests sin root ni imagen, patrón `ARXY_SYS_DRM_PATH`):
  `ARXY_SYS_ROOT` (prefijo /proc+/sys), `ARXY_DEV_PATH` (defecto /dev),
  `ARXY_LIB_DIR`/`ARXY_LIB64_DIR` (loaders), `ARXY_SYS_DRM_PATH` (drm).
- Tests con sh -c + funciones de lib/: export -f funciones y export de vars, o llamadas directas (3 bugs esta sesion por no hacerlo).
- Kills deterministas en tests: overrides de funcion (curl/tar/mv/rm) que matan
  tras la fase + `kill -9 $BASHPID` (`$$` es el padre: mataria el test, no el
  subshell) ← Commit 6: `mv` que mata EN VEZ DE mover no prueba nada.
