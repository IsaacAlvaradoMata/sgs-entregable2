# Instalación de la base de datos en SGSPRI

Los scripts de `bd/` se prueban en Docker (Oracle Free 23ai, PDB `FREEPDB1`) escritos para Oracle 21c EE. En SGSPRI se ejecutan los mismos archivos; solo cambian los valores que dependen del servidor.

## Valores que cambian por servidor

| Script | Valor | Docker | SGSPRI |
|---|---|---|---|
| Todos | PDB | `FREEPDB1` | `SGSPDB` |
| `01_infraestructura.sql` | `<CLAVE_SGS_ADMIN>` | clave de desarrollo | clave de producción (en `notas/claves.md`) |
| `01_infraestructura.sql` | Ruta de los datafiles | se toma sola del datafile `SYSTEM` de la PDB | igual |
| `03_base_interna.sql` | `<LLAVE_CIFRADO>` | llave de desarrollo | llave de producción |
| `03_base_interna.sql` | Parámetro `CORREO_WALLET` | `file:/opt/oracle/oradata/wallet_sgs` | igual (misma ruta en `SGSPRI` y `SGSSTB`, ver `wallet_correo.md`) |
| `03_base_interna.sql` | Parámetro `CORREO_PUERTO` | `465` | el puerto que responda desde la VM |
| `03_base_interna.sql` | `<CLAVE_CORREO>` | contraseña de aplicación de Gmail | la misma (se guarda cifrada al final del script) |
| `06_padron.sql` | `<RUTA_PADRON>` | `/opt/oracle/oradata/padron` | igual (misma carpeta en `SGSPRI` y `SGSSTB`, dueño `oracle`) |
| `08_seguridad.sql` | `<CLAVE_USUARIO_*>`, `<CLAVE_ROL_*>` | claves de desarrollo | claves de producción (en `notas/claves.md`) |

## SQL*Plus

Antes de ejecutar los scripts con SQL*Plus: `export NLS_LANG=AMERICAN_AMERICA.AL32UTF8`. Los scripts están en UTF-8 y los textos de los correos llevan tildes y Ñ; sin esa variable quedan dañados dentro de los packages.

## Orden

1. `01_infraestructura.sql` como SYSTEM en `SGSPDB`.
2. `02_modelo.sql` como SGS_ADMIN.
3. `03_base_interna.sql`: sección 0 como SYS en `SGSPDB`, el resto como SGS_ADMIN (al final guarda `CORREO_CLAVE` cifrada).
4. `04_reglas_negocio.sql` y `05_bitacoras.sql` como SGS_ADMIN.
5. `06_padron.sql`: copiar los archivos del TSE a la carpeta, sección 0 como SYS en `SGSPDB`, el resto como SGS_ADMIN (la última sección carga el padrón; tarda unos minutos).
6. Los scripts siguientes (07 a 09) en orden.
7. `10_datos_operaciones.sql` completo (secciones A a E).

`00_reinicio_desarrollo.sql` no se ejecuta en SGSPRI.

## Antes de instalar (servidor)

- Zona horaria `America/Costa_Rica` en el sistema operativo de las dos VMs.
- Bases creadas con juego de caracteres `AL32UTF8` y el principal en `FORCE LOGGING`.
- Wallet del correo y carpeta del padrón en **las dos** VMs, con la misma ruta, para que después de un switchover o failover el nuevo principal funcione sin cambiar parámetros.

## Standby (SGSSTB)

En la standby no se ejecuta ningún script: tablas, packages, triggers, parámetros, privilegios, la lista de control de red, el directorio del padrón y los datos llegan por el redo. Lo que vive fuera de la base (wallet, archivos del padrón, zona horaria) se prepara a mano en la VM.

## Verificar en SGSPRI

- Enviar un correo de prueba con `SGS_PKG_CORREO.enviar`.
- Repetir la prueba de la bitácora (`bd/dbeaver/paso_4_1_pruebas.sql`, partes 1 y 2): confirma que la detección por pila de llamadas (`DBMS_UTILITY.FORMAT_CALL_STACK`) marca bien lo crítico en 21c.
