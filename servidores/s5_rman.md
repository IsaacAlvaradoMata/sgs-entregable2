# S5 — Respaldos con RMAN

Estrategia de respaldo y recuperación de `SGSPRI` con RMAN: backup full, backup incremental, restore y recovery, y copia del respaldo al standby. Capturas en [`capturas/s5_rman/`](capturas/s5_rman/).

Estado: **RMAN configurado y backup full (nivel 0) e incremental (nivel 1) hechos.** Falta: prueba de restore/recovery, copia a `SGSSTB` y automatización diaria (`DBMS_SCHEDULER`, cuando exista `RESP_HORA_DIARIO` en la tabla de parámetros).

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
