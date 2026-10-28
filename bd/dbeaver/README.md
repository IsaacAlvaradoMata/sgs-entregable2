# Versiones para DBeaver

Archivos generados a partir de los scripts oficiales de `bd/`, solo para ejecutar en DBeaver con `Cmd + A` y `Option + X`: sin comentarios, sin líneas en blanco dentro de cada bloque y sin `/` (DBeaver corta mal los bloques PL/SQL con `/`).

Los scripts oficiales (`bd/0X_*.sql`) son los que valen para el manual de instalación y para SQL*Plus / SQL Developer.

Se generan con:

```bash
awk -f bd/dbeaver/convertir.awk <seccion del script oficial> > bd/dbeaver/<paso>.sql
```

Los bloques anónimos (`DECLARE … END;`, como la validación de sesión al inicio de cada script) no van en estos archivos: DBeaver no los separa del `CREATE` siguiente con la línea en blanco y da PLS-00103. Se corren aparte con `Cmd + Enter`.

Los packages van en un archivo aparte (`<paso>_package.sql`): la especificación y el cuerpo se seleccionan y se corren cada uno con `Cmd + Enter`. Juntos con `Option + X`, DBeaver mete el cuerpo dentro de la especificación (PLS-00103).
