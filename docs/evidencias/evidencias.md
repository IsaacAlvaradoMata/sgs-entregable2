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

## B1 — Modelo (`bd/02_modelo.sql`)

Ambiente: Docker, PDB `FREEPDB1`, conectado como `SGS_ADMIN`. Ejecución completa desde cero (`00` → `01` → `02`) el 2026-10-26.

### 1. Resumen de objetos del esquema

```sql
SELECT 'Tablas' AS objeto, COUNT(*) AS cantidad FROM user_tables
UNION ALL SELECT 'Secuencias', COUNT(*) FROM user_sequences
UNION ALL SELECT 'Indices', COUNT(*) FROM user_indexes
UNION ALL SELECT 'Vistas', COUNT(*) FROM user_views;
```

![Resumen de objetos](capturas/B1_02_01_resumen_objetos.png)

El esquema tiene 55 tablas, cada una con su secuencia (55), 163 índices y la vista del precio de venta.

### 2. Tablas por tablespace

```sql
SELECT tablespace_name, COUNT(*) AS tablas
  FROM user_tables
 GROUP BY tablespace_name
 ORDER BY tablespace_name;
```

![Tablas por tablespace](capturas/B1_02_02_tablas_tablespace.png)

Las tablas de auditoría (histórico de precios, bitácora, detalle de bitácora y bitácora de errores) están en `SGS_AUD`; las 51 restantes en `SGS_DATA`.

### 3. Índices por tablespace

```sql
SELECT tablespace_name, COUNT(*) AS indices
  FROM user_indexes
 GROUP BY tablespace_name;
```

![Índices por tablespace](capturas/B1_02_03_indices_tablespace.png)

Los 163 índices (llaves primarias, únicas, índices únicos funcionales e índices secundarios) están en `SGS_IDX`, separados de los datos.

### 4. Restricciones de integridad por tipo

```sql
SELECT DECODE(constraint_type, 'P', 'Llave primaria', 'R', 'Llave foranea',
                               'U', 'Unica', 'C', 'Check') AS tipo,
       COUNT(*) AS cantidad
  FROM user_constraints
 WHERE constraint_type IN ('P', 'R', 'U')
    OR (constraint_type = 'C' AND search_condition_vc NOT LIKE '%IS NOT NULL')
 GROUP BY constraint_type
 ORDER BY constraint_type;
```

![Restricciones](capturas/B1_02_04_restricciones.png)

55 llaves primarias, 74 llaves foráneas, 43 restricciones únicas y 86 restricciones CHECK (sin contar los `NOT NULL`).

### 5. Objetos inválidos

```sql
SELECT object_name, object_type, status
  FROM user_objects
 WHERE status <> 'VALID';
```

![Objetos inválidos](capturas/B1_02_05_objetos_invalidos.png)

La consulta no devuelve filas: todos los objetos del esquema compilaron correctamente.

### 6. Precio de venta calculado

```sql
SELECT pro_codigo, suc_nombre, pro_precio_costo, ps_pct_utilidad, pct_descuento,
       art_pct_impuesto, precio_sin_impuesto, monto_impuesto, precio_venta
  FROM SGS_VW_PRECIO_VENTA
 WHERE (pro_codigo IN ('LAC-001', 'BEB-001') AND suc_nombre = 'Sucursal San Isidro')
    OR (pro_codigo = 'LIM-001' AND suc_nombre = 'Sucursal Buenos Aires')
 ORDER BY pro_codigo;
```

![Precio de venta](capturas/B1_02_06_precio_venta.png)

El precio de venta se calcula a partir del costo, la utilidad de la sucursal, el mayor descuento vigente (topado al descuento máximo de la sucursal) y el impuesto del artículo. Ejemplo: el detergente (`LIM-001`) cuesta ₡1.700; con 30 % de utilidad son ₡2.210; el 15 % de descuento de su familia deja ₡1.878,50; con 13 % de impuesto el precio de venta es ₡2.122,71.
