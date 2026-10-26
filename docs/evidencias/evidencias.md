# Evidencias de implementación

Capturas de los pasos que ya funcionan, en el orden en que se ejecutan. Cada captura muestra información concreta del resultado (no mensajes de ejecución exitosa). Base para el PDF de evidencias.

Nombre de archivo: `<etapa>_<script>_<número>_<qué-muestra>.png`, en [`capturas/`](capturas/).

## B0 — Infraestructura (`bd/01_infraestructura.sql`)

Ambiente: Docker, PDB `FREEPDB1`, conectado como SYSTEM. Verificado el 2026-10-25.

### 1. Tablespaces en línea con su MAXSIZE

```sql
SELECT t.tablespace_name, t.status, d.bytes / 1024 / 1024 AS tamano_mb,
       d.autoextensible, d.maxbytes / 1024 / 1024 AS maxsize_mb
  FROM dba_tablespaces t
  JOIN dba_data_files d ON d.tablespace_name = t.tablespace_name
 WHERE t.tablespace_name LIKE 'SGS%'
 ORDER BY t.tablespace_name;
```

![Tablespaces](capturas/B0_01_01_tablespaces.png)

Los 3 tablespaces del proyecto están `ONLINE` y con autoextensión: `SGS_AUD` (50 MB → 1 GB), `SGS_DATA` (200 MB → 4 GB) y `SGS_IDX` (100 MB → 2 GB). El MAXSIZE es finito para que el monitoreo de uso tenga un límite real contra el cual medir.

### 2. Usuario propietario y cuotas

```sql
SELECT u.username, u.account_status, u.default_tablespace, u.temporary_tablespace,
       q.tablespace_name AS tablespace_cuota,
       DECODE(q.max_bytes, -1, 'ILIMITADA', TO_CHAR(q.max_bytes / 1024 / 1024) || ' MB') AS cuota
  FROM dba_users u
  JOIN dba_ts_quotas q ON q.username = u.username
 WHERE u.username = 'SGS_ADMIN'
 ORDER BY q.tablespace_name;
```

![Usuario y cuotas](capturas/B0_01_02_usuario_cuotas.png)

`SGS_ADMIN` está `OPEN`, con `SGS_DATA` como tablespace por defecto, `TEMP` como temporal y cuota ilimitada en los tres tablespaces del proyecto.

### 3. Privilegios de sistema

```sql
SELECT privilege
  FROM dba_sys_privs
 WHERE grantee = 'SGS_ADMIN'
 ORDER BY privilege;
```

![Privilegios](capturas/B0_01_03_privilegios.png)

`SGS_ADMIN` tiene solo los 8 privilegios de sistema necesarios para crear y mantener sus objetos.

### 4. Roles otorgados

```sql
SELECT granted_role
  FROM dba_role_privs
 WHERE grantee = 'SGS_ADMIN';
```

![Roles](capturas/B0_01_04_roles.png)

La consulta no devuelve filas: `SGS_ADMIN` no tiene roles, en particular `CONNECT`, `RESOURCE` ni `DBA`.
