# S6 — Switchover, failover y recuperación

Cambios de rol entre `SGSPRI` y `SGSSTB` con el broker de Data Guard (`dgmgrl`). Capturas en [`capturas/s6_switchover_failover/`](capturas/s6_switchover_failover/).

Estado: **S6 completo.** Broker configurado; switchover, failover, reincorporación y regreso a los roles originales probados sin pérdida de datos.

---

## 1. Broker de Data Guard

El broker administra la configuración: hace switchover y failover con un comando y muestra el retraso de sincronización (monitoreo).

El broker maneja el envío de redo, así que primero se borra el destino que se configuró a mano (si no, `ORA-16698` al crear la configuración). En **los dos** servidores (`sqlplus / as sysdba`):

```
ALTER SYSTEM SET log_archive_dest_2='' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;
```

En `SGSPRI`, como `oracle`:

```
dgmgrl sys@SGSPRI
CREATE CONFIGURATION sgs_dg AS PRIMARY DATABASE IS SGSPRI CONNECT IDENTIFIER IS SGSPRI;
ADD DATABASE SGSSTB AS CONNECT IDENTIFIER IS SGSSTB MAINTAINED AS PHYSICAL;
ENABLE CONFIGURATION;
SHOW CONFIGURATION;      -- Configuration Status: SUCCESS
SHOW DATABASE SGSSTB;    -- Transport Lag 0 s, Apply Lag 0 s, Real Time Query ON, SUCCESS
```

| Dato | Valor |
|---|---|
| Configuración | `sgs_dg` |
| Modo de protección | MaxPerformance (transporte `ASYNC`) |
| Fast-Start Failover | Deshabilitado (el failover se hace a mano, para la demostración) |

## 2. Switchover (cambio planeado de roles)

Intercambio planeado, sin pérdida de datos (por ejemplo, para dar mantenimiento a la principal). Desde `dgmgrl sys@SGSPRI`:

```
VALIDATE DATABASE SGSSTB;      -- Ready for Switchover: Yes
SWITCHOVER TO SGSSTB;          -- Switchover succeeded, new primary is "sgsstb"
SHOW CONFIGURATION;            -- sgsstb Primary, sgspri Physical standby
```

- Tardó unos 40 segundos. El broker convierte `SGSSTB` en principal, reinicia `SGSPRI` y la deja como standby.
- Justo después aparece `WARNING` con `ORA-16854: apply lag could not be determined`: la nueva standby todavía no recibe su primer archivo. En menos de un minuto pasa sola a `SUCCESS`.

**Verificación en la nueva principal (`SGSSTB`):**

```
SELECT name, database_role, open_mode FROM v$database;   -- SGS  PRIMARY  READ WRITE
SHOW PDBS                                                 -- SGSPDB  READ WRITE (abre sola)
ALTER PLUGGABLE DATABASE SGSPDB SAVE STATE;               -- que abra sola también en este servidor
ALTER SESSION SET CONTAINER = SGSPDB;
INSERT INTO system.prueba_dg VALUES (4, 'Escrito en SGSSTB como principal', SYSDATE);
COMMIT;
```

**En la nueva standby (`SGSPRI`):**

```
SELECT database_role, open_mode FROM v$database;   -- PHYSICAL STANDBY  READ ONLY WITH APPLY
ALTER SESSION SET CONTAINER = SGSPDB;
SELECT * FROM system.prueba_dg ORDER BY id;        -- aparece la fila 4
```

Con los roles invertidos, los datos viajan de `SGSSTB` a `SGSPRI`.

> Mientras `SGSSTB` es la principal, Isaac se conecta por la IP de Tailscale de `SGSSTB` (`100.69.133.78`), servicio `sgspdb`. El script de respaldo (`respaldo_rman.sh`) está pensado para `SGSPRI` como principal: no se ejecuta mientras los roles estén invertidos.

**Regreso a los roles originales:** desde `dgmgrl sys@SGSPRI`, `SWITCHOVER TO SGSPRI;`. Después de reiniciar las VMs se verificó con `SHOW CONFIGURATION`: `sgspri` Primary, `sgsstb` Physical standby, `SUCCESS`.

## 3. Failover (caída de la principal) y reincorporación

Simula que `SGSPRI` se cae sin aviso: `SGSSTB` toma el mando y, cuando `SGSPRI` vuelve, se reincorpora como standby gracias al flashback (sin copiar la base de nuevo).

### 3.1 Dato de control y caída

En `SGSPRI`, dentro de `SGSPDB`:

```
INSERT INTO system.prueba_dg VALUES (5, 'Antes de la caida de SGSPRI', SYSDATE);
COMMIT;
```

Se confirma que la fila 5 ya está en `SGSSTB` (`SELECT * FROM system.prueba_dg WHERE id = 5;`). Luego, en `SGSPRI` (`sqlplus / as sysdba`, en `CDB$ROOT`):

```
ALTER SYSTEM SWITCH LOGFILE;
SHUTDOWN ABORT;            -- apagado de golpe, como una caída real
```

Desde `dgmgrl sys@SGSSTB`, `SHOW CONFIGURATION` muestra `sgspri` con `ORA-1034: ORACLE not available` y `Configuration Status: ERROR`. Es lo esperado: la principal no responde.

### 3.2 Failover a SGSSTB

```
VALIDATE DATABASE SGSSTB;      -- Ready for Failover: Yes (Primary Not Running)
FAILOVER TO 'SGSSTB';          -- Failover succeeded, new primary is "SGSSTB"
SHOW CONFIGURATION;            -- sgsstb Primary; sgspri (disabled) ORA-16661; SUCCESS
```

- Tardó unos 15 segundos.
- **Problema encontrado:** `FAILOVER TO SGSSTB;` (sin comillas) respondía `ORA-16600: not connected to target standby database`, aunque la sesión sí estaba en `SGSSTB` (por TNS y también con `dgmgrl /`). Se resolvió escribiendo el nombre **entre comillas y en mayúscula**, igual que el `db_unique_name`: `FAILOVER TO 'SGSSTB';`. Lo mismo se usa en `REINSTATE` y `SWITCHOVER` desde la standby.
- `ORA-16661: the standby database needs to be reinstated` es normal: `SGSPRI` queda fuera hasta reincorporarla.

**Verificación en la nueva principal (`SGSSTB`):**

```
SELECT name, database_role, open_mode FROM v$database;   -- SGS  PRIMARY  READ WRITE
SHOW PDBS                                                 -- SGSPDB  READ WRITE
ALTER SESSION SET CONTAINER = SGSPDB;
SELECT * FROM system.prueba_dg ORDER BY id;               -- está la fila 5: no se perdieron datos
INSERT INTO system.prueba_dg VALUES (6, 'Escrito en SGSSTB tras el failover', SYSDATE);
COMMIT;
```

**Flashback en `SGSSTB`:** el `VALIDATE` mostró que estaba en `Off` (la standby creada con `DUPLICATE` no lo hereda). Se activó para poder reincorporar también `SGSSTB` en una caída futura:

```
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER DATABASE FLASHBACK ON;
SELECT flashback_on FROM v$database;    -- YES
```

### 3.3 Reincorporación de SGSPRI

En `SGSPRI`, solo montar (no abrir):

```
sqlplus / as sysdba
STARTUP MOUNT;            -- Database mounted.
```

Desde `dgmgrl sys@SGSSTB`:

```
REINSTATE DATABASE 'SGSPRI';   -- Reinstatement of database "SGSPRI" succeeded
SHOW CONFIGURATION;            -- sgsstb Primary, sgspri Physical standby, SUCCESS
```

El broker regresa `SGSPRI` con flashback al momento del failover, la convierte en standby, la reinicia y activa la aplicación (unos 20 segundos). Verificación en `SGSPRI` (sesión nueva de `sqlplus`):

```
SELECT database_role, open_mode FROM v$database;   -- PHYSICAL STANDBY  READ ONLY WITH APPLY
ALTER SESSION SET CONTAINER = SGSPDB;
SELECT * FROM system.prueba_dg ORDER BY id;        -- llega la fila 6, escrita durante la caída
```

### 3.4 Regreso a los roles originales

Desde `dgmgrl sys@SGSSTB`:

```
SWITCHOVER TO 'SGSPRI';        -- Switchover succeeded
SHOW CONFIGURATION;            -- sgspri Primary, sgsstb Physical standby
```

Justo después aparece `ERROR` con `ORA-16810: multiple errors or warnings detected for the member` en `sgsstb`: la standby recién reiniciada todavía no recibe redo. En alrededor de un minuto pasa sola a `SUCCESS`; `SHOW DATABASE 'SGSSTB';` muestra Transport Lag y Apply Lag de 0 segundos, `Real Time Query: ON` y `SUCCESS`.

### Resumen de comandos del broker

| Situación | Dónde | Comando |
|---|---|---|
| Ver estado | cualquiera | `SHOW CONFIGURATION;` / `SHOW DATABASE 'SGSSTB';` |
| Cambio planeado | principal o standby | `SWITCHOVER TO 'SGSSTB';` (o `'SGSPRI'`) |
| Caída de la principal | standby | `FAILOVER TO 'SGSSTB';` |
| Reincorporar la caída | nueva principal, con la caída en `MOUNT` | `REINSTATE DATABASE 'SGSPRI';` |
