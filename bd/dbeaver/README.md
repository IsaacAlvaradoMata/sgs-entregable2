# Versiones para DBeaver

Archivos generados a partir de los scripts oficiales de `bd/`, solo para ejecutar en DBeaver con `Cmd + A` y `Option + X`: sin comentarios, sin líneas en blanco dentro de cada bloque y sin `/` (DBeaver corta mal los bloques PL/SQL con `/`).

Los scripts oficiales (`bd/0X_*.sql`) son los que valen para el manual de instalación y para SQL*Plus / SQL Developer.

Se generan con:

```bash
awk -f bd/dbeaver/convertir.awk <seccion del script oficial> > bd/dbeaver/<paso>.sql
```
