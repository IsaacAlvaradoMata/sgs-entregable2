# Pendientes

Qué falta y quién lo tiene. Se actualiza al cerrar cada sesión de trabajo.

## Carril S — Servidores (Andrés)

**Último avance (2026-10-28, noche):** S6 completo: switchover, failover (caída simulada de `SGSPRI`), reincorporación con `REINSTATE` y regreso a los roles originales, sin pérdida de datos. Detalle en [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md). Antes (2026-10-28, tarde): S5 casi completo (falta solo el job diario). Antes: Tailscale en las dos VMs y conexión a `SGSPDB` por Tailscale probada; `local_listener` corregido en ambos servidores. **Siguiente sesión: S5 (RMAN).** Antes (2026-10-26): **S3 completo: Data Guard funcionando** (`SGSSTB` standby física en Active Data Guard; probado con un dato que viaja de `SGSPRI` a `SGSSTB`). Detalle en [`servidores/s3_dataguard.md`](../servidores/s3_dataguard.md). Antes: base de datos creada en `SGSPRI` (`DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, ARCHIVELOG, PDB `SGSPDB`); detalle en [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md). Antes: S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

### Después

- [x] Crear la base en `SGSPRI` con `dbca`.
- [x] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS`.
- [ ] Avisar a Isaac que `SGSPDB` ya existe en `SGSPRI` (punto I1).
- [ ] Antes de la defensa: cambiar las contraseñas de `SYS`, `SYSTEM` y `PDBADMIN` por unas fuertes.
- [x] Tailscale en ambas VMs (sin exit node): [`servidores/tailscale.md`](../servidores/tailscale.md). `SGSPRI` = `100.76.209.30`, `SGSSTB` = `100.69.133.78`.
- [ ] Pedirle a Isaac que revoque la llave de Tailscale ya usada.
- [x] Conexión a `SGSPDB` por la IP de Tailscale probada desde `SGSSTB` (`sqlplus system@100.76.209.30:1521/sgspdb`).
- [ ] Isaac prueba la conexión desde DBeaver en su Mac (datos en [`servidores/tailscale.md`](../servidores/tailscale.md)).
- [x] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).
- [x] Rutina de arranque y apagado probada (2026-10-27): [`servidores/operacion_diaria.md`](../servidores/operacion_diaria.md).
- [x] Hora sincronizada con `chronyd` en los dos servidores.
- [ ] S4: administración parametrizada del standby (necesita la tabla de parámetros de Isaac, I2).
- [x] S5: RMAN configurado; full, incremental, restore y recovery probados; copia a `SGSSTB`; script a demanda (`servidores/scripts/respaldo_rman.sh`). Ver [`servidores/s5_rman.md`](../servidores/s5_rman.md).
- [ ] S5: job diario con `DBMS_SCHEDULER` que ejecute el script (falta definir `RESP_HORA_DIARIO` y dónde vive el job, coordinado con Isaac).
- [ ] Borrar el tablespace de prueba `ts_prueba_rman` (y su tabla) de `SGSPDB` cuando ya no se necesite.
- [x] S6: switchover, failover y reincorporación probados con el broker `sgs_dg`: [`servidores/s6_switchover_failover.md`](../servidores/s6_switchover_failover.md).
- [ ] S7: situaciones problemáticas y manual del standby.
- [ ] Borrar la tabla de prueba `system.prueba_dg` de `SGSPDB` cuando ya no se necesite.

## Carril B — Base de datos (Isaac)

*(Lo actualiza Isaac.)*
