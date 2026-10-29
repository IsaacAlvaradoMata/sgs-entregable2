# S7 — Situaciones problemáticas en la standby

Acciones en la principal (o en el servidor) que causan problemas en la standby, cómo se reconocen y cómo se resuelven. Cada caso se provocó a propósito en `SGSPRI` / `SGSSTB` y se resolvió con el procedimiento descrito. Capturas en [`capturas/s7_situaciones/`](capturas/s7_situaciones/).

Estado: **S7 completo** (7 casos probados el 2026-10-29).

| # | Situación | Síntoma | Solución |
|---|---|---|---|
| 1 | Operación `NOLOGGING` | `ORA-01578` + `ORA-26040` al leer en la standby | Prevención: `FORCE LOGGING`. Reparación: `RECOVER DATABASE NONLOGGED BLOCK` |
| 2 | Tablespace o datafile nuevo | Ninguno con `standby_file_management=AUTO`; el archivo nuevo aparece `RECOVER` | Cerrar y abrir la PDB en la standby |
| 3 | Standby apagada (gap) | Broker: `(disabled)` `ORA-16906` | Encenderla y `ENABLE DATABASE`; el gap se recupera solo |
| 4 | Redo faltante | Gap en `v$archive_gap` que no se cierra; `Transport Lag` creciendo | `RECOVER STANDBY DATABASE FROM SERVICE` |
| 5 | FRA llena | `ORA-19809`, `ORA-19804`, `ORA-16038`; broker `ORA-16855` | Liberar espacio o ampliar `db_recovery_file_dest_size` |
| 6 | Cambio de clave de SYS | Ninguno: el cambio viaja a la standby | Cambiar la clave solo en la principal |
| 7 | Lag en una carga masiva | `apply lag` > 0 en `v$dataguard_stats` | Se recupera solo; monitorear |

Consultas de diagnóstico usadas en todos los casos:

```
-- en la principal, con el broker
dgmgrl sys@SGSPRI
SHOW CONFIGURATION;
SHOW DATABASE 'SGSSTB';            -- Transport Lag, Apply Lag, avisos ORA-

-- en la standby
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag');
SELECT * FROM v$archive_gap;       -- huecos en la secuencia
SELECT MAX(sequence#) FROM v$archived_log WHERE applied = 'YES';
-- alert log: /opt/oracle/diag/rdbms/sgsstb/SGSSTB/trace/alert_SGSSTB.log
```

Para pausar y reanudar la aplicación de redo en la standby (lo usan varios casos), en `SGSSTB` como `oracle`:

```
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
```

---

## 1. Operación NOLOGGING

**Causa:** una operación `NOLOGGING` (crear una tabla `NOLOGGING`, una carga con `APPEND`) no escribe redo. Sin redo, los datos nunca llegan a la standby.

**Prevención:** `SGSPRI` está en `FORCE LOGGING` desde S3, lo que obliga a generar redo aunque la operación diga `NOLOGGING`. Prueba con la protección puesta:

```
SELECT force_logging FROM v$database;                 -- YES
-- en SGSPDB
CREATE TABLE system.prueba_s7_nolog NOLOGGING AS
  SELECT LEVEL AS id, 'Fila ' || LEVEL AS texto FROM dual CONNECT BY LEVEL <= 1000;
SELECT logging FROM dba_tables WHERE table_name = 'PRUEBA_S7_NOLOG';   -- NO
-- en SGSSTB
SELECT COUNT(*) FROM system.prueba_s7_nolog;          -- 1000: llegó completa
```

**Sin la protección** (se quitó un momento para ver el daño):

```
ALTER DATABASE NO FORCE LOGGING;                      -- en CDB$ROOT de SGSPRI
CREATE TABLE system.prueba_s7_dano TABLESPACE users NOLOGGING AS
  SELECT LEVEL AS id, 'Fila ' || LEVEL AS texto FROM dual CONNECT BY LEVEL <= 1000;
SELECT file#, unrecoverable_time FROM v$datafile WHERE unrecoverable_time > SYSDATE - 1/24;   -- datafile 12
```

**Síntoma** en la standby:

```
SELECT COUNT(*) FROM system.prueba_s7_dano;
-- ORA-01578: ORACLE data block corrupted (file # 12, block # 131)
-- ORA-26040: Data block was loaded using the NOLOGGING option
```

**Solución:** primero volver a proteger la principal y luego traer los bloques desde ella.

```
ALTER DATABASE FORCE LOGGING;                         -- SGSPRI
-- SGSSTB, como oracle
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
rman target / <<< "RECOVER DATABASE NONLOGGED BLOCK;"     -- datafile 12: 3 bloques examinados, 0 pendientes
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
SELECT COUNT(*) FROM system.prueba_s7_dano;           -- 1000
```

> Nunca dejar la principal en `NO FORCE LOGGING`. La carga del padrón es la operación más grande del sistema y debe llegar completa a la standby.

## 2. Tablespace o datafile nuevo

**Causa:** la standby tiene que crear cada datafile nuevo en su propia ruta.

**Prevención:** `standby_file_management = AUTO` (en las dos bases) y `db_file_name_convert`, que cambia `SGSPRI` por `SGSSTB` en la ruta.

```
-- SGSPRI, en SGSPDB (la base no tiene carpeta por defecto: sin ruta da ORA-02236)
CREATE TABLESPACE ts_prueba_s7 DATAFILE '/opt/oracle/oradata/SGSPRI/SGSPDB/ts_prueba_s7_01.dbf' SIZE 10M;
CREATE TABLE system.prueba_s7_ts TABLESPACE ts_prueba_s7 AS SELECT LEVEL AS id FROM dual CONNECT BY LEVEL <= 500;
-- SGSSTB
SELECT name, status FROM v$datafile WHERE name LIKE '%ts_prueba_s7%';
-- /opt/oracle/oradata/SGSSTB/SGSPDB/ts_prueba_s7_01.dbf   RECOVER
SELECT COUNT(*) FROM system.prueba_s7_ts;             -- 500
```

**Detalle:** con la PDB de la standby abierta en solo lectura, el datafile nuevo queda en `RECOVER` aunque sus datos sí se aplican. Se normaliza cerrando y abriendo la PDB en la standby (la principal no se toca):

```
ALTER PLUGGABLE DATABASE SGSPDB CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
SELECT file#, status FROM v$datafile WHERE file# = 17;   -- ONLINE
```

## 3. Standby apagada y el gap

**Causa:** mientras la standby está apagada, la principal sigue generando archivos que no puede enviar (gap).

**Síntoma:** al apagarla a mano con `SHUTDOWN`, el broker la deshabilita:

```
SHOW CONFIGURATION;
-- sgsstb - Physical standby database (disabled)
--   ORA-16906: The member was shutdown.
```

**Solución:** encenderla y volver a habilitarla en el broker; Data Guard pide los archivos que faltan a la principal (siguen en su disco) y el gap se recupera solo.

```
-- SGSSTB
STARTUP MOUNT;
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
-- SGSPRI
dgmgrl sys@SGSPRI
ENABLE DATABASE 'SGSSTB';          -- Enabled.
SHOW CONFIGURATION;                -- SUCCESS
-- SGSSTB
SELECT * FROM v$archive_gap;       -- no rows selected
```

Prueba: la fila escrita en `SGSPRI` con la standby apagada (501) apareció en `SGSSTB` al reincorporarla.

## 4. Redo faltante

**Causa:** se pierde un archivo de redo que la standby todavía no recibió (borrado, disco dañado). A diferencia del caso 3, ya no existe en ningún lado, así que el gap no se puede cerrar solo.

**Simulación:** con la standby apagada se generaron las secuencias 105 a 107 en `SGSPRI` y se borró la 106 (`rm` del archivo y `CROSSCHECK ARCHIVELOG SEQUENCE 106` en RMAN).

**Síntoma:**

```
SHOW DATABASE 'SGSSTB';
-- Transport Lag: 5 minutes 4 seconds (creciendo)   Apply Lag: (unknown)
-- ORA-16855: transport lag has exceeded specified threshold      WARNING
SELECT * FROM v$archive_gap;       -- LOW_SEQUENCE# 106  HIGH_SEQUENCE# 106
```

**Solución:** traer desde la principal solo los bloques que cambiaron, sin recrear la standby. RMAN se conecta con la clave de SYS porque también entra a `SGSPRI`.

```
-- SGSSTB, como oracle
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
rman target sys@SGSSTB
RECOVER STANDBY DATABASE FROM SERVICE SGSPRI;     -- Finished recover
-- sqlplus / as sysdba
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
```

Después:

- La recuperación desactiva el flashback (RMAN avisa `flashback needs to be reenabled on standby open`). Se vuelve a activar con la aplicación en pausa: `APPLY-OFF`, `ALTER DATABASE FLASHBACK ON;` (`flashback_on = YES`), `APPLY-ON`.
- Se hace un respaldo en la principal (`respaldo_rman.sh 1`), para no depender del archivo perdido.

Resultado: lags en 0, `SUCCESS`, `v$archive_gap` vacío y la fila 502 (escrita detrás del hueco) en la standby.

## 5. FRA llena

**Causa:** la Fast Recovery Area guarda archivos de redo, respaldos y flashback, con un límite (20 GB). Si se llena en la standby, no puede guardar el redo que recibe. (En la principal sería peor: la base se detiene.)

**Simulación** en `SGSSTB`, con la aplicación en pausa (así lo recibido no se puede liberar) y el límite pegado a lo usado; `SCOPE=MEMORY` para no tocar el archivo de parámetros:

```
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-OFF';"
ALTER SYSTEM SET db_recovery_file_dest_size = 4480M SCOPE=MEMORY;   -- usados: 4459 MB
-- SGSPRI: carga de unos 170 MB de redo
CREATE TABLE system.prueba_s7_fra TABLESPACE users AS
  SELECT LEVEL AS id, RPAD('x', 150, 'x') AS texto FROM dual CONNECT BY LEVEL <= 1000000;
```

**Síntoma:**

```
-- v$recovery_file_dest: 4472 MB usados de 4480
-- alert_SGSSTB.log
-- ORA-19809: limit exceeded for recovery files
-- ORA-19804: cannot reclaim 46792192 bytes disk space from 4697620480 bytes limit
-- ORA-16038: log 12 sequence# 114 cannot be archived
-- broker: Transport Lag creciendo, ORA-16855
```

**Solución:** liberar espacio (borrar archivos ya aplicados o respaldos obsoletos: `DELETE OBSOLETE`, el job `SGS_JOB_STB_BORRADO`) o ampliar el límite:

```
ALTER SYSTEM SET db_recovery_file_dest_size = 20G SCOPE=MEMORY;
SHOW SPPARAMETER db_recovery_file_dest_size          -- 20G (el archivo de parámetros no cambió)
dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET STATE='APPLY-ON';"
```

Resultado: `SUCCESS`, lags en 0; aplicó lo pendiente a 2,35 MB/s.

## 6. Clave de SYS

**Causa posible:** Data Guard se autentica entre servidores con la clave de SYS del password file. En versiones anteriores, cambiarla en la principal sin copiar el archivo a la standby cortaba el envío de redo.

**Prueba:** en 21c el cambio viaja solo por el redo.

```
-- SGSPRI
ALTER USER SYS IDENTIFIED BY "<clave temporal>";
ALTER SYSTEM ARCHIVE LOG CURRENT;
dgmgrl sys@SGSSTB                    -- entra con la clave temporal: Connected to "SGSSTB"
SHOW CONFIGURATION;                  -- SUCCESS
-- regreso a la clave original
ALTER USER SYS IDENTIFIED BY "<clave original>";
ALTER SYSTEM ARCHIVE LOG CURRENT;
dgmgrl sys@SGSPRI, CONNECT sys@SGSSTB   -- entra con la original en las dos
```

**Procedimiento:** la clave de SYS se cambia **solo en la principal**; no se copia el password file. Si por error la clave no entra, no insistir (el perfil bloquea SYS por red tras varios intentos): entrar con `sqlplus / as sysdba`, revisar `SELECT account_status FROM v$pwfile_users WHERE username = 'SYS';`, desbloquear con `ALTER USER SYS ACCOUNT UNLOCK;` si hace falta y volver a fijar la clave.

## 7. Lag en una carga masiva

**Causa:** una carga grande (como el padrón) genera mucho redo de golpe; la standby tarda en recibirlo (transport lag) y en aplicarlo (apply lag). Con transporte `ASYNC` la principal no se frena.

**Prueba 1, condiciones normales:** 3 000 000 filas (unos 500 MB de redo) en 35,7 s. Consultando `v$dataguard_stats` en `SGSSTB` durante la carga, los dos lags se mantuvieron en `+00 00:00:00`, y las 3 000 000 filas llegaron. La standby aplica en tiempo real a la misma velocidad que genera la principal.

```
CREATE TABLE system.prueba_s7_carga TABLESPACE users AS
  SELECT ROWNUM AS id, RPAD('x', 150, 'x') AS texto
    FROM (SELECT 1 FROM dual CONNECT BY LEVEL <= 2000) a,
         (SELECT 1 FROM dual CONNECT BY LEVEL <= 1500) b;
```

(Con `CONNECT BY LEVEL <= 3000000` directo da `ORA-30009: Not enough memory for CONNECT BY operation`; el producto de dos listas pequeñas genera las mismas filas con poca memoria.)

**Prueba 2, standby lenta** (simulada con `APPLY-OFF`): otros 3 000 000 filas en 40,5 s. En `SGSSTB`:

```
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag');
-- transport lag  +00 00:00:00   (recibió todo)
-- apply lag      +00 00:01:17   (lo tiene sin aplicar)
```

Al reactivar (`APPLY-ON`) se puso al día en segundos: la primera consulta posterior ya mostró `apply lag +00 00:00:00`, con 6 000 000 filas en la standby.

**Procedimiento:** hacer las cargas masivas fuera de horas de uso, vigilar `SHOW DATABASE 'SGSSTB'` o `v$dataguard_stats` durante la carga y no hacer switchover ni failover hasta que los dos lags estén en 0.

---

## Objetos de prueba

Tablas `system.prueba_s7_nolog`, `prueba_s7_dano`, `prueba_s7_ts`, `prueba_s7_fra`, `prueba_s7_carga` y tablespace `ts_prueba_s7` en `SGSPDB`: se borran junto con `ts_prueba_rman` y `system.prueba_dg` (ver `notas/pendientes.md`).
