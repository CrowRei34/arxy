cmd_help() {
    cat <<EOF
$PROG $ARXY_VERSION — subsistema Arch minimalista (rápido, sin sandbox).

Uso: $PROG <comando> [args...]   (axy es alias de $PROG)

  install|i <pkg...>   instalar paquetes de Arch (+ crea lanzadores .desktop)
  install gpu-amd|gpu-nvidia  stack GL completo para esas GPUs (+~170MB)
  install --aur <pkg>  instalar de AUR (precompilados -bin, motor paru)
  remove|rm <pkg...>   desinstalar (+ borra sus lanzadores)
  update|up            actualizar todo el subsistema (pacman -Syu)
  clean [--apply]   informa uso (rootfs/cache/AUR) y limpia con --apply
  dedup                hardlinkea ficheros identicos de /usr (ahorra disco)
  info <pkg>           info de un paquete (instalado o de repos)
  list|l               paquetes instalados ([desktop] = tiene lanzador)
  search|s <texto>     buscar en repos
  search-aur|sa <txt>  buscar en AUR (paru o RPC; requiere jq)
  run|r <bin|ruta> [...] ejecutar programa del subsistema o binario suelto
  which|w <bin|ruta>    muestra donde se resolveria ([subsistema] o [host])
  shell [cmd...]       terminal Arch completa (admin: sudo $PROG shell)
  export <pkg|f.desktop|--all>  (re)crear lanzadores .desktop
  unexport <nombre>    borrar un lanzador
  doctor [--fix]      verifica requisitos e imagen (y repara con --fix)
  quickstart|qs        dice tu siguiente paso segun estado (para empezar)
  setup                (re)descarga e instala la imagen (atomico, con rollback)
  rollback             restaura la imagen anterior a un setup
  version [--verbose]  version CLI+imagen (verbose: nivel/GPU/tamaño/hold)
  help                 esta ayuda

Atajos: i, r, rm, up, l, s. Si el comando no existe, se interpreta como 'run':
  $PROG firefox   ==   $PROG run firefox

Ejemplos:
  $PROG install firefox gimp htop
  $PROG run ./mi-binario-suelto --opcion
  $PROG shell
  sudo $PROG shell        # para pacman manual dentro

Config: $ARXY_SYS_CONF, ~/.config/arxy/config (env manda).
Nivel: auto (1=bwrap, 2=sin namespaces); forzar con ARXY_LEVEL=1|2.
Imagen: $ARXY_ROOT  (se descarga sola en el primer uso).
EOF
}

