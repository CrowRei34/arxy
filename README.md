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

**Void Linux** (recomendado): copiar `packaging/void/arxy/` a
`void-packages/srcpkgs/` y `xbps-src pkg arxy`, o pedirlo donde
distribuyas tus paquetes.

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
| `arxy shell` | shell interactiva dentro de Arch |
| `arxy search/info/list/update` | buscar, detalle, instalados, actualizar todo |
| `arxy export --all` | regenerar lanzadores del menú |
| `arxy setup / doctor` | (re)descargar imagen / chequeo de salud |
| `arxy inspect-deps <bin>` | qué librerías necesitaría un binario del host |
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

## Límites honestos

Necesitan demonios root/systemd y **no** van dentro: TeamViewer, AnyDesk.
`protonvpn-app` choca con el ProtonVPN del host (misma app single-instance
en el bus compartido). Steam/umu-launcher sí van (multilib habilitado).

## Desarrollo

```bash
bash -n src/arxy install.sh && shellcheck -S warning src/arxy install.sh
```

`src/arxy` y `config/arxy.conf` son canónicos; `packaging/void/arxy/files/`
son copias para xbps (el CI verifica que son idénticas).

## Licencia

MIT — ver [LICENSE](LICENSE).
