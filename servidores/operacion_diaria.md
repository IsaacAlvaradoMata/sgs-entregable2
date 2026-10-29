# Operación diaria: encender y apagar los servidores

Rutina para cada sesión de trabajo y para la defensa. Las bases **no arrancan solas** al encender las VMs: hay que levantarlas en orden. Capturas en [`capturas/operacion/`](capturas/operacion/).

> Los comandos de SQL*Plus se ejecutan **uno a la vez** y desde la raíz (`CDB$ROOT`). Una sesión nueva de `sqlplus / as sysdba` ya entra a la raíz; si hay duda, `SHOW CON_NAME`.
> En Linux los comandos van en minúsculas (`exit`, no `EXIT`).

## Encender (primero la principal, después la standby)

Desde que existe el broker y se hacen switchovers, **el rol de cada servidor puede cambiar**. Por eso primero se monta la base y se pregunta el rol, y después se abre en el orden correcto.

1. VirtualBox: encender `SGSPRI` y `SGSSTB`. Entrar por SSH desde la HP:
   ```
   ssh root@192.168.56.101
   ssh root@192.168.56.102
   ```

2. En **cada** servidor (como `oracle`):
   ```
   su - oracle
   lsnrctl start
   sqlplus / as sysdba
   STARTUP MOUNT;
   SELECT db_unique_name, database_role FROM v$database;
   ```

3. En el que diga **`PRIMARY`** (normalmente `SGSPRI`), primero:
   ```
   ALTER DATABASE OPEN;
   SELECT name, database_role, open_mode FROM v$database;   -- PRIMARY  READ WRITE
   SHOW PDBS                                                 -- SGSPDB  READ WRITE (abre sola por SAVE STATE)
   ```

4. En el que diga **`PHYSICAL STANDBY`** (normalmente `SGSSTB`):
   ```
   ALTER DATABASE OPEN READ ONLY;
   ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
   SELECT database_role, open_mode FROM v$database;   -- PHYSICAL STANDBY  READ ONLY WITH APPLY
   ```
   El **broker arranca solo** la aplicación de cambios; puede tardar hasta un minuto en pasar de `READ ONLY` a `READ ONLY WITH APPLY`. Si no pasa, desde `dgmgrl sys@SGSPRI`: `EDIT DATABASE SGSSTB SET STATE='APPLY-ON';` (con el broker activo no se usa `RECOVER MANAGED STANDBY DATABASE`).

5. Revisar la configuración: `dgmgrl sys@SGSPRI` → `SHOW CONFIGURATION;` → `SUCCESS`.

Justo después de `lsnrctl start`, los servicios estáticos aparecen con `status UNKNOWN`; es normal.

## Apagar (primero la standby, después la principal)

> Antes de suspender o apagar la HP, apagar siempre las VMs con esta rutina. Si la HP se suspende con las VMs encendidas, sus relojes se atrasan (pasó el 2026-10-28: unos 54 minutos); chronyd ya está configurado con `makestep 1 -1` para corregirlo de golpe al volver (ver [`s1_sgspri.md`](s1_sgspri.md) §8).

1. **Standby** (normalmente `SGSSTB`; como `oracle`, `sqlplus / as sysdba`):
   ```
   SHUTDOWN IMMEDIATE;
   exit
   ```
2. **Principal** (normalmente `SGSPRI`; como `oracle`, `sqlplus / as sysdba`):
   ```
   SHUTDOWN IMMEDIATE;
   exit
   ```
3. En cada VM, como `root` (`exit` hasta ver el prompt con `#`):
   ```
   shutdown -h now
   ```

## Verificar que la standby sigue sincronizada

```
-- En SGSSTB: número del último archivo aplicado
SELECT MAX(sequence#) AS ultimo_aplicado FROM v$archived_log WHERE applied = 'YES';

-- En SGSPRI: forzar un archivo nuevo
ALTER SYSTEM SWITCH LOGFILE;
SELECT dest_id, status, error FROM v$archive_dest WHERE dest_id = 2;   -- 2  VALID

-- En SGSSTB, unos segundos después: el número sube (en la prueba del 2026-10-27 pasó de 12 a 13)
SELECT MAX(sequence#) AS ultimo_aplicado FROM v$archived_log WHERE applied = 'YES';
```
