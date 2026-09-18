# Política de seguridad

## Reportar una vulnerabilidad

No abras un issue público. Escribe a **SrDicov@gmail.com** con:

- Qué componente afecta (`run`, `setup`, bridge, etc.).
- Pasos mínimos para reproducir o prueba de concepto.
- Qué puede hacer un atacante con ello (lectura, escritura, escalada).

Respondo en unos días. Publico el fix y lo menciono en el CHANGELOG;
si necesitas embargo temporal para coordinar, dilo en el correo.

## Versiones soportadas

| Versión | Soporte |
| ------- | ------- |
| 0.5.x   | Sí      |
| < 0.5   | No      |

## Alcance

arxy no es un sandbox de seguridad: no hay aislamiento entre el
subsistema y el host por diseño (ver README). Los reportes sobre
"el subsistema puede ver /home" no son vulnerabilidades, es la
arquitectura. Lo que sí cuenta: escalada de privilegios no intencionada,
ejecución remota, o el bridge ejecutando algo fuera de su allowlist.
