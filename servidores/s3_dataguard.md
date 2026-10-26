# S3 — Data Guard (SGSPRI → SGSSTB)

Pasos confirmados para convertir `SGSSTB` en standby física de `SGSPRI`. Capturas en [`capturas/s3_dataguard/`](capturas/s3_dataguard/).

Estado: **`SGSPRI` preparada (force logging, flashback, redo de 50 MB y standby redo logs).** Falta: parámetros de Data Guard, red de Oracle, duplicar la base y arrancar la aplicación de cambios.

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
