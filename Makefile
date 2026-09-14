# Makefile — arxy se edita en lib/*.sh; src/arxy es GENERADO (commiteado
# porque install.sh y packaging/void lo leen del clon sin herramientas).
# Tras tocar lib/: `make src/arxy` y el diff de src/arxy debe estar vacío
# salvo tu cambio (D9: regenerar 2 veces da el mismo sha256).
# shellcheck corre sobre src/arxy GENERADO (los fragmentos sueltos dan
# falsos SC2034/SC2148: vars y shebang viven en otro fragmento).
LIB = lib/00-head.sh lib/10-level.sh lib/20-lifecycle.sh lib/30-package.sh \
      lib/40-query.sh lib/41-desktop.sh lib/50-run.sh lib/60-hw.sh \
      lib/70-help.sh lib/zz-dispatch.sh

src/arxy: $(LIB) Makefile
	cat $(LIB) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

.PHONY: check sync
check: src/arxy
	bash -n src/arxy install.sh

# Copia el generado + conf a packaging/void (flujo: editar lib/,
# make sync, commitear todo junto). cp es idempotente por diseño.
sync: src/arxy
	cp src/arxy packaging/void/arxy/files/arxy
	cp config/arxy.conf packaging/void/arxy/files/arxy.conf
