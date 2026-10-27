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

> **Pendiente:** las capturas 1 a 4 se retoman al cerrar el modelo. Después de tomarlas se agregaron `SGS_MONITOREO` y `SGS_MONITOREO_TABLESPACE` (57 tablas). Las capturas 5 y 6 siguen vigentes.

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

## B2 — Base interna (`bd/03_base_interna.sql`)

Ambiente: Docker, PDB `FREEPDB1`, conectado como `SGS_ADMIN`.

### 1. Registro de errores (`SGS_PKG_ERRORES`)

Prueba: un bloque provoca una división entre cero, la captura con `SGS_PKG_ERRORES.registrar` y la vuelve a lanzar con `RAISE` (el bloque termina con el error esperado `ORA-01476`).

```sql
DECLARE
    v_resultado NUMBER;
BEGIN
    v_resultado := 1 / 0;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        SGS_PKG_ERRORES.registrar('PRUEBA_B2.division_entre_cero');
        RAISE;
END;

SELECT ber_id, ber_programa, ber_codigo, ber_mensaje, ber_traza, ber_usuario_bd, ber_fecha
  FROM SGS_BITACORA_ERROR
 ORDER BY ber_id;
```

![Bitácora de errores](capturas/B2_03_01_bitacora_error.png)

El error quedó registrado con el programa que falló, su código y mensaje, la línea donde ocurrió (traza), la cuenta de Oracle y la fecha. Se registra en una transacción autónoma, por eso queda guardado aunque el bloque que falló haga `ROLLBACK`.

### 2. Parámetros del sistema (`SGS_PKG_PARAMETROS`)

```sql
SELECT par_codigo, par_valor, par_es_cifrado, par_descripcion
  FROM SGS_PARAMETRO
 ORDER BY par_codigo;
```

![Parámetros](capturas/B2_03_02_parametros.png)

Los valores que el enunciado marca como parametrizados están registrados en `SGS_PARAMETRO`: correo, porcentajes de aviso (como fracción), días, meses, premiación, uso máximo de tablespace y los tiempos del standby. Los packages los leen con `SGS_PKG_PARAMETROS.obtener` y `obtener_numero`; se cambian con `actualizar`, que bloquea la fila con `FOR UPDATE NOWAIT`. Los parámetros cifrados (clave del correo y claves de roles) se agregan con el package de cifrado.

### 3. Destinatarios de las notificaciones

```sql
SELECT des_tipo, des_nombre, des_email, des_estado
  FROM SGS_DESTINATARIO
 ORDER BY des_tipo;
```

![Destinatarios](capturas/B2_03_03_destinatarios.png)

Cada tipo de destinatario (coordinador, DBA, gerente) tiene su correo. En desarrollo son alias de la cuenta del proyecto; antes de la defensa se cambian por el correo externo que indique el profesor.

### 4. Cuerpo del package de cifrado ofuscado (`SGS_PKG_CIFRADO`)

```sql
SELECT line, text
  FROM user_source
 WHERE name = 'SGS_PKG_CIFRADO' AND type = 'PACKAGE BODY'
 ORDER BY line
 FETCH FIRST 5 ROWS ONLY;
```

![Package de cifrado ofuscado](capturas/B2_03_04_cifrado_wrapped.png)

El cuerpo del package se instaló con `DBMS_DDL.CREATE_WRAPPED`: Oracle guarda el código ofuscado (`wrapped`), por lo que la llave de cifrado AES-256 que contiene no se puede leer consultando el código fuente. La llave no está en ninguna tabla.

### 5. Clave del correo cifrada en la tabla de parámetros

```sql
SELECT par_codigo, par_es_cifrado, par_valor
  FROM SGS_PARAMETRO
 WHERE par_es_cifrado = 'S';
```

![Parámetro cifrado](capturas/B2_03_05_parametro_cifrado.png)

La contraseña de aplicación del correo se guarda cifrada con `DBMS_CRYPTO` (AES-256, CBC, vector inicial aleatorio). En la tabla solo queda el valor cifrado en hexadecimal; el package de correo la descifra con `SGS_PKG_CIFRADO.obtener_parametro` al momento de enviar.

### 6. Validación de contraseñas de los usuarios del sistema

```sql
SELECT SGS_PKG_CIFRADO.validar_usuario('lmora', 'Gerente2026') AS clave_correcta,
       SGS_PKG_CIFRADO.validar_usuario('lmora', 'otraClave')   AS clave_incorrecta,
       SGS_PKG_CIFRADO.validar_usuario('noexiste', 'x')        AS usuario_inexistente
  FROM DUAL;
```

![Validación de usuarios](capturas/B2_03_06_validar_usuario.png)

Las contraseñas de los usuarios del sistema se guardan como hash SHA-256 con sal. La validación acepta la clave correcta y rechaza una clave incorrecta y un usuario inexistente.

### 7. Lista de control de red para el correo

```sql
SELECT host, lower_port, upper_port, principal, privilege
  FROM dba_host_aces
 WHERE principal = 'SGS_ADMIN'
 ORDER BY privilege;
```

![ACL de red](capturas/B2_03_07_acl_red.png)

Oracle bloquea toda conexión saliente. La lista de control de red solo autoriza a `SGS_ADMIN` a conectarse a `smtp.gmail.com` (en sus puertos seguros) y a resolver ese nombre. La captura se tomó con el puerto 587; después se agregó el 465, que es el que se usa en la red de desarrollo.

### 8. Correo enviado desde Oracle (`SGS_PKG_CORREO`)

```sql
BEGIN
    SGS_PKG_CORREO.enviar_a_tipo('DBA', 'Prueba SGS: correo enviado desde Oracle',
        'Hola, este correo lo envió Oracle directamente por SMTP sobre TLS, sin VPN.' || CHR(13) || CHR(10)
        || 'Prueba de caracteres: tildes áéíóú, eñe ñ, colones ₡100.000.');
END;
```

![Correo recibido](capturas/B2_03_08_correo_recibido.png)

Oracle envía el correo directamente a Gmail por SMTP sobre TLS (puerto 465), sin VPN. El package lee el servidor, el puerto, el wallet y el remitente de `SGS_PARAMETRO`, descifra la clave en el momento del envío y toma el destinatario de `SGS_DESTINATARIO` (tipo DBA). El texto llega en UTF-8, con tildes, eñe y el símbolo de colones.

## B3 — Reglas de negocio (`bd/04_reglas_negocio.sql`)

Ambiente: Docker, PDB `FREEPDB1`, conectado como `SGS_ADMIN`.

### 1. Registro de un cliente nacional desde el padrón (`SGS_PKG_CLIENTES`)

```sql
DECLARE
    v_id NUMBER;
BEGIN
    SGS_PKG_CLIENTES.registrar_nacional(p_cedula => '199990005', p_sexo => 'F', p_estado_civil => 'S',
                                        p_email => 'sgs.notificaciones.una+laura@gmail.com', p_id_cliente => v_id);
    SGS_PKG_CLIENTES.asignar_credito(v_id, 150000);
END;

SELECT c.cli_id, c.cli_cedula, c.cli_nombre, p.clp_apellido1, p.clp_apellido2, p.clp_sexo,
       p.clp_id_padron, c.cli_es_preferencial, x.cxc_limite_credito, x.cxc_saldo
  FROM SGS_CLIENTE c
  JOIN SGS_CLIENTE_PERSONA p ON p.clp_id_cliente = c.cli_id
  JOIN SGS_CUENTA_COBRAR x ON x.cxc_id_cliente = c.cli_id
 WHERE c.cli_cedula = '199990005';
```

![Cliente registrado desde el padrón](capturas/B3_04_01_cliente_padron.png)

Con solo la cédula, el procedimiento tomó el nombre y los apellidos del padrón y dejó a la clienta enlazada a su persona del padrón. El trigger `TRG_CLI_CREA_CUENTA` le creó la cuenta por cobrar, y `asignar_credito` (que bloquea la cuenta con `FOR UPDATE NOWAIT`) le asignó ₡150.000 de límite y la marcó como preferencial.

### 2. Rechazo: cédula que no está en el padrón

```sql
DECLARE
    v_id NUMBER;
BEGIN
    SGS_PKG_CLIENTES.registrar_nacional(p_cedula => '199990099', p_sexo => 'M', p_id_cliente => v_id);
END;
```

![Cédula fuera del padrón](capturas/B3_04_02_error_cedula_padron.png)

Error esperado: un cliente nacional solo se registra si su cédula existe en el padrón. El procedimiento deshace lo hecho (`ROLLBACK TO SAVEPOINT`), registra el error en la bitácora de errores y lo devuelve con un mensaje claro.

### 3. Rechazo: enlazar a un cliente con otra persona del padrón

```sql
UPDATE SGS_CLIENTE_PERSONA
   SET clp_id_padron = (SELECT pad_id FROM SGS_PADRON WHERE pad_cedula = '199990002')
 WHERE clp_id_cliente = (SELECT cli_id FROM SGS_CLIENTE WHERE cli_cedula = '199990001');
```

![Enlace al padrón inválido](capturas/B3_04_03_error_enlace_padron.png)

Error esperado: el trigger `TRG_CLP_VALIDA` impide enlazar a un cliente con una persona del padrón que tiene otra cédula. La regla se cumple aunque el cambio se haga con un `UPDATE` directo, sin pasar por el package.

### 4. Rechazo: datos de persona para un cliente empresa

```sql
INSERT INTO SGS_CLIENTE_PERSONA (clp_id, clp_id_cliente, clp_apellido1)
VALUES (SEQ_CLIENTE_PERSONA.NEXTVAL, (SELECT cli_id FROM SGS_CLIENTE WHERE cli_cedula = '3101654321'), 'X');
```

![Empresa con datos de persona](capturas/B3_04_04_error_empresa_persona.png)

Error esperado: los datos de persona (apellidos, sexo, estado civil, etc.) solo aplican a personas. El trigger `TRG_CLP_VALIDA` protege la relación de subtipo entre `SGS_CLIENTE` y `SGS_CLIENTE_PERSONA`.

### 5. Historial automático de precios de costo

```sql
UPDATE SGS_PRODUCTO SET PRO_PRECIO_COSTO = 1550 WHERE PRO_CODIGO = 'ABA-001';
UPDATE SGS_PRODUCTO SET PRO_PRECIO_COSTO = 1550 WHERE PRO_CODIGO = 'ABA-001';
COMMIT;

SELECT p.pro_codigo, h.hpr_precio_ant, h.hpr_precio_nue, h.hpr_fecha, h.hpr_usuario
  FROM SGS_HISTORICO_PRECIO h
  JOIN SGS_PRODUCTO p ON p.pro_id = h.hpr_id_producto
 WHERE p.pro_codigo = 'ABA-001'
 ORDER BY h.hpr_id;
```

![Historial de precios](capturas/B3_04_05_historico_precio.png)

El trigger `TRG_PRO_HISTORICO_PRECIO` registró el cambio de costo del arroz (₡1.500 → ₡1.550) con la cuenta de Oracle y la fecha. El segundo `UPDATE` deja el mismo costo, así que no genera registro. La primera fila es el registro inicial de los datos de catálogo. (La hora sale en UTC porque así está configurado el contenedor de desarrollo.)

### 6. Cuentas por cobrar y por pagar automáticas

Prueba hecha con `INSERT` directos (sin packages), en modo de commit manual y deshecha al final con `ROLLBACK`: los triggers reaccionan aunque nadie use el package.

**Factura a crédito pendiente → saldo del cliente y detalle de la cuenta por cobrar**

```sql
INSERT INTO SGS_FACTURA_VENTA (FV_ID, FV_ID_CLIENTE, FV_ID_SUCURSAL, FV_ID_USUARIO, FV_SUBTOTAL, FV_TOTAL, FV_ES_CREDITO, FV_ESTADO)
VALUES (SEQ_FACTURA_VENTA.NEXTVAL,
        (SELECT CLI_ID FROM SGS_CLIENTE WHERE CLI_CEDULA = '199990001'),
        (SELECT SUC_ID FROM SGS_SUCURSAL WHERE SUC_NOMBRE = 'Sucursal San Isidro'),
        (SELECT USU_ID FROM SGS_USUARIO WHERE USU_USERNAME = 'mcastro'),
        50000, 50000, 'S', 'P');

SELECT f.fv_id, f.fv_total, f.fv_es_credito, f.fv_estado,
       d.dcc_monto_original, d.dcc_saldo, x.cxc_limite_credito, x.cxc_saldo
  FROM SGS_FACTURA_VENTA f
  JOIN SGS_DETALLE_CUENTA_COBRAR d ON d.dcc_id_factura = f.fv_id
  JOIN SGS_CUENTA_COBRAR x ON x.cxc_id = d.dcc_id_cuenta
 WHERE f.fv_id = (SELECT MAX(fv_id) FROM SGS_FACTURA_VENTA);
```

![Factura a crédito](capturas/B3_04_06_factura_credito_cxc.png)

`TRG_FV_CUENTA_COBRAR` agregó la factura al detalle de la cuenta por cobrar y `TRG_DCC_SALDO` aumentó el saldo de la clienta a ₡50.000.

**Pagos → la factura pasa a cancelada**

```sql
INSERT INTO SGS_PAGO_FACTURA_VENTA (PFV_ID, PFV_ID_FACTURA, PFV_ID_TIPO_PAGO, PFV_MONTO)
VALUES (SEQ_PAGO_FACTURA_VENTA.NEXTVAL, (SELECT MAX(FV_ID) FROM SGS_FACTURA_VENTA),
        (SELECT TPA_ID FROM SGS_TIPO_PAGO WHERE TPA_NOMBRE = 'SINPE Movil'), 20000);
INSERT INTO SGS_PAGO_FACTURA_VENTA (PFV_ID, PFV_ID_FACTURA, PFV_ID_TIPO_PAGO, PFV_MONTO)
VALUES (SEQ_PAGO_FACTURA_VENTA.NEXTVAL, (SELECT MAX(FV_ID) FROM SGS_FACTURA_VENTA),
        (SELECT TPA_ID FROM SGS_TIPO_PAGO WHERE TPA_NOMBRE = 'Efectivo'), 30000);
```

![Factura cancelada](capturas/B3_04_07_factura_cancelada.png)

Cada abono bajó el saldo de la factura (`TRG_PFV_ABONO`) y de la cuenta (`TRG_DCC_SALDO`). Al llegar a 0, la factura cambió sola de pendiente (`P`) a cancelada (`C`).

**Rechazo: factura que supera el límite de crédito**

![Límite de crédito](capturas/B3_04_08_error_limite_credito.png)

Una factura a crédito de ₡250.000 para una clienta con límite de ₡200.000 se rechaza completa: no se guarda con estado pendiente.

**Rechazo: crédito para un cliente no preferencial**

![Cliente no preferencial](capturas/B3_04_09_error_no_preferencial.png)

`TRG_FV_VALIDA_CREDITO` solo permite facturar a crédito a clientes preferenciales y activos (nunca al cliente por defecto).

**Rechazo: pago mayor al saldo de la factura**

![Pago excesivo](capturas/B3_04_10_error_pago_excesivo.png)

Sobre una factura de ₡10.000, un pago de ₡15.000 se rechaza.

**Factura de proveedor a crédito → cuenta por pagar**

```sql
INSERT INTO SGS_FACTURA_PROVEEDOR (FP_ID, FP_ID_PROVEEDOR, FP_ID_USUARIO, FP_NUMERO, FP_SUBTOTAL, FP_TOTAL, FP_ES_CREDITO, FP_ESTADO)
VALUES (SEQ_FACTURA_PROVEEDOR.NEXTVAL,
        (SELECT PRV_ID FROM SGS_PROVEEDOR WHERE PRV_CEDULA_JURIDICA = '3101100005'),
        (SELECT USU_ID FROM SGS_USUARIO WHERE USU_USERNAME = 'crodriguez'),
        'DAS-0001', 380000, 380000, 'S', 'P');
```

![Cuenta por pagar](capturas/B3_04_11_factura_proveedor_cxp.png)

El mismo mecanismo del lado de los proveedores: la factura pendiente aumenta lo que se le debe al proveedor (₡380.000 de ₡500.000).

**Rechazo: factura de proveedor que supera el límite**

![Límite con el proveedor](capturas/B3_04_12_error_limite_proveedor.png)

Una segunda compra a crédito de ₡200.000 llevaría la deuda a ₡580.000 y se rechaza.

### 7. Compras (`SGS_PKG_COMPRAS`)

Operaciones completas con el package: una sola transacción con `SAVEPOINT`, bloqueo de la cuenta del proveedor con `FOR UPDATE WAIT 5`, `COMMIT`, y ante error `ROLLBACK TO SAVEPOINT` + bitácora de errores. Los triggers de los pasos anteriores reaccionan a lo que inserta el package.

**Compra a crédito: factura y cuenta por pagar**

```sql
DECLARE
    v_id NUMBER;
BEGIN
    SGS_PKG_COMPRAS.registrar_compra(
        p_proveedor  => '3101100001',
        p_numero     => 'LDV-1001',
        p_usuario    => 'crodriguez',
        p_es_credito => 'S',
        p_lineas     => SGS_PKG_COMPRAS.t_lineas(
                            1 => SGS_PKG_COMPRAS.t_linea(codigo => 'LAC-001', cantidad => 200, costo => 650,  vencimiento => TRUNC(SYSDATE) + 20),
                            2 => SGS_PKG_COMPRAS.t_linea(codigo => 'LAC-002', cantidad => 50,  costo => 2300, vencimiento => TRUNC(SYSDATE) + 55)),
        p_id_factura => v_id);
END;
```

![Compra a crédito](capturas/B3_04_13_compra_credito.png)

Subtotal ₡245.000 + 1 % de impuesto = ₡247.450, pendiente y cargado a la cuenta por pagar del proveedor.

**Lotes, existencias y movimientos de la compra**

![Lotes de la compra](capturas/B3_04_14_compra_lotes_existencia.png)

Cada línea creó su lote con fecha de ingreso y de vencimiento, registró el movimiento `COMPRA` en la Bodega Central (el inventario está centralizado) y el trigger `TRG_MOV_EXISTENCIA` subió la existencia.

**Costo distinto → historial de precios**

![Historial de costo](capturas/B3_04_15_compra_historial_costo.png)

El queso se compró a ₡2.300 (costaba ₡2.200): el package actualizó el costo del producto y el trigger registró el cambio. La leche se compró al mismo costo y no genera registro.

**Compra de contado**

![Compra de contado](capturas/B3_04_16_compra_contado.png)

Una compra de contado nace cancelada, con su pago registrado, y no entra a la cuenta por pagar.

**Abono y devolución al proveedor**

```sql
DECLARE
    v_factura NUMBER;
    v_nota    NUMBER;
BEGIN
    SELECT fp_id INTO v_factura FROM SGS_FACTURA_PROVEEDOR WHERE fp_numero = 'LDV-1001';
    SGS_PKG_COMPRAS.registrar_pago(p_id_factura => v_factura, p_monto => 100000, p_tipo_pago => 'Transferencia');
    SGS_PKG_COMPRAS.registrar_devolucion(
        p_id_factura => v_factura,
        p_lineas     => SGS_PKG_COMPRAS.t_lineas_devolucion(
                            1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'LAC-002', cantidad => 10)),
        p_motivo     => 'Empaque dañado',
        p_usuario    => 'crodriguez',
        p_id_nota    => v_nota);
END;
```

![Abono y nota de crédito](capturas/B3_04_17_compra_abono_devolucion.png)

El abono de ₡100.000 y la nota de crédito de ₡23.230 (10 de los 50 quesos) rebajan el saldo a ₡124.220.

![Devolución en el inventario](capturas/B3_04_18_devolucion_inventario.png)

La devolución sale del mismo lote que entró con la compra: el movimiento `DEVOLUCION_PROVEEDOR` bajó la existencia de 50 a 40.

**Rechazos**

![Producto de otro proveedor](capturas/B3_04_19_error_producto_proveedor.png)

No se le puede comprar a un proveedor un producto que no es suyo.

![Devolución mayor a lo comprado](capturas/B3_04_20_error_devolucion_excesiva.png)

`TRG_DNCP_VALIDA` impide devolver más de lo comprado, sumando todas las notas de crédito de la línea.

![Movimiento inmutable](capturas/B3_04_21_error_movimiento_inmutable.png)

Los movimientos de inventario son la historia del inventario: `TRG_MOV_INMUTABLE` impide modificarlos o borrarlos; un error se corrige con otro movimiento.

### 8. Traslados con selección de lotes por FEFO (`SGS_PKG_INVENTARIO`)

```sql
DECLARE
    v_id NUMBER;
BEGIN
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100001', p_numero => 'LDV-1002', p_usuario => 'crodriguez', p_es_credito => 'S',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'LAC-001', cantidad => 100, costo => 650, vencimiento => TRUNC(SYSDATE) + 40)),
        p_id_factura => v_id);
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal San Isidro', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'LAC-001', cantidad => 230),
                                    2 => SGS_PKG_INVENTARIO.t_linea(codigo => 'LAC-002', cantidad => 20),
                                    3 => SGS_PKG_INVENTARIO.t_linea(codigo => 'ABA-001', cantidad => 40),
                                    4 => SGS_PKG_INVENTARIO.t_linea(codigo => 'FRU-001', cantidad => 30)), v_id);
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal Buenos Aires', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'LAC-001', cantidad => 50),
                                    2 => SGS_PKG_INVENTARIO.t_linea(codigo => 'ABA-001', cantidad => 30)), v_id);
END;
```

**Verificación: existencias por producto y sucursal, y consistencia con los movimientos**

![Verificación de traslados](capturas/B3_04_22_traslado_verificacion.png)

Las existencias de cada producto en la Bodega Central y en las sucursales quedaron como se esperaba, y en ningún lote la existencia difiere de la suma de sus movimientos (entradas menos salidas).

**Reparto de lotes por FEFO**

![FEFO](capturas/B3_04_23_traslado_fefo.png)

De las 230 leches enviadas a San Isidro, 200 salieron del lote que vence primero (lo dejó en 0 en la central) y 30 del lote siguiente. Los lotes se bloquean con `SELECT … FOR UPDATE WAIT 5` mientras se reparten, para que dos operaciones simultáneas no tomen las mismas unidades.

**Rechazos registrados en la bitácora de errores**

![Rechazos del traslado](capturas/B3_04_24_traslado_rechazos.png)

Existencia insuficiente, sucursal inexistente y origen igual al destino (restricción `CK_TRA_ORIGEN_DESTINO`). Cada intento se deshizo con `ROLLBACK TO SAVEPOINT` y quedó registrado por `SGS_PKG_ERRORES`.
