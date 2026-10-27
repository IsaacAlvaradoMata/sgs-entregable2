# Operación diaria: encender y apagar los servidores

Rutina para cada sesión de trabajo y para la defensa. Las bases **no arrancan solas** al encender las VMs: hay que levantarlas en orden. Capturas en [`capturas/operacion/`](capturas/operacion/).

> Los comandos de SQL*Plus se ejecutan **uno a la vez** y desde la raíz (`CDB$ROOT`). Una sesión nueva de `sqlplus / as sysdba` ya entra a la raíz; si hay duda, `SHOW CON_NAME`.
> En Linux los comandos van en minúsculas (`exit`, no `EXIT`).

## Encender (primero la principal, después la standby)

1. VirtualBox: encender `SGSPRI` y luego `SGSSTB`. Entrar por SSH desde la HP:
   ```
   ssh root@192.168.56.101
   ssh root@192.168.56.102
   ```

2. **`SGSPRI`** (como `oracle`):
   ```
   su - oracle
   lsnrctl start
   sqlplus / as sysdba
   STARTUP;
   SELECT name, database_role, open_mode FROM v$database;   -- SGS  PRIMARY  READ WRITE
   SHOW PDBS                                                 -- SGSPDB  READ WRITE (abre sola por SAVE STATE)
   ```

3. **`SGSSTB`** (como `oracle`):
   ```
   su - oracle
   lsnrctl start
   sqlplus / as sysdba
   STARTUP;
   ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
   ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
   SELECT name, database_role, open_mode FROM v$database;   -- SGS  PHYSICAL STANDBY  READ ONLY WITH APPLY
   ```

Justo después de `lsnrctl start`, los servicios estáticos aparecen con `status UNKNOWN`; es normal.

## Apagar (primero la standby, después la principal)

1. **`SGSSTB`** (como `oracle`, `sqlplus / as sysdba`):
   ```
   ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
   SHUTDOWN IMMEDIATE;
   exit
   ```
2. **`SGSPRI`** (como `oracle`, `sqlplus / as sysdba`):
   ```
   SHUTDOWN IMMEDIATE;
   exit
   ```
3. En cada VM, como `root` (`exit` hasta ver el prompt con `#`):
   ```
   shutdown -h now
   ```
