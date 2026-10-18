# Pendientes

Qué falta y quién lo tiene. Se actualiza al cerrar cada sesión de trabajo.

## Carril S — Servidores (Andrés)

**Último avance (2026-10-17):** `SGSPRI` lista hasta el software de Oracle 21c y el listener, **sin base de datos creada**. Detalle en [`servidores/s1_sgspri.md`](../servidores/s1_sgspri.md) y [`servidores/s2_sgspri.md`](../servidores/s2_sgspri.md).

### Siguiente paso: clonar SGSPRI → SGSSTB

Se clona **antes** de crear la base, para que la standby quede solo con el software (como pide S2) y con rutas idénticas.

1. Apagar `SGSPRI` limpiamente (`shutdown -h now` como `root`).
2. VirtualBox → clic derecho en `SGSPRI` → Clonar:
   - Nombre `SGSSTB`.
   - **Generar nuevas direcciones MAC para todos los adaptadores de red.**
   - Clonación **completa**.
3. Encender **solo `SGSSTB`** y ajustar lo que quedó con datos de `SGSPRI`:
   - Hostname → `sgsstb.localdomain` (`hostnamectl set-hostname`).
   - IP de `enp0s8` → `192.168.56.102/24` (`nmcli`).
   - `ORACLE_SID=SGSSTB` en `~/.bash_profile` del usuario `oracle`.
   - Listener: `listener.ora` (en `/opt/oracle/homes/OraDBHome21cEE/network/admin`) apunta a `sgspri.localdomain`; cambiarlo a `sgsstb.localdomain`.
4. Encender las dos y probar que se ven (`ping sgspri` / `ping sgsstb`).

### Después

- [ ] Crear la base en `SGSPRI` con `dbca` (CDB con `DB_NAME=SGS`, `DB_UNIQUE_NAME=SGSPRI`, PDB `SGSPDB`, archivelog y FRA en `/opt/oracle/fast_recovery_area`). El comando quedó preparado en la conversación (Paso 21 original).
- [ ] Anotar en `docs/decisiones.md` la decisión `DB_NAME = SGS` (igual en ambos servidores, requisito de Data Guard).
- [ ] Tailscale en ambas VMs (sin exit node) para que el Mac de Isaac llegue a `SGSPDB`.
- [ ] S3: Data Guard (`SGSSTB` como standby física de `SGSPRI`).

## Carril B — Base de datos (Isaac)

*(Lo actualiza Isaac.)*
