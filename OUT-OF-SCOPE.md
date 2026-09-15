# OUT-OF-SCOPE.md — límites de arxy (documento vivo)

Si no está aquí, no existe como límite conocido. Cada fase que añade un
`ponytail:` o una desviación lo registra aquí (ver "Tech debt vivo").
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

Desde Commit 11: `run_in` solo monta el manifiesto 64-bit reescrito
(`ponytail:` en `lib/35-gpu.sh`). Apps puras de 32-bit que busquen su
propio ICD pueden fallar. Upgrade: segundo manifiesto + loader 32-bit
cuando un caso real lo pida.

## 5. DDX Xorg anidado

Las apps X usan el servidor X del host (vía `/tmp/.X11-unix`
bindeado). No se monta el driver DDX de NVIDIA dentro
(`ponytail:` en `lib/10-level.sh`). Upgrade: montar
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
`install arxy-gaming`; Commit 13; re-verificado en v0.5.0 con Iris en
este host). AMD y NVIDIA reales: solo mocks
(lógica cubierta en `test-gpu-drm.sh`, montajes sin probar en HW).

Sin acceso a ese HW (2026-09-15, solo Intel disponible): si tienes
AMD/NVIDIA, reporta con `arxy doctor --json` + `arxy run eglinfo -B` +
`arxy run glxinfo -B` + `arxy run vulkaninfo --summary`.
Upgrade: verificar en HW real cuando haya acceso; si falla, fix de
Fase 4 en commit con mensaje ampliado. Decisión v0.5.0: 6b fuera
(§14), 7b diferido hasta usuario real (§15).

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
funcionan con el token ambiente, probado e2e en Commit 16).

## 13. Tech debt vivo (`ponytail:`)

`grep -rn 'ponytail:' lib/ tests/ bridge/` es la lista (ver `AGENTS.md`
"Tech debt grepeable"). Resumen a fecha de cierre de Fase 4:

- ICD Vulkan 32-bit (§4): manifiesto + loader cuando haya caso real.
- DDX Xorg anidado (§5): montar `xorg/modules` si hay X anidado.
- glvnd vendors (§6): `--ro-bind-data` como los ICDs.
- `\n` en nombres bajo `/usr` (`pkg_desktops`): `find -print0` si
  aparece un caso real.
- TOCTOU realpath→execv (`bridge/arxy-bridged.c`): `openat2` con
  `RESOLVE_*` o `fexecve` si hay caso real.
- EINTR en drenaje final (ídem): reintentar `read` en `[done]`.
- Padding base64 interior laxo (ídem): exigir `=` solo al final.
- Off-by-one 65/64 en parse (ídem, inocuo: `authorize()` limita a
  `MAXARGS`).

## 14. Aislamiento GUI (`ARXY_GUI_ISOLATION`, Fase 6b)

X11 bridge / Wayland isolation no se implementan en bash (Fase 6b,
Go/C). Patrón `narrowedTo` (§12): diferido con upgrade identificado;
solo cuando un consumidor real lo pida. `xdg-open` cubre `gio`.

## 15. Anclaje anti-downgrade (Fase 7b)

La firma minisign (Fase 7) autentica el tarball pero no su frescura:
un `latest` antiguo firmado seguiría verificando. Upgrade: estado
firmado `{format, sha256, timestamp}` + refusar timestamp menor, solo
cuando un consumidor real lo pida (hoy `setup` siempre quiere latest).
