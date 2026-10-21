# Pendientes

Qué falta y quién lo tiene. Se actualiza al cerrar cada sesión de trabajo.

## Carril S — Servidores (Andrés)

**Último avance (2026-10-21):** S1 completo salvo Tailscale. Las dos VMs se ven por nombre por la red interna. `SGSSTB` creada como clon de `SGSPRI` y con identidad propia (`sgsstb.localdomain`, `192.168.56.102`, `ORACLE_SID=SGSSTB`, listener). Detalle en [`servidores/s1_sgsstb.md`](../servidores/s1_sgsstb.md).

### Después

- [ ] Crear la base en `SGSPRI` con `dbca` (CDB con `DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, PDB `SGSPDB`, archivelog y FRA en `/opt/oracle/fast_recovery_area`). El comando quedó preparado en la conversación (Paso 21 original).
- [ ] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS` (igual en ambos servidores, requisito de Data Guard).
- [ ] Tailscale en ambas VMs (sin exit node) para que el Mac de Isaac llegue a `SGSPDB`.
- [ ] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).

## Carril B — Base de datos (Isaac)

*(Lo actualiza Isaac.)*
