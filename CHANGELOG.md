# Changelog de arxy

## [0.5.0] - 2026-09-15

Desde v0.2.1: Fase 6a, Fase 7 y cierre de auditoría.

### Añadido

- `arxy desktop --migrate`: etiqueta launchers legacy sin `X-Arxy-Pkg`
  (idempotente; auto tras `install`/`update` con aviso a stderr).
- Firmas minisign del tarball: CI de `arxy-image` firma y publica
  `.minisig`; `arxy setup` descarga y verifica con `config/arxy.pub`.
- `ARXY_SIGNATURE_POLICY` (`required|optional|off`, defecto `optional`);
  pin `ARXY_IMAGE_SHA256` + `required` = die (fail closed).
- `doctor --json` gana campo aditivo `signature`
  (`policy`, `minisign_available`, `last_setup_verified`; `format: 1` intacto).
- Tests nuevos: `test-desktop-migrate.sh`, `test-desktop-shims.sh`,
  `test-signature.sh`, `test-signature-policy.sh`.

### Corregido

- Tests e2e audio/input: trap de limpieza de rootfs temporales.
- `is_mesa_mini` + aviso de migrate: sin pipe bajo `pipefail` (SIGPIPE 141).
- `test-hardware-json.sh`: `bash -c` en vez de `sh -c` (dash).
- Split-brain con sudo sin env (`ARXY_DATA` derivado tras `_restore_frozen`).
- `lint.yml` inválido desde Fase 1 (nunca había corrido el CI).
- `build.yml` de imagen: gate de firma en shell (`if` + secrets lo invalida),
  `pacman -Sy` para minisign (db vacía en el container).

### Documentado (sin código)

- Reglas: push/release explícito, shadow manual→paquete, tests musl-aware,
  suites en secuencia (anti-flake), firmas minisign.
- `OUT-OF-SCOPE.md`: `ponytail:` del bridge, aislamiento GUI (Fase 6b),
  anclaje anti-downgrade (Fase 7b).

### Fuera de alcance

- Ver `OUT-OF-SCOPE.md` (anti-cheat, módulos kernel, userns, ICDs 32-bit,
  DDX anidado, glvnd, `narrowedTo`, anti-downgrade, GUI isolation).
