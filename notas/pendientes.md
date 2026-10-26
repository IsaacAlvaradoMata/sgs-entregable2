# Pendientes

Qué falta y quién lo tiene. Se actualiza al cerrar cada sesión de trabajo.

## Carril S — Servidores (Andrés)

**Último avance (2026-10-26):** **S3 completo: Data Guard funcionando** (`SGSSTB` standby física en Active Data Guard; probado con un dato que viaja de `SGSPRI` a `SGSSTB`). Detalle en [`servidores/s3_dataguard.md`](../servidores/s3_dataguard.md). Antes: base de datos creada en `SGSPRI` (`DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, ARCHIVELOG, PDB `SGSPDB`); detalle en [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md). Antes: S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

### Después

- [x] Crear la base en `SGSPRI` con `dbca`.
- [x] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS`.
- [ ] Avisar a Isaac que `SGSPDB` ya existe en `SGSPRI` (punto I1).
- [ ] Antes de la defensa: cambiar las contraseñas de `SYS`, `SYSTEM` y `PDBADMIN` por unas fuertes.
- [ ] Tailscale en ambas VMs (sin exit node) para que el Mac de Isaac llegue a `SGSPDB`.
- [x] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).
- [ ] **Siguiente sesión: empezar probando el arranque** (el apagado del 2026-10-26 funcionó en `SGSSTB`; `SGSPRI` ya estaba abajo). Si todo responde, documentarlo en `servidores/` como procedimiento probado:
  - `SGSPRI` (como `oracle`): `lsnrctl start` → `sqlplus / as sysdba` → `STARTUP;` (la PDB abre sola por `SAVE STATE`).
  - `SGSSTB` (como `oracle`): `lsnrctl start` → `sqlplus / as sysdba` → `STARTUP;` → `ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;` → `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;` → verificar `READ ONLY WITH APPLY`.
  - Apagado: primero `SGSSTB` (`RECOVER MANAGED STANDBY DATABASE CANCEL;` + `SHUTDOWN IMMEDIATE;`), después `SGSPRI` (`SHUTDOWN IMMEDIATE;`), luego `shutdown -h now` como `root`. Los comandos de SQL*Plus se ejecutan desde `CDB$ROOT` (sesión nueva o `SHOW CON_NAME`).
- [ ] S4: administración parametrizada del standby (necesita la tabla de parámetros de Isaac, I2).
- [ ] S5: respaldos con RMAN.
- [ ] S6: switchover, failover y reincorporación (broker de Data Guard).
- [ ] Borrar la tabla de prueba `system.prueba_dg` de `SGSPDB` cuando ya no se necesite.

## Carril B — Base de datos (Isaac)

*(Lo actualiza Isaac.)*
