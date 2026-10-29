# I1 — Preparación de las VMs para el esquema SGS

Lo que necesitan los scripts de `bd/` fuera de la base: correo (wallet y puerto de Gmail), carpeta del padrón, espacio y parámetros del servidor. Data Guard solo replica lo que está dentro de la base, así que el wallet y la carpeta se crean en **las dos** VMs con la misma ruta: después de un switchover o failover el nuevo principal funciona sin cambiar parámetros. Capturas en [`capturas/i1_preparacion/`](capturas/i1_preparacion/).

Estado: **`SGSPRI` y `SGSSTB` preparadas.** Siguiente: instalar los scripts de `bd/` en `SGSPDB` (ver [`configuracion/instalacion_bd_sgspri.md`](configuracion/instalacion_bd_sgspri.md)).

Todo se ejecuta como `oracle` (`ssh root@192.168.56.101` o `.102` y `su - oracle`).

---

## 1. Puerto de Gmail

```
timeout 10 bash -c 'exec 3<>/dev/tcp/smtp.gmail.com/587; head -1 <&3' || echo "SIN RESPUESTA EN 587"
echo QUIT | timeout 15 openssl s_client -connect smtp.gmail.com:465 2>/dev/null | grep -c "BEGIN CERTIFICATE"
```

| Servidor | 587 | 465 |
|---|---|---|
| `SGSPRI` | `SIN RESPUESTA EN 587` | `1` (responde) |
| `SGSSTB` | `SIN RESPUESTA EN 587` | `1` (responde) |

`CORREO_PUERTO` queda en `465`, igual que en desarrollo.

## 2. Wallet del correo

```
WALLET=/opt/oracle/oradata/wallet_sgs
mkdir -p $WALLET/certs && cd $WALLET/certs
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do curl -sfO https://pki.goog/repo/certs/$c.pem && echo "$c OK" || echo "$c FALLO"; done
$ORACLE_HOME/bin/orapki wallet create -wallet $WALLET -auto_login_only
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do $ORACLE_HOME/bin/orapki wallet add -wallet $WALLET -trusted_cert -cert $WALLET/certs/$c.pem -auto_login_only; done
$ORACLE_HOME/bin/orapki wallet display -wallet $WALLET
ls -l $WALLET
```

En los dos servidores: los 6 certificados `OK`; `display` muestra `GTS Root R1` a `R4`, `WR2` y `WE2`; queda `cwallet.sso` con dueño `oracle`. Es la ruta del parámetro `CORREO_WALLET` (`file:/opt/oracle/oradata/wallet_sgs`).

## 3. Carpeta del padrón y disco

```
mkdir -p /opt/oracle/oradata/padron
ls -ld /opt/oracle/oradata/padron     # drwxr-xr-x oracle oinstall
df -h /opt                            # SGSPRI: 58 GB libres de 74 GB
```

Ahí se copian `PADRON_COMPLETO.txt` y `distelec.txt` del TSE antes de `bd/06_padron.sql`.

## 4. Revisión de la base y del servidor

En `SGSPRI` (`sqlplus / as sysdba`):

| Revisión | Resultado |
|---|---|
| `NLS_CHARACTERSET` | `AL32UTF8` |
| `SYSTIMESTAMP` | zona `-06:00` (Costa Rica) |
| Fast Recovery Area | límite 20 GB, usado 1,63 GB, liberable 0,39 GB |
| `resource_limit` | `TRUE` |
| `job_queue_processes` | `40` |
| `remote_login_passwordfile` | `EXCLUSIVE` |

En `SGSSTB` se revisan solo los parámetros del servidor (lo demás es de la base, que es la misma): `resource_limit` = `TRUE`, `job_queue_processes` = `4000`, `remote_login_passwordfile` = `EXCLUSIVE`. `job_queue_processes` es distinto en cada servidor pero en los dos es mayor que cero, así que los jobs corren en cualquiera que sea el principal.
