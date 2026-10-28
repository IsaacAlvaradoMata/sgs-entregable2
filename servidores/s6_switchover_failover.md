# S6 — Switchover, failover y recuperación

Cambios de rol entre `SGSPRI` y `SGSSTB` con el broker de Data Guard (`dgmgrl`). Capturas en [`capturas/s6_switchover_failover/`](capturas/s6_switchover_failover/).

Estado: **Broker configurado (`SUCCESS`).** Falta: switchover y regreso, failover y reincorporación.

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
