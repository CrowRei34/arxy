# Qué cambia y por qué

## Checklist (puerta de AGENTS.md)

- [ ] `make sync` + `git diff --exit-code src/arxy` en verde
- [ ] `bash -n lib/*.sh src/arxy install.sh` en verde
- [ ] `shellcheck -S warning src/arxy install.sh` en verde
- [ ] `cmp` ×3 contra `packaging/void/arxy/files/` en verde
- [ ] Tests tocados en verde (`bash tests/test-*.sh`, en secuencia)
- [ ] Un commit con el porqué

## Pruebas

Comandos exactos que corriste y su resultado. Si algún check no aplica,
di cuál y por qué.
