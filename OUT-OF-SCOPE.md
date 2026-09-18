# OUT-OF-SCOPE.md — límites de arxy (documento vivo)

Si no está aquí, no existe como límite conocido. Cada `TODO:` o desviación
se registra aquí (ver "Tech debt vivo").
Un reporte "arxy no ejecuta X" se responde con el link a su sección.

## 1. Anti-cheat a nivel kernel

EAC, BattlEye, Vanguard, Ricochet y similares exigen su driver en el
kernel del host y telemetría anti-VM. Ningún contenedor ligero (arxy,
Distrobox, systemd-nspawn) los ejecuta. Los juegos que los exigen no
funcionan en arxy por diseño, no por bug. Revisar el manifiesto del
juego (ProtonDB) antes de instalar.

## 2. Módulos kernel ausentes

arxy usa el kernel del host y no puede suplir módulos: `nvidia`,
`ntsync`, `fuse`. Si el host no los trae, la feature que los pide no
funciona. `arxy doctor --json` lo reporta (`kmods`, `dev`, `nvidia`).

## 3. Hosts sin user namespaces

L1 (bwrap) es imposible sin userns. L2 lo cubre (binarios via ld-linux,
escrituras via chroot con sudo) pero exige root para instalar.
`arxy doctor --json` lo reporta (`userns`, `level`).

## 4. ICDs Vulkan de 32-bit

`run_in` reescribe el manifiesto al guest segun su
clase real (`elf_class`; antes asumia 64-bit y un ICD 32-bit
caia en `lib64`). El loader Vulkan de 32-bit sigue sin soporte en el
rootfs, asi que apps puras de 32-bit que busquen su propio ICD pueden
fallar igual. Upgrade: segundo manifiesto + loader 32-bit cuando un
caso real lo pida.

## 5. DDX Xorg anidado

Las apps X usan el servidor X del host (vía `/tmp/.X11-unix`
bindeado). No se monta el driver DDX de NVIDIA dentro
(`TODO:` en `lib/10-level.sh`). Upgrade: montar
`xorg/modules` por ruta conocida si alguien corre un X anidado.

## 6. glvnd `egl_vendor.d`

No se montan los JSONs de vendors GLVND del host, solo ICDs Vulkan y
`egl_external_platform.d`. Apps EGL-headless que dependan del vendor
del host pueden fallar. Upgrade: mismo mecanismo `--ro-bind-data`
que los ICDs.

## 7. PKGBUILDs `arxy-gaming-*` no publicados en AUR

`arxy install arxy-gaming` funciona vía rewrite a dependencias reales;
los PKGBUILDs de `packaging/aur/` son drafts. Upgrade: publicar +
`make aur-publish` (follow-up declarado, no existe aún).

## 8. Primera ejecución de Steam

`steam --version` como root se niega (decisión de Valve, no de arxy).
Como usuario, el primer arranque auto-descarga el runtime de Steam
(cientos de MB, versionado por upstream): es lento y ajeno a arxy.
`arxy install arxy-gaming` deja los paquetes; el bootstrap lo hace
Steam en su primer arranque en sesión de usuario.

## 9. `pkg=$ver` de NVIDIA

Si la versión exacta del módulo no está en repos en ese momento,
pacman falla con mensaje. Sin fallback a "cualquiera": un mismatch
provoca crashes GL. Fijar el mirror o esperar al repo.

## 10. Hardware no probado

Verificado real: Intel (HD 630: GL + EGL tras
`install arxy-gaming`; re-verificado en v0.5.0 con Iris en
este host). AMD y NVIDIA reales: solo mocks
(lógica cubierta en `test-gpu-drm.sh`, montajes sin probar en HW).

Sin acceso a ese HW (solo hay Intel disponible): si tienes
AMD/NVIDIA, reporta con `arxy doctor --json` + `arxy run eglinfo -B` +
`arxy run glxinfo -B` + `arxy run vulkaninfo --summary`.
Upgrade: verificar en HW real cuando haya acceso; si falla, fix en
commit con mensaje ampliado.

## 11. Tarball vigente con `[multilib]` duplicado

El builder añadía la estanza en vez de descomentar (`create-arch-`
`bootstrap.sh`, ya corregido para la proxima build). El tarball
actual trae el duplicado: pacman avisa ("database already
registered") pero opera. Se normaliza solo en la proxima imagen.

## 12. Registro por instancia / `narrowedTo` (diferido, no omitido)

El daemon solo conoce UN token (el suyo, ambiente: todo proceso del
sandbox lo hereda por env). Un registro auto-servido no confina nada
con el mismo UID: nada distingue por env a `arxy run` de la app que
corre dentro, asi que cualquier allowlist "estrechada" seria
auto-otorgada. La frontera real sigue siendo la allowlist del daemon
(`--allowed-cmd` al arrancar). Upgrade: credencial padre-fuera-de-banda
(o techo del registro-raiz contra la allowlist del daemon) + TTL +
`trap`; solo cuando un consumidor anidado real lo pida (Steam/Proton
funcionan con el token ambiente, probado e2e).

## 13. Tech debt vivo (`TODO:`)

`grep -rn 'TODO:' lib/ tests/ bridge/` es la lista (ver `AGENTS.md`
"Tech debt grepeable"). Resumen:

- ICD Vulkan 32-bit (§4): manifiesto + loader cuando haya caso real.
- DDX Xorg anidado (§5): montar `xorg/modules` si hay X anidado.
- glvnd vendors (§6): `--ro-bind-data` como los ICDs.
- `\n` en nombres bajo `/usr` (`do_dedup`): `find -print0` si
  aparece un caso real.
- TOCTOU realpath→execv (`bridge/arxy-bridged.c`): `openat2` con
  `RESOLVE_*` o `fexecve` si hay caso real.
- EINTR en drenaje final (ídem): reintentar `read` en `[done]`.
- Padding base64 interior laxo (ídem): exigir `=` solo al final.
- Off-by-one 65/64 en parse (ídem, inocuo: `authorize()` limita a
  `MAXARGS`).

## 14. Aislamiento GUI (`ARXY_GUI_ISOLATION`)

X11 bridge / Wayland isolation no se implementan en bash (se harían en
Go/C). Patrón `narrowedTo` (§12): diferido con upgrade identificado;
solo cuando un consumidor real lo pida. `xdg-open` cubre `gio`.

## 15. Anclaje anti-downgrade

La firma minisign autentica el tarball pero no su frescura:
un `latest` antiguo firmado seguiría verificando. Upgrade: estado
firmado `{format, sha256, timestamp}` + refusar timestamp menor, solo
cuando un consumidor real lo pida (hoy `setup` siempre quiere latest).

## 16. Retención del Rollback (1 generación)

El comando `arxy rollback` retiene únicamente la generación
inmediatamente anterior (`ARXY_ROOT.old`). Ejecutar un segundo
`setup` (por ejemplo, tras un intento fallido de arreglo)
destruirá la copia buena original, reemplazándola por la actual.
Para retener múltiples generaciones se requeriría versionado de
directorios (ej. `.old.1`, `.old.2`), pero el diseño prioriza
simplicidad atómica. Upgrade: snapshots btrfs/ZFS o múltiples links,
solo si la demanda lo exige.

- **z-repo noarch support**: `check_outdated.py` de z-repo ignora en silencio los paquetes con `archs="noarch"`. Mientras tanto, el template de arxy evita `noarch` y compila para cada arquitectura (x86_64 y x86_64-musl). Eso duplica builds de CI en paquetes sin arquitectura. Arreglarlo exige tocar `check_outdated.py` en z-repo. Upgrade: cuando z-repo soporte noarch, volver al canónico con `archs="noarch"`.

## Verificación end-to-end en Void Linux

Los paquetes publicados en z-repo (arxy-0.5.0_N.x86_64.xbps,
arxy-0.5.0_N.x86_64-musl.xbps) son compilados y firmados por
GitHub Actions, y validados por `check_outdated.py` de z-repo. Sin
embargo, la instalación + ejecución end-to-end en un host Void
real no se verifica en CI.

Upgrade path: cuando haya acceso a un host Void (VM, contenedor),
correr:
  sudo xbps-install -S arxy
  arxy version --verbose
  arxy doctor --json
y reportar.

Riesgo actual: bajo. El delta entre 0.5.0_1 y 0.5.0_2 son fixes de UX
sin cambios estructurales.
