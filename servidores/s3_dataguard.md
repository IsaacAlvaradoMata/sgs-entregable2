# S3 — Data Guard (SGSPRI → SGSSTB)

Pasos confirmados para convertir `SGSSTB` en standby física de `SGSPRI`. Capturas en [`capturas/s3_dataguard/`](capturas/s3_dataguard/).

Estado: **`SGSPRI` preparada (force logging, flashback, redo de 50 MB y standby redo logs).** Parámetros de Data Guard y red de Oracle configurados. Falta: duplicar la base y arrancar la aplicación de cambios.

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
