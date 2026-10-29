---
titulo: Manual de Administración del Standby
---

# Introducción

Este manual explica cómo se administra la base standby del Sistema de Gestión de Supermercados (SGS): cómo se opera y se vigila la sincronización, los procesos automáticos que la mantienen, los respaldos con RMAN, los cambios de rol entre los servidores y las situaciones que pueden causar problemas en la standby, con su solución. La instalación de los dos servidores y de Data Guard está en el manual de instalación y despliegue.

Todos los procedimientos de este manual se ejecutaron en los servidores del proyecto. En los comandos, `SGSPRI` y `SGSSTB` son los dos servidores; los de SQL se ejecutan como `oracle` en `sqlplus / as sysdba` desde la raíz del contenedor, salvo que se indique otra cosa.

## Arquitectura

![Arquitectura del despliegue](docs/manuales/imagenes/arquitectura.png)

| Elemento | Valor |
|---|---|
| Servidor principal | `SGSPRI` (`192.168.56.101`), `DB_UNIQUE_NAME = SGSPRI` |
| Servidor standby | `SGSSTB` (`192.168.56.102`), `DB_UNIQUE_NAME = SGSSTB` |
| Base | CDB `SGS` con la PDB `SGSPDB` |
| Tipo de standby | Física, abierta en solo lectura mientras aplica (Active Data Guard) |
| Envío del redo | Asíncrono (`ASYNC`) por la red interna |
| Modo de protección | MaxPerformance |
| Configuración del broker | `sgs_dg` |
| Fast-Start Failover | Deshabilitado: los cambios de rol se hacen a mano |
| Flashback Database | Activo en las dos bases |
| Fast Recovery Area | `/opt/oracle/fast_recovery_area`, 20 GB en cada servidor |

## Conceptos

- **Redo y archivos archivados.** Todo cambio en la principal queda en el redo. Con el envío en tiempo real, la standby recibe el redo mientras se genera (en sus standby redo logs) y lo aplica de inmediato; además, cada vez que un redo log se cierra se archiva y viaja completo.
- **Transport lag y apply lag.** El retraso de transporte es cuánto redo generado en la principal todavía no llegó a la standby; el de aplicación, cuánto llegó pero todavía no se aplicó. En operación normal los dos están en 0.
- **Gap.** Un hueco en la secuencia de archivos de la standby, porque estuvo apagada o porque un archivo no llegó. Data Guard pide los archivos que faltan a la principal (`fal_server`) y el gap se cierra solo mientras esos archivos existan.
- **MaxPerformance.** La principal confirma cada transacción sin esperar a la standby, así que nunca se frena por ella. A cambio, si la principal cae de golpe, se podrían perder los últimos segundos de redo que no llegaron.
- **Switchover y failover.** El switchover es un cambio de roles planeado y sin pérdida de datos (por ejemplo, para dar mantenimiento a la principal). El failover convierte la standby en principal cuando la principal cayó.
- **Reincorporación.** Después de un failover, la base que cayó se reincorpora como standby con Flashback Database, sin volver a copiarla.

# Operación diaria

## Encender y apagar

Las bases no arrancan solas al encender las VMs. Como el rol de cada servidor puede cambiar después de un switchover o failover, primero se monta cada base y se revisa su rol.

**Encender** (en cada servidor, como `oracle`):

```
lsnrctl start
sqlplus / as sysdba
STARTUP MOUNT;
SELECT db_unique_name, database_role FROM v$database;
```

En el que diga `PRIMARY` (normalmente `SGSPRI`), primero:

```
ALTER DATABASE OPEN;
SELECT name, database_role, open_mode FROM v$database;   -- PRIMARY  READ WRITE
SHOW PDBS                                                 -- SGSPDB  READ WRITE
```

En el que diga `PHYSICAL STANDBY` (normalmente `SGSSTB`):

```
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
SELECT database_role, open_mode FROM v$database;         -- PHYSICAL STANDBY  READ ONLY WITH APPLY
```

El broker arranca solo la aplicación del redo; puede tardar hasta un minuto en pasar de `READ ONLY` a `READ ONLY WITH APPLY`. Si no pasa, desde el broker: `EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';` (con el broker activo no se usa `RECOVER MANAGED STANDBY DATABASE`).

![La standby abierta y aplicando](servidores/capturas/operacion/04_sgsstb_read_only_with_apply.png)

**Apagar:** primero la standby y después la principal (`SHUTDOWN IMMEDIATE;` en cada una), y luego cada VM como `root` (`shutdown -h now`).

> Antes de suspender o apagar la HP se apagan siempre las VMs. Si la HP se suspende con las VMs encendidas, sus relojes se atrasan; `chronyd` está configurado con `makestep 1 -1` para corregirlo de golpe al volver, pero los jobs que tocaban mientras estuvo suspendida se corren tarde.

## Revisar la sincronización

Desde la principal, con el broker:

```
dgmgrl sys@SGSPRI
SHOW CONFIGURATION;          -- Configuration Status: SUCCESS
SHOW DATABASE 'SGSSTB';      -- Transport Lag, Apply Lag, Real Time Query, Database Status
```

![Standby al día: lags en 0 y SUCCESS](docs/evidencias/capturas/I1_04_broker_tras_instalacion.jpeg)

En la standby, con SQL:

```
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag');
SELECT * FROM v$archive_gap;                                        -- sin filas: no hay gap
SELECT MAX(sequence#) AS ultima_aplicada FROM v$archived_log WHERE applied = 'YES';
SELECT name, role, action FROM v$dataguard_process ORDER BY name;  -- MRP0 y los procesos que reciben el redo
```

Para comprobar que la sincronización funciona en el momento, se fuerza un archivo nuevo en la principal y se ve que la secuencia aplicada sube en la standby:

```
-- SGSPRI
ALTER SYSTEM SWITCH LOGFILE;
-- SGSSTB, unos segundos después
SELECT MAX(sequence#) AS ultima_aplicada FROM v$archived_log WHERE applied = 'YES';
```

El alert log de la standby está en `/opt/oracle/diag/rdbms/sgsstb/SGSSTB/trace/alert_SGSSTB.log` y el de la principal en `/opt/oracle/diag/rdbms/sgspri/SGSPRI/trace/alert_SGSPRI.log`.

| Estado del broker | Qué significa | Qué hacer |
|---|---|---|
| `SUCCESS` | Todo en orden | Nada |
| `WARNING` con `ORA-16854` o `ORA-16810` justo después de un cambio de rol | La nueva standby todavía no recibe su primer archivo | Esperar un minuto; pasa sola a `SUCCESS` |
| `WARNING` con `ORA-16855` | El transport lag superó el límite | Revisar si hay un gap o la FRA llena (situaciones problemáticas) |
| `(disabled)` con `ORA-16906` | La standby se apagó | Encenderla y `ENABLE DATABASE 'SGSSTB';` |
| `ERROR` con `ORA-1034` | La principal no responde | Revisar la principal; si cayó, evaluar el failover |

# Administración parametrizada

La standby se administra sola con los valores de la tabla `SGS_PARAMETRO`. Cambiar un valor cambia el comportamiento sin tocar código.

| Parámetro | Valor | Qué controla |
|---|---|---|
| `STB_MINUTOS_ARCHIVO` | 5 | Tiempo máximo entre archivos de actualización |
| `STB_MB_ARCHIVO` | 50 | Tamaño de un archivo de actualización (el de los redo logs) |
| `STB_MINUTOS_TRASLADO` | 10 | Cada cuánto se traslada la información a la standby |
| `STB_DIAS_BORRADO` | 3 | Antigüedad de los archivos ya trasladados y aplicados que se borran |
| `RESP_HORA_DIARIO` | 1 | Hora del respaldo diario |

Cada proceso es un job de `SGS_ADMIN` que llama un procedimiento de `SGS_PKG_STANDBY`. El procedimiento lee el parámetro **en el momento de ejecutarse** y se lo pasa a un script de Linux que corre como `oracle` (`/home/oracle/scripts`, igual en los dos servidores). El script solo actúa si su base es la principal (en la standby termina con el código 4) y lo que hay que hacer en la otra base lo hace por SSH. Cada ejecución deja un log en `/home/oracle/logs`, y si el script falla el error queda en `SGS_BITACORA_ERROR`.

| Job | Procedimiento o script | Programación |
|---|---|---|
| `SGS_JOB_STB_ARCHIVO` | `SGS_PKG_STANDBY.aplicar_archivo` → `standby_archivo.sh` | Diario, 00:10 |
| `SGS_JOB_STB_TRASLADO` | `SGS_PKG_STANDBY.trasladar` → `standby_traslado.sh` | Cada `STB_MINUTOS_TRASLADO` minutos |
| `SGS_JOB_STB_BORRADO` | `SGS_PKG_STANDBY.borrar_archivos` → `standby_borrado.sh` | Diario, 00:20 |
| `SGS_JOB_RESPALDO_DIARIO` | `respaldo_rman.sh` | Diario, a la hora de `RESP_HORA_DIARIO` |

Cualquiera se ejecuta a demanda, como `SGS_ADMIN` en la principal:

```
EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_STB_TRASLADO', use_current_session => TRUE);
```

## Archivo de actualización cada 5 minutos o 50 MB

- **Por tiempo:** el procedimiento aplica `STB_MINUTOS_ARCHIVO` × 60 segundos en la propiedad `ArchiveLagTarget` del broker, en las dos bases (para que siga valiendo después de un switchover). Oracle cierra entonces un archivo como máximo cada 5 minutos aunque haya poco movimiento. Se cambia con el broker y no con `ALTER SYSTEM` para que la configuración no quede marcada como inconsistente.
- **Por tamaño:** los redo logs miden 50 MB, así que cada 50 MB de cambios se cierra un archivo. El procedimiento compara `STB_MB_ARCHIVO` con el tamaño de los redo logs y, si no coinciden, avisa al DBA por correo. Cambiar el tamaño de los redo logs con Data Guard activo se hace a mano, en una ventana de mantenimiento.

```
SHOW PARAMETER archive_lag_target      -- 300 en las dos bases
```

![ArchiveLagTarget aplicado en las dos bases al cambiar el parámetro a 10 minutos](servidores/capturas/s4_standby/14_job_archivo_con_parametro_10_sgspri_600.png)

## Traslado cada 10 minutos y a demanda

El broker envía el redo de forma continua. Además, cada `STB_MINUTOS_TRASLADO` minutos el job ejecuta `ALTER SYSTEM ARCHIVE LOG CURRENT`, que cierra el archivo actual y lo envía completo a la standby, donde se aplica. Si el parámetro cambia, el job se reprograma solo con el valor nuevo.

Para demostrarlo en la revisión, en `SGSSTB` antes y después de ejecutar el job a demanda:

```
SELECT MAX(sequence#) AS ultima_aplicada FROM v$archived_log WHERE applied = 'YES';
```

![Secuencia aplicada en la standby después del traslado a demanda](servidores/capturas/s4_standby/19_sgsstb_aplicada_despues_59.png)

## Borrado a los 3 días en los dos servidores

El job borra con RMAN, en la principal y por SSH en la standby, los archivos archivados con más de `STB_DIAS_BORRADO` días:

```
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-3';
```

Las dos bases tienen la regla `ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY`: en la principal solo se borra lo que ya se trasladó y se aplicó en la standby, y en la standby solo lo que ya se aplicó. RMAN se niega a borrar un archivo que todavía hace falta.

![Borrado de archivos en los dos servidores](servidores/capturas/s4_standby/29_borrado_conteos_ambos_servidores.png)

# Respaldos y recuperación

## Estrategia

| Elemento | Valor |
|---|---|
| Respaldo completo | Incremental nivel 0 de toda la base (raíz, `PDB$SEED` y `SGSPDB`), los domingos |
| Respaldo incremental | Nivel 1 (solo los bloques que cambiaron), los demás días |
| Archivos de redo | Se respaldan con cada respaldo (`PLUS ARCHIVELOG`) |
| Retención | `REDUNDANCY 1`: un respaldo completo vigente; lo obsoleto se borra en cada respaldo |
| Control file y spfile | Respaldo automático después de cada respaldo |
| Compresión | `COMPRESSED BACKUPSET` |
| Copia al otro servidor | `rsync` a `/opt/oracle/respaldos_sgspri` en `SGSSTB` (o `/opt/oracle/respaldos_sgsstb` en `SGSPRI` cuando los roles están invertidos) |

El script `respaldo_rman.sh` hace el respaldo, la limpieza (`CROSSCHECK` y `DELETE OBSOLETE`) y la copia, y termina con un código: `0` todo bien, `1` error de RMAN, `2` nivel inválido, `3` error al copiar, `4` la base de ese servidor no es la principal, `5` servidor desconocido o base no disponible.

## Respaldo a demanda

Como `SGS_ADMIN` en la principal (es lo que pide el enunciado para la revisión):

```
EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO', use_current_session => TRUE);
```

O directamente como `oracle` en la principal, indicando el nivel:

```
~/scripts/respaldo_rman.sh 0; echo "Resultado: $?"     # completo
~/scripts/respaldo_rman.sh 1; echo "Resultado: $?"     # incremental
ssh oracle@sgsstb "ls -lt /opt/oracle/respaldos_sgspri/backupset/"
```

![Respaldo a demanda desde el job](servidores/capturas/s5_rman/30_job_respaldo_a_demanda_succeeded.png)

Para revisar los respaldos, `rman target /` → `LIST BACKUP SUMMARY;` (`LV 0` completos, `LV 1` incrementales, `LV A` archivos de redo, `LV F` control file y spfile).

## Restaurar y recuperar un datafile

Este es el procedimiento probado cuando se pierde un archivo de datos con la base abierta. En la prueba se usó un tablespace de prueba: se respaldó, se insertó un dato después del respaldo y se borró su datafile.

1. Síntoma al usar el tablespace:

```
ALTER TABLESPACE ts_prueba_rman ONLINE;
-- ORA-01157: cannot identify/lock data file 13
```

2. Restaurar el archivo desde el respaldo y aplicar el redo posterior (`rman target /`):

```
RESTORE TABLESPACE SGSPDB:ts_prueba_rman;
RECOVER TABLESPACE SGSPDB:ts_prueba_rman;
```

3. Poner el tablespace en línea (en `SGSPDB`) y comprobar los datos:

```
ALTER SESSION SET CONTAINER = SGSPDB;
ALTER TABLESPACE ts_prueba_rman ONLINE;
SELECT * FROM system.prueba_rman;      -- el dato del respaldo y el posterior
```

El `RESTORE` deja el archivo como estaba en el respaldo; el `RECOVER` le aplica los cambios posteriores desde los archivos de redo. Si se intenta poner en línea solo con el `RESTORE`, Oracle responde `ORA-01113: file needs media recovery`.

![Datos recuperados después del restore y recovery](servidores/capturas/s5_rman/17_datos_recuperados.png)

# Cambios de rol

Los cambios de rol se hacen con el broker, como `oracle`. Los nombres de las bases se escriben **entre comillas y en mayúscula** (`'SGSSTB'`): sin comillas, el failover respondió `ORA-16600` aunque la sesión estaba en la base correcta.

## Switchover

Cambio planeado, sin pérdida de datos. Desde `dgmgrl sys@SGSPRI`:

```
VALIDATE DATABASE 'SGSSTB';      -- Ready for Switchover: Yes
SWITCHOVER TO 'SGSSTB';          -- Switchover succeeded, new primary is "SGSSTB"
SHOW CONFIGURATION;              -- sgsstb Primary, sgspri Physical standby
```

El broker convierte `SGSSTB` en principal, reinicia `SGSPRI` y la deja como standby, en unos 30 a 40 segundos. Justo después puede aparecer `WARNING` con `ORA-16854` mientras la nueva standby recibe su primer archivo; en menos de un minuto pasa a `SUCCESS`.

![Switchover a SGSSTB](docs/evidencias/capturas/I4_08_switchover_a_sgsstb.jpeg)

Con `SGSSTB` como principal se comprobó que el sistema completo funciona sin cambiar nada: los 19 jobs, el correo, las operaciones del sistema, el respaldo (que respalda `SGSSTB` y copia a `SGSPRI`), el traslado y la carga del padrón, y que lo escrito en `SGSSTB` llega a `SGSPRI`.

**Regreso a los roles normales:** `SWITCHOVER TO 'SGSPRI';` y esperar `SUCCESS` (puede aparecer `ORA-16810` unos segundos).

## Failover

Cuando la principal cae y no se puede recuperar a tiempo. Desde la standby, `dgmgrl sys@SGSSTB`:

```
SHOW CONFIGURATION;              -- sgspri: ORA-1034: ORACLE not available; Configuration Status: ERROR
VALIDATE DATABASE 'SGSSTB';      -- Ready for Failover: Yes (Primary Not Running)
FAILOVER TO 'SGSSTB';            -- Failover succeeded, new primary is "SGSSTB"
SHOW CONFIGURATION;              -- sgsstb Primary; sgspri (disabled) ORA-16661
```

El failover tardó unos 15 segundos y no se perdieron datos: la última fila escrita en `SGSPRI` antes de la caída estaba en `SGSSTB`. `ORA-16661` es normal: `SGSPRI` queda fuera hasta reincorporarla.

![Failover a SGSSTB](servidores/capturas/s6_switchover_failover/12_failover_a_sgsstb.png)

## Reincorporación

Cuando la base que cayó vuelve a funcionar, se monta (sin abrirla) y se reincorpora desde la nueva principal:

```
-- En SGSPRI
sqlplus / as sysdba
STARTUP MOUNT;
-- Desde dgmgrl sys@SGSSTB
REINSTATE DATABASE 'SGSPRI';     -- Reinstatement of database "SGSPRI" succeeded
SHOW CONFIGURATION;              -- sgsstb Primary, sgspri Physical standby, SUCCESS
```

El broker regresa `SGSPRI` con Flashback Database al momento del failover, la convierte en standby, la reinicia y le activa la aplicación del redo; lo escrito en `SGSSTB` durante la caída llega a `SGSPRI`. Después se vuelve a los roles normales con `SWITCHOVER TO 'SGSPRI';`.

![Reincorporación de SGSPRI como standby](servidores/capturas/s6_switchover_failover/16_reinstate_sgspri_success.png)

## Reconectar el cliente

Mientras `SGSSTB` es la principal, los clientes se conectan a su IP de Tailscale (`100.69.133.78`, servicio `sgspdb`); en DBeaver, con las conexiones `SGSSTB - …`. Al volver a los roles normales se usan otra vez las de `SGSPRI` (`100.76.209.30`). El respaldo y los procesos del standby no necesitan cambios: sus scripts detectan cuál base es la principal.

| Situación | Dónde | Comando |
|---|---|---|
| Ver el estado | Cualquiera | `SHOW CONFIGURATION;` / `SHOW DATABASE 'SGSSTB';` |
| Cambio planeado | Principal o standby | `SWITCHOVER TO 'SGSSTB';` (o `'SGSPRI'`) |
| Caída de la principal | Standby | `FAILOVER TO 'SGSSTB';` |
| Reincorporar la que cayó | Nueva principal, con la caída en `MOUNT` | `REINSTATE DATABASE 'SGSPRI';` |
| Pausar o reanudar la aplicación del redo | Standby, `dgmgrl /` | `EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';` / `'APPLY-ON'` |

# Situaciones problemáticas

Todas las acciones de la principal se replican en la standby, pero algunas causan problemas. Cada caso de esta sección se provocó a propósito en los servidores y se resolvió con el procedimiento descrito.

| Situación | Síntoma | Solución |
|---|---|---|
| Operación `NOLOGGING` | `ORA-01578` y `ORA-26040` al leer en la standby | Prevención: `FORCE LOGGING`; reparación: `RECOVER DATABASE NONLOGGED BLOCK` |
| Tablespace o datafile nuevo | Ninguno con `standby_file_management=AUTO`; el datafile aparece `RECOVER` | Cerrar y abrir la PDB en la standby |
| Standby apagada (gap) | Broker: `(disabled)` con `ORA-16906` | Encenderla y `ENABLE DATABASE`; el gap se cierra solo |
| Redo faltante | Gap que no se cierra y transport lag creciendo | `RECOVER STANDBY DATABASE FROM SERVICE` |
| FRA llena | `ORA-19809`, `ORA-19804`, `ORA-16038`; broker `ORA-16855` | Liberar espacio o ampliar `db_recovery_file_dest_size` |
| Cambio de la clave de `SYS` | Ninguno: el cambio viaja a la standby | Cambiar la clave solo en la principal |
| Carga masiva | Apply lag mayor que 0 | Se recupera solo; vigilar los lags |

## Operación NOLOGGING

**Causa.** Una operación `NOLOGGING` (una tabla creada `NOLOGGING`, una carga con `APPEND`) no escribe redo, así que sus datos nunca llegan a la standby.

**Prevención.** La principal está en `FORCE LOGGING`, que obliga a generar redo aunque la operación diga `NOLOGGING`. Con la protección puesta, una tabla creada `NOLOGGING` llegó completa a la standby.

**Síntoma** (con la protección quitada a propósito por un momento), al leer la tabla en la standby:

```
-- ORA-01578: ORACLE data block corrupted (file # 12, block # 131)
-- ORA-26040: Data block was loaded using the NOLOGGING option
```

![El bloque sin redo en la standby](servidores/capturas/s7_situaciones/05_sgsstb_ora_26040.png)

**Solución.** Primero volver a proteger la principal y luego traer desde ella los bloques afectados:

```
ALTER DATABASE FORCE LOGGING;                              -- SGSPRI
-- SGSSTB, como oracle
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
rman target / <<< "RECOVER DATABASE NONLOGGED BLOCK;"
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
```

> Nunca se deja la principal en `NO FORCE LOGGING`. La carga del padrón es la operación más grande del sistema y debe llegar completa a la standby.

## Tablespace o datafile nuevo

**Causa.** La standby tiene que crear cada datafile nuevo en su propia ruta.

**Prevención.** `standby_file_management = AUTO` en las dos bases y `db_file_name_convert`, que traduce `SGSPRI` por `SGSSTB` en la ruta. Un tablespace creado en la principal se crea solo en la standby, con sus datos. Así se crearon los tablespaces del sistema al instalar el esquema.

**Detalle.** Con la PDB de la standby abierta en solo lectura, el datafile nuevo queda en estado `RECOVER` aunque sus datos sí se aplican. Se normaliza cerrando y abriendo la PDB en la standby, sin tocar la principal:

```
ALTER PLUGGABLE DATABASE SGSPDB CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
SELECT file#, status FROM v$datafile;            -- el datafile nuevo en ONLINE
```

![Datafile nuevo en línea después de reabrir la PDB](servidores/capturas/s7_situaciones/16_pdb_reabierta_datafile_online.png)

## Standby apagada y el gap

**Causa.** Mientras la standby está apagada, la principal sigue generando archivos que no puede enviar.

**Síntoma.** Al apagarla con `SHUTDOWN`, el broker la deshabilita: `sgsstb - Physical standby database (disabled)` con `ORA-16906: The member was shutdown`.

**Solución.** Encenderla (`STARTUP MOUNT`, abrir en solo lectura y abrir la PDB) y habilitarla en el broker. Data Guard pide a la principal los archivos que faltan y el gap se cierra solo:

```
-- dgmgrl sys@SGSPRI
ENABLE DATABASE 'SGSSTB';          -- Enabled.
SHOW CONFIGURATION;                -- SUCCESS
-- SGSSTB
SELECT * FROM v$archive_gap;       -- no rows selected
```

Lo escrito en la principal con la standby apagada apareció en la standby al reincorporarla.

![El gap recuperado](servidores/capturas/s7_situaciones/22_gap_recuperado_fila_501.png)

## Redo faltante

**Causa.** Se pierde un archivo de redo que la standby todavía no recibió (por ejemplo, se borró o se dañó el disco). A diferencia del caso anterior, ya no existe en ningún lado y el gap no se puede cerrar solo.

**Síntoma.** El transport lag crece, el broker muestra `ORA-16855` y `v$archive_gap` muestra el hueco, que no desaparece.

![Gap sin resolver por un archivo perdido](servidores/capturas/s7_situaciones/28_gap_106_sin_resolver.png)

**Solución.** Traer desde la principal solo los bloques que cambiaron, sin volver a crear la standby:

```
-- SGSSTB, como oracle
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
rman target sys@SGSSTB
RECOVER STANDBY DATABASE FROM SERVICE SGSPRI;
-- sqlplus / as sysdba
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
```

Después:

- La recuperación desactiva el flashback de la standby. Se vuelve a activar con la aplicación en pausa: `APPLY-OFF`, `ALTER DATABASE FLASHBACK ON;`, `APPLY-ON`.
- Se hace un respaldo en la principal (`respaldo_rman.sh 1`), para no depender del archivo perdido.

## FRA llena

**Causa.** La Fast Recovery Area guarda los archivos de redo, los respaldos y el flashback, y tiene un límite. Si se llena en la standby, no puede guardar el redo que recibe. En la principal sería más grave: la base deja de aceptar cambios.

**Síntoma.** En el alert log de la standby, `ORA-19809: limit exceeded for recovery files`, `ORA-19804` y `ORA-16038: log cannot be archived`; en el broker, transport lag creciendo con `ORA-16855`.

![FRA llena en la standby](servidores/capturas/s7_situaciones/38_fra_llena_ora19809.png)

**Solución.** Liberar espacio (borrar archivos ya aplicados o respaldos obsoletos: `DELETE OBSOLETE` o el job `SGS_JOB_STB_BORRADO`) o ampliar el límite:

```
SELECT ROUND(space_limit/1024/1024) AS mb_limite, ROUND(space_used/1024/1024) AS mb_usado FROM v$recovery_file_dest;
ALTER SYSTEM SET db_recovery_file_dest_size = 20G SCOPE=MEMORY;
```

En la prueba el límite se había bajado solo en memoria, por eso se restableció con `SCOPE=MEMORY`; para ampliarlo de forma permanente se usa `SCOPE=BOTH`. En cuanto hay espacio, la standby guarda lo pendiente y se pone al día sola.

## Cambio de la clave de SYS

**Causa posible.** Data Guard se autentica entre los servidores con la clave de `SYS` del archivo de contraseñas. En versiones anteriores, cambiarla en la principal sin copiar ese archivo a la standby cortaba el envío del redo.

**En Oracle 21c** el cambio viaja solo a la standby con el redo: después de cambiar la clave en la principal, el broker siguió en `SUCCESS` y se pudo entrar a la standby con la clave nueva.

**Procedimiento.** La clave de `SYS` se cambia **solo en la principal**, y no se copia el archivo de contraseñas:

```
ALTER USER SYS IDENTIFIED BY "<CLAVE_NUEVA>";
ALTER SYSTEM ARCHIVE LOG CURRENT;
```

Si la clave no entra, no se insiste (después de varios intentos fallidos se bloquea `SYS` por red): se entra con `sqlplus / as sysdba`, se revisa `SELECT account_status FROM v$pwfile_users WHERE username = 'SYS';`, se desbloquea con `ALTER USER SYS ACCOUNT UNLOCK;` si hace falta y se vuelve a fijar la clave.

## Carga masiva

**Causa.** Una carga grande, como la del padrón, genera mucho redo de golpe; la standby puede tardar en recibirlo y en aplicarlo. Con el envío asíncrono, la principal no se frena.

**Prueba.** Una carga de 3 000 000 filas (unos 500 MB de redo) en 36 segundos: los dos lags se mantuvieron en 0 durante toda la carga y las filas llegaron completas. Con la aplicación pausada (como si la standby fuera lenta), el apply lag subió a más de un minuto y, al reanudarla, se puso al día en segundos.

![Lags en 0 durante la carga masiva](servidores/capturas/s7_situaciones/47_lag_0_durante_la_carga.png)

**Procedimiento.** Las cargas masivas se hacen fuera de las horas de uso, vigilando `SHOW DATABASE 'SGSSTB';` o `v$dataguard_stats` durante la carga, y no se hace un switchover ni un failover hasta que los dos lags estén en 0.

# Lista para la revisión

Lo que se puede demostrar a demanda durante la revisión:

| Demostración | Comando |
|---|---|
| Estado de la configuración y de la sincronización | `dgmgrl sys@SGSPRI` → `SHOW CONFIGURATION;` y `SHOW DATABASE 'SGSSTB';` |
| Un dato escrito en la principal aparece en la standby | Insertar en `SGSPRI`, `ALTER SYSTEM SWITCH LOGFILE;` y consultar en `SGSSTB` |
| La standby no acepta escrituras | Un `INSERT` en `SGSSTB` responde `ORA-16000` |
| Traslado a demanda | `RUN_JOB('SGS_ADMIN.SGS_JOB_STB_TRASLADO')` y la secuencia aplicada en `SGSSTB` antes y después |
| Archivo cada N minutos parametrizado | Cambiar `STB_MINUTOS_ARCHIVO`, `RUN_JOB('SGS_ADMIN.SGS_JOB_STB_ARCHIVO')` y `SHOW PARAMETER archive_lag_target` en las dos |
| Borrado parametrizado | `RUN_JOB('SGS_ADMIN.SGS_JOB_STB_BORRADO')` y su log |
| Respaldo a demanda copiado a la standby | `RUN_JOB('SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO')` y la carpeta de respaldos en `SGSSTB` |
| Switchover y regreso | `SWITCHOVER TO 'SGSSTB';` y `SWITCHOVER TO 'SGSPRI';` |
| Failover y reincorporación | `SHUTDOWN ABORT` en `SGSPRI`, `FAILOVER TO 'SGSSTB';`, `STARTUP MOUNT` y `REINSTATE DATABASE 'SGSPRI';` |
