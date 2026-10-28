# S5 — Respaldos con RMAN

Estrategia de respaldo y recuperación de `SGSPRI` con RMAN: backup full, backup incremental, restore y recovery, y copia del respaldo al standby. Capturas en [`capturas/s5_rman/`](capturas/s5_rman/).

Estado: **RMAN configurado y backup full (nivel 0) e incremental (nivel 1) hechos; restore y recovery probados.** Falta: copia a `SGSSTB` y automatización diaria (`DBMS_SCHEDULER`, cuando exista `RESP_HORA_DIARIO` en la tabla de parámetros).

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
