# arxy — subsistema Arch minimalista para cualquier distro

[![lint](https://github.com/SrDicov/arxy/actions/workflows/lint.yml/badge.svg)](https://github.com/SrDicov/arxy/actions/workflows/lint.yml)
![license](https://img.shields.io/badge/license-MIT-green)

Corre software de **Arch Linux** (repos oficiales + AUR precompilado) en
cualquier distro —Void, Alpine, Debian…— a **velocidad nativa**, sin VMs, sin
Docker y sin sandbox pesado. Las apps gráficas aparecen en tu menú como si
fueran nativas.

```bash
sudo arxy setup                         # primera vez: descarga Arch mínimo
arxy install telegram-desktop steam     # repos oficiales
arxy install --aur spotify zoom vscode  # AUR precompilado (-bin)
arxy run rar x archivo.rar              # CLI dentro del subsistema
arxy update                             # pacman -Syu del subsistema
```

> La imagen mínima la construye el repo hermano
> [**arxy-image**](https://github.com/SrDicov/arxy-image) (CI semanal,
> release `latest`); este CLI la descarga y verifica sola en el primer uso.

## Requisitos del host

`bash bwrap curl tar zstd xz gzip file` + user namespaces sin privilegios.
Se requiere `bash>=4.4` (todas las distros soportadas lo traen).
Comprobar: `arxy doctor`.

## Instalación

**Void Linux** (recomendado, desde z-repo):

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S   # importa la llave del repo (solo la primera vez)
sudo xbps-install -y arxy
sudo arxy setup              # descarga la imagen (~220MB) y listo
```

En Void musl usa `.../z-repo/x86_64-musl` en la primera línea.
Empaquetado manual: copiar `packaging/void/arxy/` a
`void-packages/srcpkgs/` y `xbps-src pkg arxy`.

**Cualquier distro:**

```bash
sudo ./install.sh              # a /usr/local (arxy + axy)
sudo PREFIX=/usr ./install.sh  # a /usr
sudo arxy setup                # descarga la imagen (~220MB) y listo
```

## Uso

| Comando | Qué hace |
|---|---|
| `arxy install <pkg...>` / `--aur` | instala (oficial / AUR `-bin`) + crea launcher |
| `arxy remove <pkg...>` | desinstala y borra su launcher |
| `arxy run <bin> [args]` | ejecuta algo dentro del subsistema |
| `arxy which <bin>` | muestra dónde se resolvería ([subsistema] o [host]) |
| `arxy shell` | shell interactiva dentro de Arch |
| `arxy search/info/list/update` | buscar, detalle, instalados, actualizar todo |
| `arxy export --all` | regenerar lanzadores del menú |
| `arxy setup / doctor` | (re)descargar imagen (atómico, con rollback) / chequeo de salud |
| `arxy dedup` | hardlinkea ficheros idénticos de `/usr` (corre solo tras `install`/`update` si ahorra ≥10 MB; opt-out `ARXY_NO_AUTO_DEDUP=1`) |
| `arxy rollback` | restaura el rootfs completo al estado previo al último setup (se pierde lo instalado después) |
| `axy` | alias corto de `arxy` |

Configuración: `/etc/arxy/arxy.conf` (sistema) y `~/.config/arxy/config`
(usuario); todo admite override por variable de entorno (`ARXY_*`).

## Cómo funciona (resumen)

- La imagen es un rootfs Arch extraído en `/var/lib/arxy/root` (sin
  squashfs/FUSE: ficheros normales, arranque instantáneo).
- Entrar es solo un **mount namespace** (`bwrap --bind root /`): sin
  seccomp/netns. Se comparte `/home /tmp /run /dev` y la GPU; `/host` es tu
  raíz real. De ahí la velocidad nativa.
- Lectura/ejecución como usuario; solo instalar/actualizar re-ejecuta con
  `sudo`. AUR solo `-bin` (nunca compila toolchains), construidos como
  usuario en `/var/lib/arxy/build`.
- Repos: `core` + `extra` + `multilib` (Steam y 32 bits funcionan).
- Dos niveles de ejecución, autodetectados (`arxy doctor` los muestra,
  `ARXY_LEVEL=1|2` fuerza uno):
  - **Nivel 1** (bwrap + user namespaces): el habitual.
  - **Nivel 2** (sin namespaces): `run` vía el `ld-linux` del subsistema,
    `install` vía `chroot` con sudo. Para kernels hardened o containers
    donde bwrap no funciona. Sin FUSE en ningún nivel, por decisión:
    cada formato FUSE reintroduciría la dependencia que arxy elimina
    (la imagen es un tarball plano, no squashfs/dwarfs). Tampoco hay
    bundle monolítico estilo conty-*.sh: el rootfs extraído ya cubre
    ambos niveles y mantener dos arquitecturas paralelas sería deuda.

## Límites honestos

Necesitan demonios root/systemd y **no** van dentro: TeamViewer, AnyDesk.
`protonvpn-app` choca con el ProtonVPN del host (misma app single-instance
en el bus compartido). Steam/umu-launcher sí van (multilib habilitado).
En nivel 2: AUR no disponible (compilar exige namespaces: solo paquetes
oficiales); AUR se compila con `--skippgpcheck` por defecto (los keyservers
caídos rompen builds sanos; `ARXY_GPG_CHECK=1` exige verificación GPG);
`pacman -S/-U/-R` dentro de `arxy shell` está bloqueado a propósito
(vería la DB del host: usa `arxy install/remove/update`;
solo cubre invocación por nombre, `/usr/bin/pacman` directo no intercepta;
escape hatch `ARXY_ALLOW_RAW_PACMAN=1`); CheckSpace se desactiva en
operaciones chroot (la mtab de containers anidados no expone el rootfs);
apps GTK/Qt con cachés de módulos de rutas absolutas son best-effort. Ni el nivel 1 (cero aislamiento) ni el 2
son sandbox de seguridad: no ejecutes software no confiable.
Dedup: si una app modificara un fichero hardlinkeado afectaría a las demás
que lo comparten; en `/usr` no ocurre en la práctica (pacman reemplaza
ficheros al actualizar, no escribe in-place: el link se rompe solo).

## Desarrollo

```bash
bash -n src/arxy install.sh && shellcheck -S warning src/arxy install.sh
```

`src/arxy` y `config/arxy.conf` son canónicos; `packaging/void/arxy/files/`
son copias para xbps (el CI verifica que son idénticas).

## Licencia

MIT — ver [LICENSE](LICENSE).
