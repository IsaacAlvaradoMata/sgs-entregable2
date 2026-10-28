# Pendientes

Qué falta y quién lo tiene. Se actualiza al avanzar; el detalle de cada etapa está en [`guia.md`](../guia.md).

| Pendiente | Responsable | Estado |
|---|---|---|
| `bd/02_modelo.sql`: estructura y datos de catálogos | Isaac | Hecho (2026-10-26) |
| Preguntar a Andrés si sus procesos de standby y RMAN necesitan alguna tabla (registro de traslados, respaldos) | Isaac | Respondido: no necesitan tabla nueva; el job de respaldo solo necesita la fila `RESP_HORA_DIARIO` y dos permisos (ver Carril S) |
| Datos de prueba de operaciones (compras, ventas, pagos, devoluciones, traslados) | Isaac | Después de B3 |
| Diagrama relacional y diccionario de datos (se generan del script al cerrar el modelo) | Isaac | Pendiente |
| Configurar la zona horaria `America/Costa_Rica` en el sistema operativo de `SGSPRI` y `SGSSTB` antes de instalar Oracle (Docker está en UTC; solo se tiene en cuenta al probar B6 en desarrollo) | Andrés | Hecho (zona `America/Costa_Rica` desde la instalación; `chronyd` activo en las dos, ver `servidores/s1_sgspri.md` §8) |
| Probar desde `SGSPRI` y `SGSSTB` qué puerto de Gmail responde (`465` o `587`) y crear el wallet del correo en las dos VMs (ver `bd/03_base_interna.sql` y el parámetro `CORREO_PUERTO`). En la red de desarrollo el 587 no responde; se usa el 465 | Andrés | Pendiente |
| Tablas que llenan los procesos de B4, B6 y B8 (bitácora y su detalle, detalle de descuentos, premiación, órdenes de compra, cierre diario y su detalle, monitoreo): verificar 5 filas o más al cerrar esas etapas. `SGS_DESTINATARIO` tiene 3: agregar 2 más (otro coordinador y otro DBA) | Isaac | Hecho (2026-10-28, sección D de `10_datos_operaciones.sql`) |
| Padrón (B5): crear la **misma carpeta** en `SGSPRI` y `SGSSTB` para `PADRON_COMPLETO.txt` y `distelec.txt` (propuesta `/u01/app/oracle/sgs/padron`, dueño `oracle`). Así, después de un switchover o failover, el nuevo principal puede volver a cargar el padrón sin cambiar el directorio de Oracle | Andrés | Pendiente |
| Crear las dos bases con juego de caracteres `AL32UTF8` (los nombres del padrón traen Ñ y tildes) y el principal en `FORCE LOGGING` (Data Guard), para que la carga del padrón llegue completa a la standby | Andrés | Hecho (`AL32UTF8` en `dbca`; `FORCE LOGGING` en S3) |
| Espacio para archivos de redo archivados: la carga del padrón (3,7 millones de filas) genera bastante redo de una vez | Andrés | Pendiente |
| `SGS_CIERRE_DIARIO` y `SGS_PREMIACION` tienen 1 fila (las crea el proceso). Para la regla de 5 filas por tabla: generar los cierres de días anteriores con `SGS_PKG_PROCESOS.cerrar_dia(fecha)` y decidir cómo completar las premiaciones (se hace al final, con los datos definitivos) | Isaac | Hecho (2026-10-28) |

## Carril S — Servidores (Andrés)

**Último avance (2026-10-28, noche):** S6 completo: switchover, failover (caída simulada de `SGSPRI`), reincorporación con `REINSTATE` y regreso a los roles originales, sin pérdida de datos. Detalle en [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md). Antes (2026-10-28, tarde): S5 casi completo (falta solo el job diario). Antes: Tailscale en las dos VMs y conexión a `SGSPDB` por Tailscale probada; `local_listener` corregido en ambos servidores. **Siguiente sesión: S5 (RMAN).** Antes (2026-10-26): **S3 completo: Data Guard funcionando** (`SGSSTB` standby física en Active Data Guard; probado con un dato que viaja de `SGSPRI` a `SGSSTB`). Detalle en [`servidores/s3_dataguard.md`](../servidores/s3_dataguard.md). Antes: base de datos creada en `SGSPRI` (`DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, ARCHIVELOG, PDB `SGSPDB`); detalle en [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md). Antes: S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

### Después

- [x] Crear la base en `SGSPRI` con `dbca`.
- [x] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS`.
- [ ] Avisar a Isaac que `SGSPDB` ya existe en `SGSPRI` (punto I1).
- [ ] Antes de la defensa: cambiar las contraseñas de `SYS`, `SYSTEM` y `PDBADMIN` por unas fuertes.
- [x] Tailscale en ambas VMs (sin exit node): [`servidores/tailscale.md`](../servidores/tailscale.md). `SGSPRI` = `100.76.209.30`, `SGSSTB` = `100.69.133.78`.
- [ ] Pedirle a Isaac que revoque la llave de Tailscale ya usada.
- [x] Conexión a `SGSPDB` por la IP de Tailscale probada desde `SGSSTB` (`sqlplus system@100.76.209.30:1521/sgspdb`).
- [ ] Isaac prueba la conexión desde DBeaver en su Mac (datos en [`servidores/tailscale.md`](../servidores/tailscale.md)).
- [x] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).
- [x] Rutina de arranque y apagado probada (2026-10-27): [`servidores/operacion_diaria.md`](../servidores/operacion_diaria.md).
- [x] Hora sincronizada con `chronyd` en los dos servidores.
- [ ] S4: administración parametrizada del standby (necesita la tabla de parámetros de Isaac, I2).
- [x] S5: RMAN configurado; full, incremental, restore y recovery probados; copia a `SGSSTB`; script a demanda (`servidores/scripts/respaldo_rman.sh`). Ver [`servidores/s5_rman.md`](../servidores/s5_rman.md).
- [ ] S5: job diario `SGS_JOB_RESPALDO_DIARIO` (en `SGSPDB`, dueño `SGS_ADMIN`, como los jobs de Isaac) que ejecute `respaldo_rman.sh`. Hora decidida: `RESP_HORA_DIARIO` = `1` (1:00 a. m.); si a esa hora las VMs están apagadas, ese día no hay respaldo automático y se corre a demanda. Necesita:
  - [ ] Isaac agrega en `bd/03_base_interna.sql` la fila `RESP_HORA_DIARIO` = `'1'` ("Hora del respaldo diario con RMAN").
  - [ ] Isaac agrega en `bd/01_infraestructura.sql`: `GRANT CREATE EXTERNAL JOB TO SGS_ADMIN;` y `GRANT CREATE CREDENTIAL TO SGS_ADMIN;`.
  - [ ] I1 hecho (esquema de Isaac instalado en `SGSPDB` de `SGSPRI`).
  - [ ] Credencial con el usuario Linux `oracle` (la contraseña no va al repo); el job revisa que la base sea `SGSPRI` en rol PRIMARY antes de respaldar.
- [ ] Borrar el tablespace de prueba `ts_prueba_rman` (y su tabla) de `SGSPDB` cuando ya no se necesite.
- [x] S6: switchover, failover y reincorporación probados con el broker `sgs_dg`: [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md).
- [ ] S7: situaciones problemáticas y manual del standby.
- [ ] Borrar la tabla de prueba `system.prueba_dg` de `SGSPDB` cuando ya no se necesite.
