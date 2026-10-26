# S3 — Data Guard (SGSPRI → SGSSTB)

Pasos confirmados para convertir `SGSSTB` en standby física de `SGSPRI`. Capturas en [`capturas/s3_dataguard/`](capturas/s3_dataguard/).

Estado: **Data Guard funcionando.** `SGSSTB` es standby física de `SGSPRI`, abierta en solo lectura con aplicación en tiempo real (Active Data Guard). Probado con un dato insertado en `SGSPRI` que aparece en `SGSSTB`.

Comandos como `oracle` en `SGSPRI`, dentro de `sqlplus / as sysdba`, salvo que se indique otra cosa.

---

## 1. Situación inicial de SGSPRI

| Dato | Valor |
|---|---|
| Datafiles | `/opt/oracle/oradata/SGSPRI/` (en `SGSSTB` irán en `/opt/oracle/oradata/SGSSTB/`) |
| spfile | `/opt/oracle/dbs/spfileSGSPRI.ora` |
| Archivo de contraseñas | `/opt/oracle/dbs/orapwSGSPRI` |
| Redo creados por `dbca` | 3 grupos de 200 MB |
| Force logging / Flashback | NO / NO |

## 2. Force logging y flashback

```
ALTER DATABASE FORCE LOGGING;    -- todo cambio queda en el redo (si no, la standby queda inconsistente)
ALTER DATABASE FLASHBACK ON;     -- permite reincorporar un servidor después de un failover
```

## 3. Redo logs de 50 MB

El enunciado pide un archivo de actualización cada 5 minutos **o cada 50 MB**: cada vez que se llena un redo log se genera un archivo de archivado, que es lo que viaja a la standby. Por eso los redo se dejan en 50 MB (los 5 minutos se programan en S4 leyendo la tabla de parámetros). Se cambia antes de crear la standby, porque esta copia el mismo tamaño.

```
ALTER DATABASE ADD LOGFILE GROUP 4 ('/opt/oracle/oradata/SGSPRI/redo04.log') SIZE 50M;
ALTER DATABASE ADD LOGFILE GROUP 5 ('/opt/oracle/oradata/SGSPRI/redo05.log') SIZE 50M;
ALTER DATABASE ADD LOGFILE GROUP 6 ('/opt/oracle/oradata/SGSPRI/redo06.log') SIZE 50M;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
SELECT group#, bytes/1024/1024 AS mb, status FROM v$log ORDER BY group#;
-- 1, 2 y 3 en INACTIVE (solo se pueden borrar así)

ALTER DATABASE DROP LOGFILE GROUP 1;
ALTER DATABASE DROP LOGFILE GROUP 2;
ALTER DATABASE DROP LOGFILE GROUP 3;
HOST rm /opt/oracle/oradata/SGSPRI/redo01.log /opt/oracle/oradata/SGSPRI/redo02.log /opt/oracle/oradata/SGSPRI/redo03.log
```

## 4. Standby redo logs

Los usa la standby para recibir los cambios en tiempo real. Regla de Oracle: un grupo más que los redo normales (3 + 1 = 4) y del mismo tamaño. Se crean también en la principal para cuando cambie de rol (switchover).

```
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 11 ('/opt/oracle/oradata/SGSPRI/standby_redo11.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 12 ('/opt/oracle/oradata/SGSPRI/standby_redo12.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 13 ('/opt/oracle/oradata/SGSPRI/standby_redo13.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 14 ('/opt/oracle/oradata/SGSPRI/standby_redo14.log') SIZE 50M;
```

Verificación:

```
SELECT group#, bytes/1024/1024 AS mb, status FROM v$log ORDER BY group#;          -- 4, 5, 6 de 50 MB
SELECT group#, bytes/1024/1024 AS mb, status FROM v$standby_log ORDER BY group#;  -- 11 a 14 de 50 MB, UNASSIGNED
SELECT force_logging, flashback_on FROM v$database;                               -- YES, YES
```

## 5. Parámetros de Data Guard en SGSPRI

```
ALTER SYSTEM SET log_archive_config='DG_CONFIG=(SGSPRI,SGSSTB)' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=SGSPRI' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_2='SERVICE=SGSSTB ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=SGSSTB' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_state_2='DEFER' SCOPE=BOTH;   -- en pausa hasta que exista la standby
ALTER SYSTEM SET fal_server='SGSSTB' SCOPE=BOTH;
ALTER SYSTEM SET standby_file_management='AUTO' SCOPE=BOTH;
ALTER SYSTEM SET db_file_name_convert='/opt/oracle/oradata/SGSSTB/','/opt/oracle/oradata/SGSPRI/' SCOPE=SPFILE;
ALTER SYSTEM SET log_file_name_convert='/opt/oracle/oradata/SGSSTB/','/opt/oracle/oradata/SGSPRI/' SCOPE=SPFILE;
```

| Parámetro | Para qué |
|---|---|
| `log_archive_config` | Qué bases forman la configuración |
| `log_archive_dest_1` | Archivado local en la Fast Recovery Area |
| `log_archive_dest_2` | Envío de cambios a `SGSSTB` (asíncrono) |
| `fal_server` | A quién pedir archivos faltantes cuando esta base sea standby |
| `standby_file_management=AUTO` | Los datafiles nuevos (p. ej. tablespaces de Isaac) se crean solos en la standby |
| `*_name_convert` | Traducción de rutas para cuando esta base sea standby (switchover) |

Verificación:

```
COLUMN name FORMAT A30
COLUMN value FORMAT A100
SELECT name, value FROM v$parameter
 WHERE name IN ('log_archive_config','log_archive_dest_1','log_archive_dest_2',
                'log_archive_dest_state_2','fal_server','standby_file_management');
```

## 6. Red de Oracle en los dos servidores

Archivos en `/opt/oracle/homes/OraDBHome21cEE/network/admin/` (Oracle home de solo lectura del RPM).

**`tnsnames.ora`, igual en `SGSPRI` y `SGSSTB`:**

```
cat > /opt/oracle/homes/OraDBHome21cEE/network/admin/tnsnames.ora <<'EOF'
SGSPRI =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgspri.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = SGSPRI)(UR = A))
  )

SGSSTB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgsstb.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = SGSSTB)(UR = A))
  )

SGSPDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgspri.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = sgspdb))
  )
EOF
```

`(UR = A)` permite conectarse a una instancia en `NOMOUNT` (necesario para duplicar la standby).

**Registro estático en `listener.ora`** (en `SGSSTB` es igual cambiando `SGSPRI` por `SGSSTB`). Permite conectarse a la instancia aunque la base esté apagada; `*_DGMGRL` lo usa el broker en el switchover:

```
cat >> /opt/oracle/homes/OraDBHome21cEE/network/admin/listener.ora <<'EOF'

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = SGSPRI)
      (ORACLE_HOME = /opt/oracle/product/21c/dbhome_1)
      (SID_NAME = SGSPRI)
    )
    (SID_DESC =
      (GLOBAL_DBNAME = SGSPRI_DGMGRL)
      (ORACLE_HOME = /opt/oracle/product/21c/dbhome_1)
      (SID_NAME = SGSPRI)
    )
  )
EOF
lsnrctl reload     # en SGSSTB: lsnrctl start
```

En `SGSSTB`, los servicios estáticos aparecen con `status UNKNOWN` mientras la base está apagada; es lo esperado.

Verificación (debe decir **Used TNSNAMES adapter** y **OK**):

```
tnsping SGSSTB     # desde SGSPRI
tnsping SGSPRI     # desde SGSSTB
```

> Si `tnsping` dice "Used EZCONNECT adapter", falta el `tnsnames.ora` en ese servidor.

## 7. Preparar SGSSTB para recibir la copia

**Archivo de contraseñas** (desde `SGSPRI`, como `oracle`). Las dos bases deben tener el mismo; en el destino se renombra con el SID de la standby:

```
scp /opt/oracle/dbs/orapwSGSPRI oracle@sgsstb:/opt/oracle/dbs/orapwSGSSTB
```

**En `SGSSTB`** (como `oracle`): carpetas, archivo de parámetros mínimo y arranque en `NOMOUNT`:

```
mkdir -p /opt/oracle/oradata/SGSSTB/pdbseed /opt/oracle/oradata/SGSSTB/SGSPDB
mkdir -p /opt/oracle/fast_recovery_area /opt/oracle/admin/SGSSTB/adump
echo "*.db_name='SGS'" > /opt/oracle/dbs/initSGSSTB.ora

sqlplus / as sysdba
STARTUP NOMOUNT PFILE='/opt/oracle/dbs/initSGSSTB.ora';   -- ORACLE instance started.
```

**Prueba desde `SGSPRI`** (confirma red, listener estático y archivo de contraseñas):

```
sqlplus sys@SGSSTB as sysdba
SELECT status FROM v$instance;   -- STARTED
```

## 8. Duplicar la base a SGSSTB con RMAN

Desde `SGSPRI`, como `oracle` y dentro de `tmux` (si se corta el SSH, el duplicado sigue). Pide dos veces la contraseña de SYS (target y auxiliary):

```
rman target sys@SGSPRI auxiliary sys@SGSSTB
```

```
DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET db_unique_name='SGSSTB'
    SET control_files='/opt/oracle/oradata/SGSSTB/control01.ctl','/opt/oracle/oradata/SGSSTB/control02.ctl'
    SET db_file_name_convert='/opt/oracle/oradata/SGSPRI/','/opt/oracle/oradata/SGSSTB/'
    SET log_file_name_convert='/opt/oracle/oradata/SGSPRI/','/opt/oracle/oradata/SGSSTB/'
    SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=SGSSTB'
    SET log_archive_dest_2='SERVICE=SGSPRI ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=SGSPRI'
    SET log_archive_dest_state_2='ENABLE'
    SET fal_server='SGSPRI'
    SET audit_file_dest='/opt/oracle/admin/SGSSTB/adump'
    SET dispatchers='(PROTOCOL=TCP) (SERVICE=SGSSTBXDB)'
  NOFILENAMECHECK;
```

- `FOR STANDBY FROM ACTIVE DATABASE`: copia en vivo por la red, sin respaldo previo.
- `SPFILE ... SET`: copia los parámetros de `SGSPRI` cambiando lo que debe ser distinto en la standby (nombre único, rutas, destinos invertidos para el switchover).
- `DORECOVER`: aplica los últimos archivos de archivado.

Tardó unos 4 minutos y terminó con `Finished Duplicate Db`.

## 9. Arrancar la sincronización

**En `SGSSTB`** (`sqlplus / as sysdba`):

```
SELECT name, db_unique_name, database_role, open_mode FROM v$database;
-- SGS   SGSSTB   PHYSICAL STANDBY   MOUNTED

ALTER DATABASE OPEN READ ONLY;                     -- Active Data Guard: se puede consultar mientras aplica
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;   -- arranca el MRP
```

**En `SGSPRI`**:

```
ALTER SYSTEM SET log_archive_dest_state_2='ENABLE' SCOPE=BOTH;
ALTER SYSTEM SWITCH LOGFILE;
SELECT dest_id, status, error FROM v$archive_dest WHERE dest_id = 2;   -- 2  VALID  (sin error)
```

**Verificación en `SGSSTB`**:

```
SELECT name, role, action FROM v$dataguard_process ORDER BY name;
-- MRP0 (managed recovery), PR00 APPLYING_LOG y procesos rfs (reciben el redo de SGSPRI)
```

## 10. Prueba: un dato insertado en SGSPRI aparece en SGSSTB

**En `SGSPRI`:**

```
ALTER SESSION SET CONTAINER = SGSPDB;
CREATE TABLE system.prueba_dg (id NUMBER, texto VARCHAR2(50), fecha DATE);
INSERT INTO system.prueba_dg VALUES (1, 'Hola desde SGSPRI', SYSDATE);
COMMIT;
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER SYSTEM SWITCH LOGFILE;
```

**En `SGSSTB`**, segundos después:

```
ALTER SESSION SET CONTAINER = SGSPDB;
SELECT * FROM system.prueba_dg;          -- aparece la fila insertada en SGSPRI

INSERT INTO system.prueba_dg VALUES (2, 'Desde la standby', SYSDATE);
-- ORA-16000: database or pluggable database open for read-only access
```

El dato viaja de la principal a la standby y la standby no acepta escrituras. **S3 queda completo.**

> En la prueba la fila se insertó dos veces por error; por eso aparece duplicada en las capturas.
