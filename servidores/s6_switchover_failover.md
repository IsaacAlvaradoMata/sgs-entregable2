# S6 — Switchover, failover y recuperación

Cambios de rol entre `SGSPRI` y `SGSSTB` con el broker de Data Guard (`dgmgrl`). Capturas en [`capturas/s6_switchover_failover/`](capturas/s6_switchover_failover/).

Estado: **Broker configurado y switchover a `SGSSTB` probado.** Falta: regreso a `SGSPRI`, failover y reincorporación.

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
