# Pendientes

Qué falta y quién lo tiene. Se actualiza al avanzar; el detalle de cada etapa está en [`guia.md`](../guia.md).

| Pendiente | Responsable | Estado |
|---|---|---|
| `bd/02_modelo.sql`: estructura y datos de catálogos | Isaac | Hecho (2026-10-26) |
| Preguntar a Andrés si sus procesos de standby y RMAN necesitan alguna tabla (registro de traslados, respaldos) | Isaac | Respondido: no necesitan tabla nueva; el job de respaldo solo necesita la fila `RESP_HORA_DIARIO` y dos permisos (ver Carril S) |
| Datos de prueba de operaciones (compras, ventas, pagos, devoluciones, traslados) | Isaac | Después de B3 |
| Diagrama relacional y diccionario de datos (se generan del script al cerrar el modelo) | Isaac | Hecho (2026-10-29): diagrama y `docs/modelo/SGS_diccionario_datos.docx` |
| Configurar la zona horaria `America/Costa_Rica` en el sistema operativo de `SGSPRI` y `SGSSTB` antes de instalar Oracle (Docker está en UTC; solo se tiene en cuenta al probar B6 en desarrollo) | Andrés | Hecho (zona `America/Costa_Rica` desde la instalación; `chronyd` activo en las dos, ver `servidores/s1_sgspri.md` §8) |
| Probar desde `SGSPRI` y `SGSSTB` qué puerto de Gmail responde (`465` o `587`) y crear el wallet del correo en las dos VMs (ver `bd/03_base_interna.sql` y el parámetro `CORREO_PUERTO`). En la red de desarrollo el 587 no responde; se usa el 465 | Andrés | Hecho (2026-10-28: en las dos VMs el 587 no responde y el 465 sí; wallet creado en las dos, ver `servidores/i1_preparacion_vms.md`) |
| Tablas que llenan los procesos de B4, B6 y B8 (bitácora y su detalle, detalle de descuentos, premiación, órdenes de compra, cierre diario y su detalle, monitoreo): verificar 5 filas o más al cerrar esas etapas. `SGS_DESTINATARIO` tiene 3: agregar 2 más (otro coordinador y otro DBA) | Isaac | Hecho (2026-10-28, sección D de `10_datos_operaciones.sql`) |
| Padrón (B5): crear la **misma carpeta** en `SGSPRI` y `SGSSTB` para `PADRON_COMPLETO.txt` y `distelec.txt` (`/opt/oracle/oradata/padron`, la misma del Docker, dueño `oracle`; el wallet va en `/opt/oracle/oradata/wallet_sgs`). Así, después de un switchover o failover, el nuevo principal puede volver a cargar el padrón sin cambiar el directorio de Oracle | Andrés | Hecho (2026-10-28, en las dos VMs) |
| Crear las dos bases con juego de caracteres `AL32UTF8` (los nombres del padrón traen Ñ y tildes) y el principal en `FORCE LOGGING` (Data Guard), para que la carga del padrón llegue completa a la standby | Andrés | Hecho (`AL32UTF8` en `dbca`; `FORCE LOGGING` en S3) |
| Espacio para archivos de redo archivados: la carga del padrón (3,7 millones de filas) genera bastante redo de una vez | Andrés | Hecho (FRA de 20 GB con 1,63 GB usados; 58 GB libres en disco) |
| `SGS_CIERRE_DIARIO` y `SGS_PREMIACION` tienen 1 fila (las crea el proceso). Para la regla de 5 filas por tabla: generar los cierres de días anteriores con `SGS_PKG_PROCESOS.cerrar_dia(fecha)` y decidir cómo completar las premiaciones (se hace al final, con los datos definitivos) | Isaac | Hecho (2026-10-28) |

## Reparto final (acordado 2026-10-29)

Los documentos técnicos (manuales, diccionario, documentación del código, matriz de trazabilidad, guion de la defensa) los hace Isaac con el contexto del repo. Andrés hace lo que se ejecuta en los servidores y lo sube al repo por PR, como siempre.

| Pendiente | Responsable |
|---|---|
| S7: pruebas de situaciones problemáticas en la standby, subidas a `servidores/` | Andrés (hecho 2026-10-29: `servidores/s7_situaciones.md`) |
| Limpieza de `ts_prueba_rman` y `system.prueba_dg` en `SGSPDB` (después de S7) | Andrés |
| Diccionario de datos de las 57 tablas | Isaac (hecho 2026-10-29) |
| Matriz de trazabilidad de `guia.md` al día | Isaac |
| Revisión de la documentación interna del código (incluidos `11_standby.sql` y los `.sh`) | Isaac |
| Manuales: instalación y despliegue, administración del standby (con S7), técnico de administración y mantenimiento | Isaac |
| Antes de la defensa: destinatarios con el correo que indique, revocar la llave de Tailscale | Isaac |
| C1: prueba de punta a punta sobre los servidores (7 nov) | Los dos |
| Guion (Isaac), ensayo y plan B de red de la defensa (8 nov) | Los dos |


## Carril S — Servidores (Andrés)

**Último avance (2026-10-28, noche):** S6 completo: switchover, failover (caída simulada de `SGSPRI`), reincorporación con `REINSTATE` y regreso a los roles originales, sin pérdida de datos. Detalle en [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md). Antes (2026-10-28, tarde): S5 casi completo (falta solo el job diario). Antes: Tailscale en las dos VMs y conexión a `SGSPDB` por Tailscale probada; `local_listener` corregido en ambos servidores. **Siguiente sesión: S5 (RMAN).** Antes (2026-10-26): **S3 completo: Data Guard funcionando** (`SGSSTB` standby física en Active Data Guard; probado con un dato que viaja de `SGSPRI` a `SGSSTB`). Detalle en [`servidores/s3_dataguard.md`](../servidores/s3_dataguard.md). Antes: base de datos creada en `SGSPRI` (`DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, ARCHIVELOG, PDB `SGSPDB`); detalle en [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md). Antes: S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

### Después

- [x] Crear la base en `SGSPRI` con `dbca`.
- [x] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS`.
- [x] Avisar a Isaac que `SGSPDB` ya existe en `SGSPRI` (punto I1).
- [x] I1, preparación de las VMs (puerto de Gmail, wallet, carpeta del padrón, parámetros) en `SGSPRI` y `SGSSTB`: [`servidores/i1_preparacion_vms.md`](../servidores/i1_preparacion_vms.md).
- [ ] Antes de la defensa: cambiar las contraseñas de `SYS`, `SYSTEM` y `PDBADMIN` por unas fuertes.
- [x] Tailscale en ambas VMs (sin exit node): [`servidores/tailscale.md`](../servidores/tailscale.md). `SGSPRI` = `100.76.209.30`, `SGSSTB` = `100.69.133.78`.
- [ ] Pedirle a Isaac que revoque la llave de Tailscale ya usada.
- [x] Conexión a `SGSPDB` por la IP de Tailscale probada desde `SGSSTB` (`sqlplus system@100.76.209.30:1521/sgspdb`).
- [ ] Isaac prueba la conexión desde DBeaver en su Mac (datos en [`servidores/tailscale.md`](../servidores/tailscale.md)).
- [x] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).
- [x] Rutina de arranque y apagado probada (2026-10-27): [`servidores/operacion_diaria.md`](../servidores/operacion_diaria.md).
- [x] Hora sincronizada con `chronyd` en los dos servidores.
- [x] S4: administración parametrizada del standby: archivo cada `STB_MINUTOS_ARCHIVO` min (y aviso si los redo no miden `STB_MB_ARCHIVO`), traslado cada `STB_MINUTOS_TRASLADO` min y a demanda, borrado a los `STB_DIAS_BORRADO` días en los dos servidores. Jobs `SGS_JOB_STB_*` en `bd/11_standby.sql`. Ver [`servidores/s4_standby.md`](../servidores/s4_standby.md).
- [x] S5: RMAN configurado; full, incremental, restore y recovery probados; copia a `SGSSTB`; script a demanda (`servidores/scripts/respaldo_rman.sh`). Ver [`servidores/s5_rman.md`](../servidores/s5_rman.md).
- [x] S5: job diario `SGS_JOB_RESPALDO_DIARIO` (de `SGS_ADMIN`, con la credencial `SGS_CRED_ORACLE`) a la hora de `RESP_HORA_DIARIO` (1:00 a. m.), probado a demanda; `respaldo_rman.sh` instalado en las dos VMs y solo respalda la PRIMARY. Script oficial `bd/11_standby.sql`. Ver [`servidores/s5_rman.md`](../servidores/s5_rman.md) §8 y §9.
- [ ] Borrar los objetos de prueba de `SGSPDB`: tablespaces `ts_prueba_rman` y `ts_prueba_s7`, tablas `system.prueba_dg` y `system.prueba_s7_*` (nolog, dano, ts, fra, carga).
- [x] S6: switchover, failover y reincorporación probados con el broker `sgs_dg`: [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md).
- [x] S7: situaciones problemáticas en la standby, probadas en las VMs (NOLOGGING, datafile nuevo, standby apagada, redo faltante, FRA llena, clave de SYS, carga masiva): [`servidores/s7_situaciones.md`](../servidores/s7_situaciones.md).
- [ ] Después de S7: datos o capturas de los servidores que pida Isaac para los manuales (por PR); leer el guion y los manuales y avisar si algo no calza.
- [ ] Al final, con Isaac: C1 (prueba de punta a punta en los servidores, Andrés maneja la HP), ensayo de la defensa (incluido el plan B de red: hotspot + Tailscale) y, el día de la defensa, encender las VMs con tiempo y revisar `SHOW CONFIGURATION` en `SUCCESS`.
