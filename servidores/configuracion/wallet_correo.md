# Wallet para el correo desde Oracle

Gmail exige conexión cifrada (TLS). Oracle valida el certificado del servidor contra un **wallet** con los certificados de Google. El wallet es un archivo del sistema operativo: **Data Guard no lo replica**, así que se crea en `SGSPRI` **y** en `SGSSTB`, en la misma ruta.

Probado en desarrollo (Docker, Oracle 23ai) el 2026-10-26. Comandos como el usuario `oracle`.

## 1. Comprobar qué puerto de Gmail responde

```bash
timeout 10 bash -c 'exec 3<>/dev/tcp/smtp.gmail.com/587; head -1 <&3' || echo "SIN RESPUESTA EN 587"
echo QUIT | timeout 15 openssl s_client -connect smtp.gmail.com:465 2>/dev/null | grep -c "BEGIN CERTIFICATE" 
```

- Si el 587 responde `220 smtp.gmail.com ESMTP`, se puede usar el 587 (STARTTLS).
- Si no, se usa el 465 (TLS desde el inicio). En la red de desarrollo el 587 no respondió y se usa el 465.
- El puerto se configura en el parámetro `CORREO_PUERTO` (`SGS_PKG_PARAMETROS.actualizar('CORREO_PUERTO', '465')`). La ACL de `bd/03_base_interna.sql` ya autoriza los dos.

## 2. Crear el wallet

Ruta: `/opt/oracle/oradata/wallet_sgs`, la misma en desarrollo, en `SGSPRI` y en `SGSSTB`. Así el parámetro `CORREO_WALLET` no cambia entre ambientes ni después de un switchover.

```bash
WALLET=/opt/oracle/oradata/wallet_sgs
mkdir -p $WALLET/certs && cd $WALLET/certs

# Raices de Google (GTS Root R1 a R4) e intermedios (WE2 y WR2): Gmail alterna entre dos cadenas
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do curl -sfO https://pki.goog/repo/certs/$c.pem && echo "$c OK" || echo "$c FALLO"; done

# Wallet de inicio automatico (sin contrasena): solo contiene certificados publicos
$ORACLE_HOME/bin/orapki wallet create -wallet $WALLET -auto_login_only
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do $ORACLE_HOME/bin/orapki wallet add -wallet $WALLET -trusted_cert -cert $WALLET/certs/$c.pem -auto_login_only; done
```

## 3. Verificar

```bash
$ORACLE_HOME/bin/orapki wallet display -wallet $WALLET
ls -l $WALLET
```

- En "Trusted Certificates" aparecen 6: GTS Root R1, R2, R3, R4, WE2 y WR2.
- Existe el archivo `cwallet.sso`.

## 4. Apuntar Oracle al wallet

`bd/03_base_interna.sql` ya deja `CORREO_WALLET` = `file:/opt/oracle/oradata/wallet_sgs`. Solo si se usara otra ruta, como `SGS_ADMIN`: `SGS_PKG_PARAMETROS.actualizar('CORREO_WALLET', 'file:<ruta>')`.

Prueba: `SGS_PKG_CORREO.enviar_a_tipo('DBA', 'Prueba', 'Texto')` y revisar la bandeja de la cuenta del proyecto.
