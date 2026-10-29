# S5 — Respaldos con RMAN

Estrategia de respaldo y recuperación de `SGSPRI` con RMAN: backup full, backup incremental, restore y recovery, y copia del respaldo al standby. Capturas en [`capturas/s5_rman/`](capturas/s5_rman/).

Estado: **RMAN configurado y backup full (nivel 0) e incremental (nivel 1) hechos; restore y recovery probados; copia a `SGSSTB` y script de respaldo a demanda funcionando.** Falta: automatización diaria (`DBMS_SCHEDULER`, cuando exista `RESP_HORA_DIARIO` en la tabla de parámetros).

Comandos en `SGSPRI`, como `oracle`, dentro de `tmux` (`tmux new -s rman`) para que un respaldo no se pierda si se corta el SSH.

---

## 1. Espacio disponible

```
SELECT ROUND(SUM(bytes)/1024/1024/1024, 2) AS gb_base FROM cdb_data_files;          -- 2.78 GB
SELECT name, ROUND(space_limit/1024/1024/1024, 2) AS gb_limite,
       ROUND(space_used/1024/1024/1024, 2) AS gb_usado FROM v$recovery_file_dest;     -- 20 GB / 1.04 GB
```

Los respaldos se guardan en la Fast Recovery Area (`/opt/oracle/fast_recovery_area`, 20 GB).

## 2. Configuración de RMAN

```
rman target /
CONFIGURE RETENTION POLICY TO REDUNDANCY 1;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
SHOW ALL;
```

| Configuración | Por qué |
|---|---|
| `REDUNDANCY 1` | Se guarda un respaldo completo vigente; la segunda copia está en `SGSSTB` |
| `CONTROLFILE AUTOBACKUP ON` | Después de cada respaldo se guardan el control file y el spfile (sin ellos no se puede restaurar) |
| `BACKUP OPTIMIZATION ON` | No repite archivos que ya están respaldados |
| `COMPRESSED BACKUPSET` | Compresión básica (incluida sin licencia extra) para ahorrar espacio |
| `ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY` | RMAN no borra archivos de redo que la standby todavía no aplicó |

## 3. Backup full (incremental nivel 0)

Un backup **incremental de nivel 0** es un respaldo **completo** de toda la base (raíz, `PDB$SEED` y `SGSPDB`) y además es el punto de partida de los incrementales de nivel 1.

```
BACKUP INCREMENTAL LEVEL 0 DATABASE PLUS ARCHIVELOG TAG 'SGS_FULL_L0';
```

- `PLUS ARCHIVELOG`: respalda los archivos de redo antes y después de los datafiles, para poder recuperar hasta el último momento.
- Terminó en 1 minuto con `Finished backup` y `Finished Control File and SPFILE Autobackup`.
- Los respaldos quedan en `/opt/oracle/fast_recovery_area/SGSPRI/backupset/` (los de la PDB, en una subcarpeta con su GUID) y el autobackup del control file en `.../SGSPRI/autobackup/`.

> Con `PLUS ARCHIVELOG`, el `TAG` escrito al final se aplica a los archivos de redo; los datafiles quedan con un tag automático (`TAG<fecha>`). Para etiquetar los datafiles, el `TAG` va justo después de `DATABASE`.

`LIST BACKUP SUMMARY` después del full: `LV 0` = datafiles de la raíz, `PDB$SEED` y `SGSPDB`; `LV A` = archivos de redo; `LV F` = autobackup del control file y spfile.

## 4. Backup incremental (nivel 1)

Se generó un cambio en `SGSPDB` (`INSERT` en `system.prueba_dg`) y luego:

```
BACKUP INCREMENTAL LEVEL 1 DATABASE TAG 'SGS_INC_L1' PLUS ARCHIVELOG;
```

- Solo guarda los bloques que cambiaron desde el nivel 0.
- Los datafiles sin cambios se omiten: `skipping datafile 00006 because it has not changed` (los de `PDB$SEED`).
- Los archivos de redo ya respaldados también se omiten (`skipping archived logs ... already backed up`), por `BACKUP OPTIMIZATION ON`.
- `LIST BACKUP SUMMARY` muestra las filas nuevas con `LV 1` y tag `SGS_INC_L1` (raíz y `SGSPDB`; `PDB$SEED` no tuvo cambios).

## 5. Prueba de restore y recovery (pérdida de un datafile)

Se simula que se daña un archivo de datos y se recupera con RMAN. Se usa un tablespace de prueba en `SGSPDB` para no tocar datos reales; la base sigue abierta todo el tiempo.

**Preparación** (`sqlplus / as sysdba`):

```
ALTER SESSION SET CONTAINER = SGSPDB;
CREATE TABLESPACE ts_prueba_rman DATAFILE '/opt/oracle/oradata/SGSPRI/SGSPDB/ts_prueba_rman01.dbf' SIZE 20M;
CREATE TABLE system.prueba_rman (id NUMBER, texto VARCHAR2(50)) TABLESPACE ts_prueba_rman;
INSERT INTO system.prueba_rman VALUES (1, 'Dato antes del respaldo');
COMMIT;
```

**Respaldo** (`rman target /`):

```
BACKUP TABLESPACE SGSPDB:ts_prueba_rman TAG 'SGS_PRUEBA_TS';
```

**Dato posterior al respaldo** (no queda en el respaldo; solo puede volver por el recovery):

```
INSERT INTO system.prueba_rman VALUES (2, 'Dato despues del respaldo');
COMMIT;
```

**Falla simulada:**

```
HOST rm /opt/oracle/oradata/SGSPRI/SGSPDB/ts_prueba_rman01.dbf
ALTER TABLESPACE ts_prueba_rman OFFLINE IMMEDIATE;
ALTER TABLESPACE ts_prueba_rman ONLINE;
-- ORA-01157: cannot identify/lock data file 13
```

**Restore y recovery** (`rman target /`):

```
RESTORE TABLESPACE SGSPDB:ts_prueba_rman;    -- copia el archivo desde el respaldo (estado del respaldo)
RECOVER TABLESPACE SGSPDB:ts_prueba_rman;    -- aplica el redo posterior: media recovery complete
```

**Comprobación:**

```
ALTER SESSION SET CONTAINER = SGSPDB;
ALTER TABLESPACE ts_prueba_rman ONLINE;
SELECT * FROM system.prueba_rman;
-- 1 Dato antes del respaldo     ← venía en el respaldo (RESTORE)
-- 2 Dato despues del respaldo   ← la aplicó el RECOVER desde el redo
```

> **Restore vs. recovery:** si se intenta poner el tablespace en línea solo con el `RESTORE`, Oracle responde `ORA-01113: file 13 needs media recovery`: el archivo quedó en el estado del respaldo y le faltan los cambios posteriores. El `RECOVER` los aplica desde los archivos de redo.

## 6. Llaves SSH entre los servidores (sin contraseña)

Los procesos automáticos no pueden escribir contraseñas, así que el usuario `oracle` de cada servidor entra al otro con una llave SSH. Se hace en los dos sentidos para que siga funcionando después de un switchover.

```
# En SGSPRI (como oracle)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id oracle@sgsstb          # pide la contraseña de oracle por única vez
ssh oracle@sgsstb hostname         # sgsstb.localdomain, sin contraseña

# En SGSSTB (como oracle)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id oracle@sgspri
ssh oracle@sgspri hostname         # sgspri.localdomain, sin contraseña
```

## 7. Copia de los respaldos a SGSSTB

`rsync` instalado como `root` en los dos servidores (`dnf install -y rsync`). En `SGSSTB` (como `oracle`): `mkdir -p /opt/oracle/respaldos_sgspri`.

Desde `SGSPRI` (como `oracle`), sin contraseña gracias a la llave SSH:

```
rsync -av --delete-excluded --exclude='control*.ctl' --exclude='flashback/' --exclude='onlinelog/' \
      /opt/oracle/fast_recovery_area/SGSPRI/ oracle@sgsstb:/opt/oracle/respaldos_sgspri/
```

- Se excluyen el control file vivo (`dbca` dejó `control02.ctl` en la FRA; copiarlo con la base abierta da un archivo inconsistente), los logs de flashback y los redo en línea: solo sirven en el propio servidor.
- `--delete-excluded` mantiene la carpeta de `SGSSTB` igual a los respaldos vigentes de `SGSPRI`.
- `rsync` solo envía lo nuevo: la primera copia fueron ~1,9 GB; las siguientes, apenas los respaldos nuevos.

En `SGSSTB` quedan `archivelog`, `autobackup`, `backupset` y las carpetas de las PDB (por GUID).

## 8. Script de respaldo (a demanda y para el job diario)

[`scripts/respaldo_rman.sh`](scripts/respaldo_rman.sh) junta todo en un paso: backup con RMAN (nivel 0 los domingos, nivel 1 los demás días, o el nivel indicado), `CROSSCHECK` y `DELETE OBSOLETE` según la retención, y copia al otro servidor con `rsync`. Deja un log por ejecución en `/home/oracle/logs`. Define las variables de Oracle porque un job del scheduler no carga `.bash_profile`.

Está instalado **igual en los dos servidores** (`/home/oracle/scripts/respaldo_rman.sh`): detecta en cuál corre (`hostname`), pregunta el rol de su base y **solo respalda si es la PRIMARY**. Así, después de un switchover respalda la nueva principal y copia al otro servidor (`/opt/oracle/respaldos_sgspri` o `/opt/oracle/respaldos_sgsstb`).

| Código de salida | Significado |
|---|---|
| `0` | Respaldo y copia OK |
| `1` | Error de RMAN |
| `2` | Nivel inválido |
| `3` | Error al copiar al otro servidor |
| `4` | La base de este servidor no es PRIMARY: no se respalda |
| `5` | Servidor desconocido o base no disponible |

Instalación (como `oracle`, en `SGSPRI` y en `SGSSTB`):

```
mkdir -p ~/scripts
curl -fsSL -o ~/scripts/respaldo_rman.sh https://raw.githubusercontent.com/IsaacAlvaradoMata/sgs-entregable2/main/servidores/scripts/respaldo_rman.sh
chmod +x ~/scripts/respaldo_rman.sh
```

**Prueba en la standby** (`SGSSTB`): `~/scripts/respaldo_rman.sh 1; echo "Resultado: $?"` → `SGSSTB no es la base principal: no se respalda` y `Resultado: 4`.

**Ejecución a mano en la principal** (`SGSPRI`):

```
~/scripts/respaldo_rman.sh 1; echo "Resultado: $?"                       # Resultado: 0
grep -E "Rol de|fin OK" $(ls -t ~/logs/respaldo_*_L1.log | head -1)     # Rol de SGSPRI: PRIMARY ... fin OK
ssh oracle@sgsstb "ls -lt /opt/oracle/respaldos_sgspri/backupset/"      # carpeta con la fecha del día
```

En la primera prueba (2026-10-28), `DELETE OBSOLETE` borró 14 objetos que la retención ya no necesita: archivos de redo del 26-oct (ya aplicados en la standby), autobackups viejos del control file y el respaldo `SGS_PRUEBA_TS`, reemplazado por la copia nueva del datafile 13 que hizo el incremental (RMAN hace nivel 0 de un archivo que no tiene nivel 0 previo).

## 9. Job diario de respaldo (`SGS_JOB_RESPALDO_DIARIO`)

El script [`bd/11_standby.sql`](../bd/11_standby.sql) crea, a nombre de `SGS_ADMIN`:

- La credencial `SGS_CRED_ORACLE` con el usuario `oracle` de Linux. La clave se pide al ejecutar (`ACCEPT ... HIDE` con `SET VERIFY OFF`), no se muestra y no queda en el repo.
- El job `SGS_JOB_RESPALDO_DIARIO`, de tipo `EXECUTABLE`, que ejecuta `/home/oracle/scripts/respaldo_rman.sh` con esa credencial. La hora sale del parámetro `RESP_HORA_DIARIO` (`1` → `FREQ=DAILY;BYHOUR=1;BYMINUTE=0;BYSECOND=0`, hora de Costa Rica). Si el parámetro cambia, se vuelve a ejecutar la sección 3 del script.

Se ejecuta en `SGSPRI` como SYS dentro de la PDB (o como `SGS_ADMIN`):

```
sqlplus / as sysdba
ALTER SESSION SET CONTAINER = SGSPDB;
@/home/oracle/scripts/11_standby.sql      -- pide la clave de Linux de oracle
```

Resultado: credencial `SGS_ADMIN.SGS_CRED_ORACLE` `TRUE`; job `TRUE` / `SCHEDULED`, próxima ejecución `01:00 AMERICA/COSTA_RICA`.

**Ejecución a demanda** (la que pide el enunciado para la revisión):

```
EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO', use_current_session => TRUE);
SELECT status, error#, run_duration, additional_info
  FROM dba_scheduler_job_run_details
 WHERE job_name = 'SGS_JOB_RESPALDO_DIARIO'
 ORDER BY log_id DESC FETCH FIRST 1 ROWS ONLY;
-- SUCCEEDED  0  +000 00:00:15  ... USERNAME="oracle"
```

El log del script confirma la ejecución (`Rol de SGSPRI: PRIMARY` y `fin OK`). Los jobs no corren en la standby (está en solo lectura); después de un switchover corren en la nueva principal, y el script respalda esa base.
