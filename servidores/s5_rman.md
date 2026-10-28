# S5 — Respaldos con RMAN

Estrategia de respaldo y recuperación de `SGSPRI` con RMAN: backup full, backup incremental, restore y recovery, y copia del respaldo al standby. Capturas en [`capturas/s5_rman/`](capturas/s5_rman/).

Estado: **RMAN configurado.** Falta: backup full, incremental, prueba de restore/recovery, copia a `SGSSTB` y automatización diaria (`DBMS_SCHEDULER`, cuando exista `RESP_HORA_DIARIO` en la tabla de parámetros).

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
