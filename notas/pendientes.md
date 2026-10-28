# Pendientes

Qué falta y quién lo tiene. Se actualiza al cerrar cada sesión de trabajo.

## Carril S — Servidores (Andrés)

**Último avance (2026-10-28):** Tailscale en las dos VMs y conexión a `SGSPDB` por Tailscale probada; `local_listener` corregido en ambos servidores. **Siguiente sesión: S5 (RMAN).** Antes (2026-10-26): **S3 completo: Data Guard funcionando** (`SGSSTB` standby física en Active Data Guard; probado con un dato que viaja de `SGSPRI` a `SGSSTB`). Detalle en [`servidores/s3_dataguard.md`](../servidores/s3_dataguard.md). Antes: base de datos creada en `SGSPRI` (`DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, ARCHIVELOG, PDB `SGSPDB`); detalle en [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md). Antes: S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

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
- [ ] S5: respaldos con RMAN.
- [ ] S6: switchover, failover y reincorporación (broker de Data Guard).
- [ ] Borrar la tabla de prueba `system.prueba_dg` de `SGSPDB` cuando ya no se necesite.

## Carril B — Base de datos (Isaac)

*(Lo actualiza Isaac.)*
