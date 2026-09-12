# arxy — corre software de Arch en cualquier distro, a velocidad nativa

[![lint](https://github.com/SrDicov/arxy/actions/workflows/lint.yml/badge.svg)](https://github.com/SrDicov/arxy/actions/workflows/lint.yml)
![license](https://img.shields.io/badge/license-MIT-green)

```bash
sudo arxy setup                  # primera vez: descarga Arch mínimo (~128MB)
arxy quickstart                  # te dice el siguiente paso
arxy install telegram-desktop    # repos oficiales (+ lanzador en tu menú)
arxy install --aur spotify       # AUR precompilado (-bin)
arxy run rar x archivo.rar       # CLI dentro del subsistema
```

## Instalación

**Void Linux** (desde z-repo):

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S   # importa la llave del repo (solo la primera vez)
sudo xbps-install -y arxy
```

En Void musl usa `.../z-repo/x86_64-musl`. Empaquetado manual: copiar
`packaging/void/arxy/` a `void-packages/srcpkgs/` y `xbps-src pkg arxy`.

**Cualquier distro** (clonar + instalar; no hay `curl | bash`: el
instalador necesita el layout del repo):

```bash
git clone https://github.com/SrDicov/arxy && cd arxy
sudo ./install.sh              # a /usr/local (arxy + axy)
sudo arxy setup                # descarga la imagen y listo
```

Imagen local (probar un build propio): `ARXY_IMAGE_URL=file:///ruta/al.tar.zst`
(nota: `file://` no acepta espacios en la ruta).

Requisitos del host: `bash bwrap curl tar zstd xz gzip file` +
`bash>=4.4`. Comprobar: `arxy doctor`.

## Arquitectura: 2 niveles

Entrar al subsistema es barato: la imagen es un rootfs Arch extraído en
`/var/lib/arxy/root` (sin squashfs/FUSE: ficheros normales). Se comparte
`/home /tmp /run /dev` y la GPU; `/host` es tu raíz real. De ahí la
velocidad nativa. Lectura/ejecución como usuario; solo instalar/actualizar
re-ejecuta con `sudo`.

- **Nivel 1** (bwrap + user namespaces): el habitual.
- **Nivel 2** (sin namespaces): `run` vía el `ld-linux` del subsistema,
  `install` vía `chroot` con sudo. Para kernels hardened o containers
  donde bwrap no funciona. Autodetectados (`arxy doctor` los muestra,
  `ARXY_LEVEL=1|2` fuerza uno).

## Límites honestos (léeme si vienes de AMD/NVIDIA)

- **AMD/NVIDIA: no probado en hardware.** `arxy doctor` avisa si detecta
  discreta e `install gpu-amd` / `gpu-nvidia` instala el stack completo
  (+~170MB, quita el hold `IgnorePkg=mesa`). La vía existe; el dato no.
- **NVIDIA propietaria: fuera de v1.** Solo nouveau (Mesa).
- **Intel iGPU y softpipe: verificados** (HD 630 acelerado, sin LLVM).
- **AUR: solo nivel 1** (compilar exige namespaces); solo `-bin`
  (nunca toolchains); `--skippgpcheck` por defecto (`ARXY_GPG_CHECK=1`
  lo exige).
- **Sin sandbox de seguridad**: ni L1 (cero aislamiento) ni L2. Es
  compat-glibc, no aislamiento: no ejecutes software no confiable.
- Necesitan demonios root/systemd y **no** van dentro: TeamViewer,
  AnyDesk. `protonvpn-app` choca con el ProtonVPN del host (misma app
  single-instance en el bus compartido). Steam/umu-launcher sí van
  (multilib habilitado).
- En nivel 2, `pacman -S/-U/-R` dentro de `arxy shell` está bloqueado a
  propósito (usa `arxy install/remove/update`); CheckSpace se desactiva
  en chroot; cachés GTK/Qt de rutas absolutas son best-effort.
- `arxy rollback` restaura el rootfs al setup anterior (se pierde lo
  instalado después). `arxy clean --apply` borra cachés y el rollback.
- Dedup por hardlinks en `/usr`: pacman reemplaza (no escribe in-place),
  el link se rompe solo. Fuera de `/usr` no se linkea.

## Uso

| Comando | Qué hace |
|---|---|
| `arxy install <pkg...>` / `--aur` | instala (oficial / AUR `-bin`) + crea launcher (`Exec=arxy run …`, directo, sin wrappers) |
| `arxy remove <pkg...>` | desinstala y borra su launcher |
| `arxy run <bin> [args]` | ejecuta algo dentro del subsistema |
| `arxy which <bin>` | dónde se resolvería ([subsistema] o [host]) |
| `arxy shell` | shell interactiva dentro de Arch |
| `arxy search/info/list/update` | buscar, detalle, instalados, actualizar todo |
| `arxy export --all` | regenerar lanzadores del menú |
| `arxy setup / doctor` | (re)descargar imagen (atómico, con rollback) / chequeo |
| `arxy dedup` | hardlinkea idénticos de `/usr` (auto tras `install`/`update` si ahorra ≥10 MB; opt-out `ARXY_NO_AUTO_DEDUP=1`) |
| `axy` | alias corto de `arxy` |

Configuración: `/etc/arxy/arxy.conf` (sistema) y `~/.config/arxy/config`
(usuario); todo admite override por variable de entorno (`ARXY_*`).

## Validación

- **Matrix en 5 distros** (Alpine, Chimera, Void, Ubuntu,
  Ubuntu-privilegiado): `arxy-image/tests/matrix.sh` — assertions de
  contenido, no solo rc. El CI la corre en cada build de imagen.
- **Hardware real** (Intel HD 630): `tests/test-hardware.sh` — dbus
  L1+L2, iris acelerado, softpipe sin LLVM, app Electron con ventana
  real. (`dbus-send` no viene en la mini: ese check da SKIP honesto;
  `arxy install dbus` lo activa.)

## Cómo contribuir

Bash, sin dependencias nuevas. Puerta antes de commit:

```bash
bash -n src/arxy install.sh && shellcheck -S warning src/arxy install.sh
```

`src/arxy` y `config/arxy.conf` son canónicos; `packaging/void/arxy/files/`
son copias para xbps (el CI verifica que son idénticas). Corre
`tests/matrix.sh` antes de commit (ver `arxy-image/tests/README.md`).
Lee `AGENTS.md`: tiene las reglas que cazaron bugs reales.

## Licencia

MIT — ver [LICENSE](LICENSE).
