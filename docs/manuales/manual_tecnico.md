---
titulo: Manual Técnico de Administración y Mantenimiento
---

# Introducción

Este manual explica cómo está construido el Sistema de Gestión de Supermercados (SGS) dentro de la base de datos y cómo se administra en el día a día: el modelo, los packages y triggers, las reglas de negocio, las bitácoras, las notificaciones, los procesos programados, la seguridad y el monitoreo. La última parte reúne las tareas de mantenimiento del DBA y los problemas que se presentaron durante el proyecto con su solución.

La instalación de los servidores y del esquema está en el manual de instalación y despliegue; la administración de la base standby, en el manual de administración del standby. El detalle de cada tabla y columna está en el diccionario de datos.

## Arquitectura lógica

Todo el sistema vive en el esquema `SGS_ADMIN` de la PDB `SGSPDB`, repartido en tres tablespaces:

| Tablespace | Contenido | Tamaño máximo |
|---|---|---|
| `SGS_DATA` | Tablas del sistema | 4 GB |
| `SGS_IDX` | Índices | 2 GB |
| `SGS_AUD` | Bitácoras de cambios y de errores | 1 GB |

El código se organiza en capas:

- **Packages:** toda la lógica del sistema. Las operaciones de negocio (ventas, compras, pagos, devoluciones, traslados, registro de clientes) se hacen llamando a sus procedimientos: validan los datos, bloquean las filas que van a cambiar, manejan la transacción y devuelven mensajes claros.
- **Triggers:** lo que el enunciado pide que ocurra "automáticamente" (saldos de las cuentas, estado de las facturas, existencias, historial de precios) y las validaciones que cruzan tablas. Funcionan aunque alguien inserte directamente en las tablas sin pasar por un package.
- **Jobs de `DBMS_SCHEDULER`:** los procesos automáticos (notificaciones, cierre diario, premiación, monitoreo, respaldo y administración del standby).
- **Tablas de configuración:** los valores que el enunciado pide parametrizar están en `SGS_PARAMETRO`, y los correos que reciben las notificaciones en `SGS_DESTINATARIO`.

| Script | Módulo |
|---|---|
| `02_modelo.sql` | Modelo de datos |
| `03_base_interna.sql` | Errores, parámetros, cifrado y correo |
| `04_reglas_negocio.sql` | Clientes, crédito, compras, inventario, ventas y sus triggers |
| `05_bitacoras.sql` | Auditoría |
| `06_padron.sql` | Padrón nacional |
| `07_procesos.sql` | Procesos programados y notificaciones |
| `08_seguridad.sql` | Perfiles, usuarios y roles |
| `09_monitoreo.sql` | Monitoreo, vistas materializadas y optimización |
| `11_standby.sql` | Respaldo diario y administración del standby |

# Modelo de datos

El modelo tiene 57 tablas agrupadas en 9 bloques funcionales: catálogos base, personas (clientes, proveedores y padrón), producto, compras y cuentas por pagar, ventas y cuentas por cobrar, devoluciones, inventario, promociones y descuentos, y administración (parámetros, destinatarios, bitácoras, cierres, premiaciones y monitoreo).

Convenciones:

- Todos los objetos llevan el prefijo `SGS_`; cada columna, el prefijo corto de su tabla (`PAI_` en `SGS_PAIS`).
- Cada tabla tiene una llave primaria numérica alimentada por su secuencia `SEQ_<tabla>`.
- Las restricciones tienen nombre: `PK_`, `FK_`, `UK_` y `CK_`; los índices propios, `IDX_`.
- Estados e indicadores en `VARCHAR2(1)` con `CHECK`: `A`/`I` (activo, inactivo), `S`/`N` (sí, no); factura `P`/`C`/`N` (pendiente, cancelada, anulada).
- Montos en `NUMBER(14,2)`. Porcentajes como fracción en `NUMBER(5,4)` entre 0 y 1 (`0.15` = 15 %).

Decisiones del modelo que guían el resto del sistema:

- **Cuentas con encabezado y detalle.** Cada cliente tiene una cuenta por cobrar y cada proveedor una cuenta por pagar, con su límite de crédito y su saldo total (es la fila que se bloquea al facturar a crédito). El detalle tiene una fila por cada factura a crédito con su monto original y su saldo.
- **Inventario por lote.** Cada línea de una compra crea un lote con su fecha de ingreso y de vencimiento. La existencia es por lote y sucursal, y cada entrada o salida queda en `SGS_MOVIMIENTO_INVENTARIO` con el documento que la causó.
- **Bodega central.** Es la sucursal marcada con `SUC_ES_CENTRAL = 'S'`: allí entran todas las compras y de allí se traslada a las sucursales, que son las que venden.
- **Clientes.** Un cliente es persona (nacional o extranjera) o empresa. El cliente nacional se enlaza a su persona del padrón, de donde toma nombre y apellidos.

El diccionario de datos (`SGS_diccionario_datos.docx`) describe cada tabla, columna, restricción e índice, y el diagrama relacional está en `SGS_diagrama.pdf`.

# Arquitectura del código

## Packages

| Package | Responsabilidad | Procedimientos y funciones públicos |
|---|---|---|
| `SGS_PKG_ERRORES` | Registra en `SGS_BITACORA_ERROR` el error que se está manejando, en una transacción autónoma | `registrar` |
| `SGS_PKG_PARAMETROS` | Lee y cambia los parámetros no cifrados | `obtener`, `obtener_numero`, `actualizar` |
| `SGS_PKG_CIFRADO` | Cifra con AES-256 los parámetros sensibles y calcula el hash de las claves de los usuarios del sistema | `guardar_parametro`, `obtener_parametro`, `hash_clave`, `validar_usuario` |
| `SGS_PKG_CORREO` | Envía correos por SMTP con TLS | `enviar`, `enviar_a_tipo` |
| `SGS_PKG_CLIENTES` | Registro de clientes nacionales (desde el padrón), extranjeros y empresas | `registrar_nacional`, `registrar_extranjero`, `registrar_empresa` |
| `SGS_PKG_CREDITO` | Límite de crédito de un cliente (separado para darle permiso solo a la gerencia) | `asignar_credito` |
| `SGS_PKG_COMPRAS` | Compras a proveedores, abonos y devoluciones | `registrar_compra`, `registrar_pago`, `registrar_devolucion` |
| `SGS_PKG_INVENTARIO` | Selección de lotes por FEFO y traslados entre sucursales | `reservar_fefo`, `trasladar` |
| `SGS_PKG_VENTAS` | Ventas de contado y a crédito, abonos y devoluciones de clientes | `registrar_venta`, `registrar_pago`, `registrar_devolucion` |
| `SGS_PKG_BITACORA` | Arma y guarda el registro de auditoría de cada operación | `iniciar`, `columna`, `desde`, `guardar` |
| `SGS_PKG_PADRON` | Carga el padrón del TSE desde los archivos oficiales | `cargar` |
| `SGS_PKG_PROCESOS` | Procesos programados y notificaciones | `avisar_clientes_limite`, `avisar_coordinador_limite`, `avisar_gerente_proveedores`, `avisar_morosos`, `avisar_vencidos`, `reportar_inventario`, `incluir_descuentos`, `premiar_clientes`, `cerrar_dia` |
| `SGS_PKG_SEGURIDAD` | Cambia la clave de un rol y la guarda cifrada | `asignar_clave_rol` |
| `SGS_PKG_ROLES` | Entrega la clave de un rol solo a quien tiene ese rol | `clave_rol` |
| `SGS_PKG_ACCESO` | Activa el rol en la sesión del usuario (derechos del invocador) | `activar_rol` |
| `SGS_PKG_MONITOREO` | Revisiones de la base y registro diario | `verificar_tablespaces`, `verificar_objetos`, `verificar_indices`, `verificar_bloqueos`, `registrar_estado` |
| `SGS_PKG_STANDBY` | Administración parametrizada del standby | `aplicar_archivo`, `trasladar`, `borrar_archivos` |

## Transacciones

Cada operación de negocio es una sola transacción con su propio punto de guardado:

```
SAVEPOINT sp_registrar_venta;
-- validaciones, bloqueos e inserciones
COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_registrar_venta;
        SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_venta');
        RAISE;
```

Si algo falla a mitad de una venta (por ejemplo, una línea sin existencia), `ROLLBACK TO` deshace todo lo que esa venta había hecho (factura, líneas, movimientos y saldos), sin tocar lo que la sesión tuviera antes. El error queda registrado y se vuelve a lanzar para que quien llamó sepa qué pasó. Usan este patrón los packages de clientes, crédito, compras, inventario, ventas y padrón, y los procesos de descuentos, premiación, cierre y monitoreo.

## Concurrencia

Las filas que dos sesiones podrían cambiar al mismo tiempo se bloquean antes de usarlas:

| Dónde | Bloqueo | Si la fila está ocupada |
|---|---|---|
| Cuenta del cliente o del proveedor al facturar, pagar o devolver | `SELECT … FOR UPDATE WAIT 5` | Espera hasta 5 segundos; si sigue ocupada, error `-20071` / `-20103` (intente de nuevo) |
| Existencias de un lote al vender o trasladar | `FOR UPDATE OF EXI_CANTIDAD WAIT 5` | Error `-20094` |
| Cuenta del cliente al cambiar el límite de crédito | `FOR UPDATE NOWAIT` | Error inmediato `-20045` |
| Un parámetro al cambiarlo | `FOR UPDATE NOWAIT` | Error inmediato `-20013` |

Las operaciones de caja esperan unos segundos porque es normal que dos ventas del mismo cliente coincidan; los cambios administrativos fallan de inmediato para no dejar a nadie esperando.

![Concurrencia: con NOWAIT el rechazo es inmediato; con WAIT 5 la sesión espera y luego se rinde](docs/evidencias/capturas/B3_04_28_concurrencia_bloqueos.png)

## Manejo de errores

Todos los procedimientos manejan sus excepciones. Los errores esperados del negocio se lanzan con `RAISE_APPLICATION_ERROR` y un código propio (anexo A), y todos los errores, esperados o no, se registran con `SGS_PKG_ERRORES.registrar`, que guarda en `SGS_BITACORA_ERROR` el programa, el código, el mensaje, la línea donde ocurrió, el usuario y la fecha. El registro va en una transacción autónoma: queda guardado aunque la operación que falló haga `ROLLBACK`.

```
SELECT BER_FECHA, BER_PROGRAMA, BER_CODIGO, BER_MENSAJE
  FROM SGS_BITACORA_ERROR
 ORDER BY BER_ID DESC;
```

![Rechazos registrados en la bitácora de errores](docs/evidencias/capturas/I0_bitacora_errores.png)

## Triggers

El sistema tiene 50 triggers: 17 de reglas de negocio y 33 de auditoría. Cada trigger de negocio modifica solo tablas distintas a la suya, para no caer en el error de tabla mutante.

| Trigger | Tabla | Qué hace |
|---|---|---|
| `TRG_CLI_CREA_CUENTA` | `SGS_CLIENTE` | Crea la cuenta por cobrar del cliente (límite 0 hasta que se le asigne crédito) |
| `TRG_PRV_CREA_CUENTA` | `SGS_PROVEEDOR` | Crea la cuenta por pagar del proveedor |
| `TRG_CLP_VALIDA` | `SGS_CLIENTE_PERSONA` | Los datos de persona no aplican a empresas; el enlace al padrón solo para nacionales y con la misma cédula |
| `TRG_PRO_HISTORICO_PRECIO` | `SGS_PRODUCTO` | Registra en el historial cada costo nuevo |
| `TRG_MOV_EXISTENCIA` | `SGS_MOVIMIENTO_INVENTARIO` | Las entradas suman a la existencia del lote en la sucursal; las salidas restan si alcanza |
| `TRG_MOV_INMUTABLE` | `SGS_MOVIMIENTO_INVENTARIO` | Impide modificar o borrar un movimiento: un error se corrige con otro movimiento |
| `TRG_FV_VALIDA_CREDITO` | `SGS_FACTURA_VENTA` | Solo un cliente preferencial y activo compra a crédito |
| `TRG_FV_CUENTA_COBRAR` | `SGS_FACTURA_VENTA` | Una factura a crédito pendiente entra al detalle de la cuenta por cobrar |
| `TRG_DCC_SALDO` | `SGS_DETALLE_CUENTA_COBRAR` | Lleva el saldo de la factura al saldo total de la cuenta; saldo en 0: la factura pasa a cancelada |
| `TRG_PFV_ABONO` | `SGS_PAGO_FACTURA_VENTA` | Un abono baja el saldo de la factura a crédito |
| `TRG_NCV_SALDO` | `SGS_NOTA_CREDITO_VENTA` | Una nota de crédito rebaja el saldo pendiente de la factura |
| `TRG_DNCV_VALIDA` | `SGS_DETALLE_NOTA_CREDITO_VENTA` | No se devuelve más de lo vendido ni una línea de otra factura |
| `TRG_FP_CUENTA_PAGAR` | `SGS_FACTURA_PROVEEDOR` | Una factura de proveedor a crédito entra al detalle de la cuenta por pagar |
| `TRG_DCP_SALDO` | `SGS_DETALLE_CUENTA_PAGAR` | Igual que `TRG_DCC_SALDO`, del lado de los proveedores |
| `TRG_PFP_ABONO` | `SGS_PAGO_FACTURA_PROVEEDOR` | Un abono baja el saldo de la factura de proveedor |
| `TRG_NCP_SALDO` | `SGS_NOTA_CREDITO_PROVEEDOR` | Una nota de crédito de proveedor rebaja el saldo pendiente |
| `TRG_DNCP_VALIDA` | `SGS_DETALLE_NOTA_CREDITO_PROVEEDOR` | No se devuelve más de lo comprado ni una línea de otra factura |
| `TRG_AUD_*` (33) | Tablas auditadas | Registran cada cambio en la bitácora (capítulo de bitácoras) |

# Reglas de negocio

## Cuentas por cobrar y por pagar

1. Al crear un cliente o un proveedor, un trigger le crea su cuenta con límite 0.
2. `SGS_PKG_CREDITO.asignar_credito` cambia el límite de un cliente; con límite mayor a 0 el cliente queda como preferencial. El límite nunca puede quedar por debajo de lo que el cliente debe (`-20044`).
3. Una factura a crédito en estado pendiente (`P`) entra al detalle de la cuenta con su monto original y su saldo, y el saldo total de la cuenta sube.
4. Cada abono (`registrar_pago`) y cada nota de crédito bajan el saldo de la factura y el de la cuenta.
5. Cuando el saldo de una factura llega a 0, la factura pasa sola de pendiente (`P`) a cancelada (`C`).

**Límite de crédito.** La cuenta tiene un `CHECK` que impide que el saldo total supere el límite. Si una factura a crédito lo superaría, la factura completa se rechaza (`-20061` para clientes, `-20063` para proveedores) y no queda guardada como pendiente. Solo los clientes preferenciales y activos compran a crédito (`-20060`).

![Factura a crédito cancelada al llegar su saldo a 0](docs/evidencias/capturas/B3_04_07_factura_cancelada.png)

## Inventario

- **Compras.** `registrar_compra` registra la factura del proveedor, crea un lote por cada línea (con su vencimiento) y la entrada a la bodega central. Si el costo de la compra es distinto al del producto, actualiza el costo y queda en el historial.
- **Traslados.** `SGS_PKG_INVENTARIO.trasladar` mueve productos de la bodega central a una sucursal (o entre sucursales), lote por lote, eligiendo los lotes por FEFO.
- **Ventas por FEFO** (primero el que vence primero). En la sucursal donde se vende se toman primero los lotes que vencen antes y, si no vencen, los que entraron primero. Si la existencia no alcanza, la venta completa se rechaza. La bodega central no vende (`-20100`).
- **Devoluciones.** La mercadería devuelta regresa al lote del que salió. No se puede devolver más de lo vendido o comprado, sumando todas las notas de crédito de la factura (`-20110`, `-20080`).
- **Movimientos.** Cada entrada y salida queda en `SGS_MOVIMIENTO_INVENTARIO` y la existencia la mantiene el trigger. Los movimientos no se modifican ni se borran (`-20051`): son la historia del inventario.

![Venta por FEFO: el lote que vence primero sale primero](docs/evidencias/capturas/B3_04_23_traslado_fefo.png)

## Historial de precios

El trigger `TRG_PRO_HISTORICO_PRECIO` registra en `SGS_HISTORICO_PRECIO` el costo anterior y el nuevo cada vez que cambia el costo de un producto, ya sea por una compra con otro costo o por un cambio directo. Si el costo no cambia, no se registra nada.

## Promociones y acciones

Cada promoción define cuántos productos patrocinadores se necesitan para una acción y cuántas acciones se otorgan (`PRM_CANTIDAD_REQUERIDA` y `PRM_CANTIDAD_ACCIONES`). Al registrar una venta, `registrar_venta` suma los productos patrocinadores de cada promoción vigente y guarda en `SGS_ACCION_OTORGADA` las acciones que le corresponden a esa factura.

## Descuentos

Un descuento se define por familia, por proveedor, por días desde el ingreso o por días para vencer. El precio de venta de cada producto en cada sucursal se calcula en la vista `SGS_VW_PRECIO_VENTA` (costo, utilidad, descuento e impuesto). Los descuentos por ingreso y por vencimiento se completan cada semana con el proceso `incluir_descuentos`, que agrega al detalle los productos que ahora cumplen la condición.

## Padrón nacional

`SGS_PKG_PADRON.cargar` lee los archivos del TSE con dos tablas externas (`SGS_EXT_DISTELEC` y `SGS_EXT_PADRON`) y los pasa a `SGS_DISTRITO_ELECTORAL` y `SGS_PADRON` con `MERGE`: inserta lo nuevo, actualiza solo lo que cambió y **nunca borra**, para no perder personas enlazadas a clientes. Devuelve cuántos distritos y personas cambiaron y cuántas líneas se rechazaron. Volver a cargar el mismo archivo no cambia nada.

`SGS_PKG_CLIENTES.registrar_nacional` busca a la persona por cédula (índice único, costo 3 en el plan de ejecución) y toma su nombre y apellidos; si la cédula no está en el padrón, el registro se rechaza (`-20043`).

![Carga del padrón](docs/evidencias/capturas/B5_06_04_carga.png)

# Bitácoras y auditoría

## Qué se registra

Las 7 áreas que pide el enunciado se auditan con 33 triggers `TRG_AUD_*`, uno por tabla:

| Área | Tablas |
|---|---|
| Facturación | Facturas de venta y de proveedor, sus detalles, pagos, notas de crédito y sus detalles |
| Precios | Producto, producto por sucursal, artículo facturable y servicio |
| Inventario | Movimientos, existencias, lotes, traslados y su detalle |
| Clientes | Cliente, cliente persona y cuenta por cobrar |
| Proveedores | Proveedor y cuenta por pagar |
| Promociones | Promoción, sus productos, premios, premios por promoción y acciones otorgadas |
| Descuentos | Descuento y sus enlaces a familia, proveedor y producto |

Cada operación deja un encabezado en `SGS_BITACORA` (área, tabla, operación, registro, usuario de la base, usuario del sistema operativo, equipo, fecha y si es crítica) y una fila en `SGS_BITACORA_DETALLE` por cada columna que cambió, con el valor anterior y el nuevo. En una inserción quedan los valores nuevos, en un borrado los anteriores, y una actualización que no cambia nada no deja rastro.

El registro va en la misma transacción que la operación: si la operación se deshace, su rastro también. Si la auditoría falla, el trigger registra el error y la operación sigue.

## Operaciones críticas

`BIT_ES_CRITICA = 'S'` marca lo que la gerencia debe revisar:

- Todo borrado.
- Facturación: anular o modificar una factura o línea existente, todo pago y toda nota de crédito.
- Precios: utilidad, descuento máximo, impuesto, precio de servicio, y el costo cuando **no** lo cambia una compra.
- Inventario: una existencia cambiada sin pasar por los movimientos (un ajuste a mano) y cualquier cambio a un lote o traslado ya registrado.
- Clientes: cédula, estado, preferencial y límite de crédito (el saldo no, porque lo mueven ventas y pagos).
- Proveedores: cédula jurídica, estado y límite.
- Promociones y descuentos: criterios, fechas, cantidades, porcentajes, estado y sus enlaces.

Para distinguir un cambio hecho por el sistema de uno hecho a mano, el trigger revisa con `SGS_PKG_BITACORA.desde` si en la pila de llamadas (`DBMS_UTILITY.FORMAT_CALL_STACK`) está el programa que normalmente hace ese cambio: el costo que cambia `SGS_PKG_COMPRAS` o la existencia que cambia `TRG_MOV_EXISTENCIA` no son críticos; el mismo cambio hecho directamente sí.

![Operaciones normales y críticas en la bitácora](docs/evidencias/capturas/I4_01_bitacora_21c.png)

## Consulta

```
-- Todo, con el detalle de cada columna
SELECT * FROM SGS_VW_BITACORA ORDER BY BIT_ID DESC;
-- Solo lo crítico (el rol Gerente la puede consultar)
SELECT * FROM SGS_VW_BITACORA_CRITICA ORDER BY BIT_ID DESC;
```

# Notificaciones y correo

## Cómo se envía

`SGS_PKG_CORREO` envía por SMTP con TLS a `smtp.gmail.com`. Lee de `SGS_PARAMETRO` el servidor, el puerto (`465`), el wallet con los certificados y el remitente, y descifra la contraseña de aplicación (`CORREO_CLAVE`) solo en el momento de usarla. La lista de control de red de la base autoriza a `SGS_ADMIN` a conectarse únicamente a ese servidor. `enviar_a_tipo` manda un correo a todos los destinatarios activos de un tipo (`GERENTE`, `COORDINADOR` o `DBA`) de la tabla `SGS_DESTINATARIO`.

## Cifrado

`SGS_PKG_CIFRADO` usa `DBMS_CRYPTO` con AES-256 en modo CBC y un vector inicial aleatorio por valor, así que el mismo dato cifrado dos veces da textos distintos. El cuerpo del package se instaló ofuscado (`DBMS_DDL.CREATE_WRAPPED`) para que la llave no se pueda leer en el código guardado en la base. Las claves de los usuarios del sistema (`SGS_USUARIO`) no se cifran sino que se guardan como hash SHA-256 de una sal más la clave (`hash_clave`), y se comprueban con `validar_usuario`.

## Notificaciones del sistema

| Notificación | Procedimiento | Destinatario | Cuándo |
|---|---|---|---|
| Cliente al 85 % de su límite | `avisar_clientes_limite` | Cada cliente | Diario, 07:00 |
| Lista de clientes al 85 % | `avisar_coordinador_limite` | Coordinador (un solo correo) | Diario, 07:00 |
| Proveedores al 70 % de su límite | `avisar_gerente_proveedores` | Gerente (un solo correo, con el estado de todos los proveedores con crédito) | Diario, 07:00 |
| Clientes morosos | `avisar_morosos` | Gerente y coordinador | Diario, 07:00 |
| Productos vencidos con su total | `avisar_vencidos` | Coordinador | Diario, 07:00 |
| Por vencer y con más de 6 meses | `reportar_inventario` | Coordinador | Lunes, 07:00 |
| Clientes premiados | `premiar_clientes` | Coordinador | Cada 6 meses |
| Cierre diario | `cerrar_dia` | Gerente y coordinador | Diario, 00:05 |
| Problemas de la base | `SGS_PKG_MONITOREO` | DBA | Según la revisión |

Si un proceso no encuentra casos, no envía correo (salvo el cierre diario, que se envía aunque no haya ventas). Mientras un caso siga, el aviso se repite cada día como recordatorio. Un cliente es moroso si tiene saldo y pasaron más de `DIAS_MOROSIDAD` días desde su último abono a una factura a crédito (o, si nunca abonó, desde su factura pendiente más vieja).

![Correo del cierre diario](docs/evidencias/capturas/B6_07_15_correo_cierre.png)

# Procesos programados

Todos los procesos automáticos son jobs de `DBMS_SCHEDULER` del usuario `SGS_ADMIN`. Su fecha de inicio está en `America/Costa_Rica`, así el scheduler calcula las horas en Costa Rica aunque el servidor esté en otra zona. Corren en la base principal; después de un cambio de roles corren en la nueva principal sin recrearlos.

| Job | Procedimiento | Programación |
|---|---|---|
| `SGS_JOB_AVISO_CLIENTES` | `SGS_PKG_PROCESOS.avisar_clientes_limite` | Diario, 07:00 |
| `SGS_JOB_AVISO_COORDINADOR` | `SGS_PKG_PROCESOS.avisar_coordinador_limite` | Diario, 07:00 |
| `SGS_JOB_AVISO_GERENTE_CXP` | `SGS_PKG_PROCESOS.avisar_gerente_proveedores` | Diario, 07:00 |
| `SGS_JOB_AVISO_MOROSOS` | `SGS_PKG_PROCESOS.avisar_morosos` | Diario, 07:00 |
| `SGS_JOB_AVISO_VENCIDOS` | `SGS_PKG_PROCESOS.avisar_vencidos` | Diario, 07:00 |
| `SGS_JOB_REPORTE_INVENTARIO` | `SGS_PKG_PROCESOS.reportar_inventario` | Lunes, 07:00 |
| `SGS_JOB_DESCUENTOS` | `SGS_PKG_PROCESOS.incluir_descuentos` | Lunes, 06:00 |
| `SGS_JOB_PREMIACION` | `SGS_PKG_PROCESOS.premiar_clientes` | Cada `PREMIO_FRECUENCIA_MESES` meses, el día 1 a las 08:00 |
| `SGS_JOB_CIERRE_DIARIO` | `SGS_PKG_PROCESOS.cerrar_dia` | Diario, 00:05 (cierra el día anterior) |
| `SGS_JOB_REVISION_TABLESPACES` | `SGS_PKG_MONITOREO.verificar_tablespaces` | Diario, 06:00 |
| `SGS_JOB_REVISION_OBJETOS` | `SGS_PKG_MONITOREO.verificar_objetos` | Diario, 06:05 |
| `SGS_JOB_REVISION_INDICES` | `SGS_PKG_MONITOREO.verificar_indices` | Diario, 06:10 |
| `SGS_JOB_REVISION_BLOQUEOS` | `SGS_PKG_MONITOREO.verificar_bloqueos` | Cada 15 minutos |
| `SGS_JOB_REGISTRO_MONITOREO` | `SGS_PKG_MONITOREO.registrar_estado` | Diario, 23:55 |
| `SGS_JOB_REFRESCO_VISTAS` | Refresco de las dos vistas materializadas | Diario, 00:30 |
| `SGS_JOB_STB_ARCHIVO` | `SGS_PKG_STANDBY.aplicar_archivo` | Diario, 00:10 |
| `SGS_JOB_STB_TRASLADO` | `SGS_PKG_STANDBY.trasladar` | Cada `STB_MINUTOS_TRASLADO` minutos |
| `SGS_JOB_STB_BORRADO` | `SGS_PKG_STANDBY.borrar_archivos` | Diario, 00:20 |
| `SGS_JOB_RESPALDO_DIARIO` | Script `respaldo_rman.sh` | Diario, a la hora de `RESP_HORA_DIARIO` |

## Procesos de negocio

- **Cierre diario.** Cierra el día anterior: facturas no anuladas y monto vendido, devoluciones y monto devuelto, total (vendido menos devuelto) y el detalle por cajero. Si el cierre de esa fecha ya existe, se recalcula y reemplaza. Se guarda antes de enviar el correo, para no perderlo si el correo falla. Se puede cerrar otro día a demanda: `SGS_PKG_PROCESOS.cerrar_dia(DATE '2026-10-28')`.
- **Premiación.** Toma las compras netas (facturas no anuladas menos sus notas de crédito) de los últimos `PREMIO_FRECUENCIA_MESES` meses, sin el cliente por defecto, y da a los `PREMIO_CANTIDAD_CLIENTES` mejores una orden de compra de `PREMIO_MONTO_ORDEN`. Acepta una fecha de corte para premiar otro período.
- **Descuentos planeados.** Para cada descuento activo de criterio `INGRESO` o `VENCIMIENTO`, agrega al detalle los productos con existencia que cumplen los días. Solo agrega (el detalle queda como historial) y no incluye lotes vencidos.
- **Inventario semanal.** Un correo con dos secciones: lotes que vencen en los próximos `DIAS_PROXIMO_VENCER` días y lotes con más de `MESES_ANTIGUEDAD_BODEGA` meses en inventario, en cualquier sucursal.

## Operación de los jobs

```
-- Estado y próxima ejecución
SELECT job_name, state, TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI TZR') AS proxima, run_count, failure_count
  FROM user_scheduler_jobs ORDER BY next_run_date;
-- Historial y errores
SELECT job_name, status, actual_start_date, error#, additional_info
  FROM user_scheduler_job_run_details ORDER BY log_id DESC;
-- Ejecutar a demanda, como lo haría el scheduler
EXEC DBMS_SCHEDULER.RUN_JOB('SGS_JOB_CIERRE_DIARIO', use_current_session => FALSE);
-- Pausar y reanudar
EXEC DBMS_SCHEDULER.DISABLE('SGS_JOB_AVISO_CLIENTES');
EXEC DBMS_SCHEDULER.ENABLE('SGS_JOB_AVISO_CLIENTES');
```

Si la base estuvo apagada a la hora de un job, el scheduler lo ejecuta una sola vez al volver a abrirla y después sigue con su horario.

![Jobs a demanda en SUCCEEDED](docs/evidencias/capturas/I4_05_avisos_a_demanda.png)

# Seguridad

## Perfil de contraseñas

Los usuarios del negocio tienen el perfil `SGS_PERFIL_USUARIO`:

| Límite | Valor |
|---|---|
| Intentos fallidos antes de bloquear | 3 |
| Tiempo de bloqueo automático | 30 minutos |
| Vigencia de la contraseña | 60 días, con 7 días de gracia |
| Reutilización | No se puede repetir ninguna de las últimas 5 ni las de los últimos 365 días |
| Sesiones simultáneas | 2 |
| Tiempo máximo inactivo | 15 minutos |

![Bloqueo automático después de tres intentos fallidos](docs/evidencias/capturas/B7_08_09_bloqueo.png)

## Usuarios y roles

Hay un usuario de Oracle por rol: `SGS_GERENTE`, `SGS_JEFE_DEPTO`, `SGS_JEFE_PROVEEDURIA` y `SGS_DIGITADOR`. Cada uno tiene su rol `SGS_ROL_*`, protegido con clave. Los usuarios se crean con `DEFAULT ROLE NONE`: al conectarse no tienen ningún permiso hasta que activan su rol.

| Rol | Puede |
|---|---|
| `SGS_ROL_DIGITADOR` | Ventas, pagos y devoluciones de clientes, registro de clientes y consultas de venta |
| `SGS_ROL_JEFE_DEPTO` | Lo del digitador, más promociones, descuentos, utilidad y descuento máximo por sucursal |
| `SGS_ROL_JEFE_PROVEEDURIA` | Compras, devoluciones y pagos a proveedores, traslados, proveedores y productos |
| `SGS_ROL_GERENTE` | Consultar todo (incluidas las operaciones críticas), asignar crédito, cambiar parámetros y ejecutar procesos a demanda |

Ningún rol tiene `DELETE`. No se usan los roles `DBA`, `CONNECT` ni `RESOURCE`.

## Privilegios de sistema y de objeto

- **De sistema** (permiten hacer algo en la base): cada usuario por rol tiene solo `CREATE SESSION`. `SGS_ADMIN` tiene los 11 que necesita para crear y mantener sus objetos (`CREATE TABLE`, `CREATE SEQUENCE`, `CREATE VIEW`, `CREATE MATERIALIZED VIEW`, `CREATE PROCEDURE`, `CREATE TRIGGER`, `CREATE JOB`, `CREATE EXTERNAL JOB`, `CREATE CREDENTIAL`, `CREATE ROLE` y `CREATE SESSION`).
- **De objeto** (permiten usar un objeto concreto): todo lo demás. Cada rol recibe `EXECUTE` sobre los packages de su función y `SELECT`, `INSERT` o `UPDATE` (a veces sobre columnas concretas) en las tablas que usa. Los usuarios reciben directamente solo `EXECUTE` sobre los packages que necesitan para activar su rol.

## Activación del rol

La clave de cada rol se guarda cifrada en `SGS_PARAMETRO` (`CLAVE_ROL_*`). El usuario activa su rol sin conocer la clave:

```
EXEC SGS_ADMIN.SGS_PKG_ACCESO.activar_rol('SGS_ROL_DIGITADOR');
SELECT role FROM session_roles;     -- SGS_ROL_DIGITADOR
```

`activar_rol` tiene derechos del invocador (Oracle no permite `SET ROLE` dentro de un procedimiento con derechos del dueño) y pide la clave a `SGS_PKG_ROLES.clave_rol`, que tiene derechos del dueño para leer el parámetro cifrado y solo la entrega si el usuario tiene ese rol otorgado (`-20132` si no). Con la clave, activa el rol con `DBMS_SESSION.SET_ROLE`.

![Permisos del digitador antes y después de activar su rol](docs/evidencias/capturas/I4_02_rol_digitador_21c.png)

# Monitoreo y rendimiento

## Revisiones

| Revisión | Qué revisa | Aviso al DBA |
|---|---|---|
| Tablespaces (06:00) | Uso de `SGS_DATA`, `SGS_IDX` y `SGS_AUD` contra su tamaño máximo | Si alguno supera `PCT_MAX_TABLESPACE` (85 %) |
| Objetos (06:05) | Objetos inválidos del esquema (en las vistas materializadas, solo errores de compilación) | Si hay alguno |
| Índices (06:10) | Índices y particiones `UNUSABLE` | Si hay alguno |
| Bloqueos (cada 15 min) | Sesiones bloqueadas por otra por más de `MINUTOS_SESION_BLOQUEADA` minutos | Si hay alguna, con la sesión que bloquea |
| Registro diario (23:55) | Tamaño de la base, sesiones totales y activas, inválidos, índices dañados, errores del día y uso de cada tablespace | Siempre, con el crecimiento y los programas con más errores |

El registro diario queda en `SGS_MONITOREO` y `SGS_MONITOREO_TABLESPACE`, y la vista `SGS_VW_CRECIMIENTO` muestra cuánto creció la base entre cada revisión.

![Reporte diario del monitoreo](docs/evidencias/capturas/B8_09_03_correo_reporte.png)

## Vistas materializadas

| Vista | Contenido |
|---|---|
| `SGS_MV_VENTAS_MENSUALES` | Por mes y sucursal: facturas, vendido, devuelto y neto |
| `SGS_MV_INVENTARIO_CONSOLIDADO` | Por producto y sucursal: existencia, valor al costo, lotes y primer vencimiento |

Se refrescan completas cada día a las 00:30, después del cierre. Entre un refresco y otro, si sus tablas cambian, aparecen como `INVALID` en `USER_OBJECTS`: solo significa que están desactualizadas. Un error real se ve en `USER_MVIEWS.COMPILE_STATE = 'COMPILATION_ERROR'`.

## Planes de ejecución

Con las estadísticas del esquema al día (`DBMS_STATS.GATHER_SCHEMA_STATS`), se analizaron con `EXPLAIN PLAN` las consultas de los requerimientos funcionales:

| Consulta | Costo | Índices usados |
|---|---|---|
| Precio de venta de un producto en una sucursal | 11 | Llaves primarias e índices de las llaves foráneas; ningún recorrido completo |
| Persona del padrón por cédula | 3 | `UK_PAD_CEDULA` |
| Persona del padrón por nombre y apellido (comparación) | 8 453 | Ninguno: recorre las 3,7 millones de filas |
| Lotes por vencer o con más de 6 meses | 6 | `PK_LOTE` |
| Clientes morosos | 12 | `IDX_FV_CLIENTE`, `IDX_PFV_FACTURA` |
| Ventas de un día por cajero (cierre) | 2 | `IDX_FV_USUARIO` |
| Mejores clientes de los últimos 6 meses | 6 | `IDX_FV_FECHA`, `PK_CLIENTE` |

La conclusión principal es que el padrón se busca siempre por cédula: por nombre la misma búsqueda es unas 2 800 veces más cara. Los recorridos completos que aparecen (cuentas por cobrar en morosos, existencias en lotes) son correctos, porque la consulta necesita revisar todas esas filas y las tablas son pequeñas. El análisis completo está en `docs/optimizacion.md`.

![Resumen de los planes de ejecución](docs/evidencias/capturas/B8_09_11_explain_resumen.png)

# Tareas de mantenimiento

Salvo que se indique otra cosa, se ejecutan conectado como `SGS_ADMIN` a la base principal.

## Parámetros

```
-- Ver todos
SELECT par_codigo, par_valor, par_es_cifrado FROM SGS_PARAMETRO ORDER BY par_codigo;
-- Cambiar uno (los porcentajes como fracción)
EXEC SGS_PKG_PARAMETROS.actualizar('DIAS_MOROSIDAD', '45');
```

Los procesos leen sus parámetros cada vez que corren, así que el cambio vale desde la siguiente ejecución. Dos parámetros definen la programación de un job y requieren reprogramarlo después de cambiarlos: `PREMIO_FRECUENCIA_MESES` (volver a ejecutar la sección 3 de `07_procesos.sql`, que recrea los jobs) y `RESP_HORA_DIARIO` (volver a ejecutar la sección 3 de `11_standby.sql`). `STB_MINUTOS_TRASLADO` no lo necesita: su job se reprograma solo.

## Destinatarios y correo

```
-- Agregar un destinatario
INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
VALUES (SEQ_DESTINATARIO.NEXTVAL, 'DBA', 'Profesor', '<correo>');
-- Dejar de enviar a uno
UPDATE SGS_DESTINATARIO SET DES_ESTADO = 'I' WHERE DES_EMAIL = '<correo>';
COMMIT;
-- Cambiar la contraseña de aplicación de Gmail (queda cifrada)
EXEC SGS_PKG_CIFRADO.guardar_parametro('CORREO_CLAVE', '<nueva contraseña>', 'Contrasena de aplicacion de la cuenta de correo (cifrada)');
```

## Usuarios y roles

```
-- Cambiar la clave de un rol (queda cifrada en SGS_PARAMETRO)
EXEC SGS_PKG_SEGURIDAD.asignar_clave_rol('SGS_ROL_GERENTE', '<nueva clave>');
```

Como `SYS` o `SYSTEM` en la PDB:

```
-- Desbloquear una cuenta bloqueada por intentos fallidos
ALTER USER SGS_DIGITADOR ACCOUNT UNLOCK;
-- Cambiar la contraseña de un usuario
ALTER USER SGS_DIGITADOR IDENTIFIED BY "<nueva clave>";
```

## Padrón

Para cargar una versión nueva del padrón, se reemplazan `PADRON_COMPLETO.txt` y `distelec.txt` en `/opt/oracle/oradata/padron` de **las dos** VMs y se ejecuta la carga:

```
SET SERVEROUTPUT ON
DECLARE
    v_distritos  NUMBER;
    v_personas   NUMBER;
    v_rechazadas NUMBER;
BEGIN
    SGS_PKG_PADRON.cargar(v_distritos, v_personas, v_rechazadas);
    DBMS_OUTPUT.PUT_LINE('Distritos: ' || v_distritos || ' | Personas: ' || v_personas || ' | Rechazadas: ' || v_rechazadas);
END;
/
```

La carga genera bastante redo, que viaja a la standby. Conviene revisar después en el broker que la standby quede al día.

## Vistas materializadas, estadísticas y objetos

```
-- Refrescar las vistas materializadas fuera de su horario
EXEC DBMS_MVIEW.REFRESH('SGS_MV_VENTAS_MENSUALES,SGS_MV_INVENTARIO_CONSOLIDADO', 'CC');
-- Actualizar las estadísticas del esquema
EXEC DBMS_STATS.GATHER_SCHEMA_STATS('SGS_ADMIN');
-- Objetos con errores de compilación
SELECT name, type, line, text FROM user_errors ORDER BY name, sequence;
```

## Revisión diaria sugerida

1. Revisar el correo del reporte diario del monitoreo y los avisos al DBA.
2. Revisar los jobs con fallos (`failure_count > 0`) y su detalle en `USER_SCHEDULER_JOB_RUN_DETAILS`.
3. Revisar los errores del día en `SGS_BITACORA_ERROR`.
4. Revisar las operaciones críticas en `SGS_VW_BITACORA_CRITICA`.
5. Revisar la standby en el broker (`SHOW CONFIGURATION;`).

# Solución de problemas

| Síntoma | Causa | Solución |
|---|---|---|
| Un usuario por rol recibe `ORA-00942` o `PLS-00201` al usar un objeto del sistema | No activó su rol: sin el rol no ve los objetos | `SGS_ADMIN.SGS_PKG_ACCESO.activar_rol('<rol>')` |
| `ORA-01031: insufficient privileges` con el rol activo | La acción no está permitida para ese rol | Es el comportamiento esperado; la acción la hace el rol que corresponde |
| `ORA-28000: the account is locked` | Tres intentos fallidos de contraseña | Esperar 30 minutos o `ALTER USER … ACCOUNT UNLOCK` |
| No llega un correo y `SGS_BITACORA_ERROR` muestra `-20030` | Puerto, wallet o contraseña de aplicación | Probar el puerto desde el servidor, revisar el wallet (`orapki wallet display`) y la clave; `CORREO_PUERTO` admite 465 y 587 |
| Error `-20031` o `-20121` | No hay destinatarios activos de ese tipo | Agregar o activar un destinatario en `SGS_DESTINATARIO` |
| Las tildes o eñes de los correos salen dañadas después de reinstalar un package | El script se ejecutó con SQL*Plus sin `NLS_LANG` en UTF-8 | `export NLS_LANG=AMERICAN_AMERICA.AL32UTF8` y volver a ejecutar el script |
| Una vista materializada aparece `INVALID` | Sus tablas cambiaron después del último refresco | Ninguna; se refresca sola a las 00:30, o a mano con `DBMS_MVIEW.REFRESH` |
| Un job aparece con fallos | El procedimiento lanzó un error | Ver `additional_info` en `USER_SCHEDULER_JOB_RUN_DETAILS` y `SGS_BITACORA_ERROR`; corregir y ejecutarlo a demanda |
| Los jobs corren a destiempo o las fechas salen corridas | El reloj de la VM se atrasó (por ejemplo, al suspender la HP con las VMs encendidas) | `chronyc makestep` como `root` y `makestep 1 -1` en `/etc/chrony.conf` |
| Una venta o pago responde "la está usando otra sesión" | Otra sesión tiene bloqueada la cuenta o la existencia | Repetir la operación; si persiste, revisar las sesiones bloqueadas (aviso del monitoreo) |

# Anexos

## A. Errores propios del sistema

| Código | Package o script | Significado |
|---|---|---|
| `-20001` | Varios scripts | La sesión no es la esperada (está en `CDB$ROOT` o no es el usuario indicado) |
| `-20010` | `SGS_PKG_PARAMETROS` | No existe el parámetro |
| `-20011` | `SGS_PKG_PARAMETROS` | El parámetro no es numérico |
| `-20012` | `SGS_PKG_PARAMETROS` | El parámetro es cifrado: se cambia con `SGS_PKG_CIFRADO` |
| `-20013` | `SGS_PKG_PARAMETROS` | Otra sesión está modificando el parámetro |
| `-20020` | `SGS_PKG_CIFRADO` | No existe el parámetro cifrado |
| `-20021` | `SGS_PKG_CIFRADO` | El parámetro existe sin cifrar |
| `-20022` | `SGS_PKG_CIFRADO` | No se pudo descifrar el parámetro |
| `-20030` | `SGS_PKG_CORREO` | No se pudo enviar el correo |
| `-20031` | `SGS_PKG_CORREO` | No hay destinatarios activos del tipo |
| `-20040` | `SGS_PKG_CLIENTES` | Un cliente empresa no lleva datos de persona |
| `-20041` | `SGS_PKG_CLIENTES` | Solo un cliente nacional se enlaza al padrón |
| `-20042` | `SGS_PKG_CLIENTES` | La cédula del cliente no coincide con la de la persona del padrón |
| `-20043` | `SGS_PKG_CLIENTES` | La cédula no está en el padrón |
| `-20044` | `SGS_PKG_CREDITO` | El límite no puede ser menor a lo que el cliente debe |
| `-20045` | `SGS_PKG_CREDITO` | Otra sesión está usando la cuenta del cliente |
| `-20046` | `SGS_PKG_CLIENTES` | No existe el país |
| `-20050` | Trigger de existencias | Existencia insuficiente del lote |
| `-20051` | Trigger de movimientos | Los movimientos de inventario no se modifican ni se borran |
| `-20060` | Trigger de facturas | El cliente no puede comprar a crédito: debe ser preferencial y estar activo |
| `-20061` | Trigger de cuentas | La factura supera el límite de crédito del cliente |
| `-20062` | Trigger de pagos | El pago supera el saldo pendiente de la factura |
| `-20063` | Trigger de cuentas | La factura supera el límite de crédito con el proveedor |
| `-20064` | Trigger de pagos | El pago supera el saldo pendiente con el proveedor |
| `-20070` | `SGS_PKG_COMPRAS` | El producto no es de este proveedor |
| `-20071` | `SGS_PKG_COMPRAS` | Otra sesión está usando la cuenta del proveedor |
| `-20072` | `SGS_PKG_COMPRAS` | No existe o no está activo el usuario |
| `-20073` | `SGS_PKG_COMPRAS` | No existe el tipo de pago |
| `-20074` | `SGS_PKG_COMPRAS` | La compra no tiene líneas |
| `-20075` | `SGS_PKG_COMPRAS` | No existe o no está activo el proveedor |
| `-20076` | `SGS_PKG_COMPRAS` | No existe el producto |
| `-20077` | `SGS_PKG_COMPRAS` | No existe la factura de proveedor |
| `-20078` | `SGS_PKG_COMPRAS` | La factura no tiene saldo pendiente |
| `-20079` | `SGS_PKG_COMPRAS` | El producto no está en la factura |
| `-20080` | Trigger de devoluciones | No se puede devolver más de lo comprado |
| `-20081` | Trigger de devoluciones | La línea devuelta no pertenece a la factura de la nota de crédito |
| `-20090` | `SGS_PKG_INVENTARIO` | Existencia insuficiente del producto en la sucursal |
| `-20091` | `SGS_PKG_INVENTARIO` | No existe la sucursal |
| `-20092` | `SGS_PKG_INVENTARIO` | No existe el producto |
| `-20093` | `SGS_PKG_INVENTARIO` | El traslado no tiene líneas |
| `-20094` | `SGS_PKG_INVENTARIO` | Otra sesión está usando las existencias |
| `-20095` | `SGS_PKG_INVENTARIO` | No existe o no está activo el usuario |
| `-20100` | `SGS_PKG_VENTAS` | La bodega central no vende |
| `-20101` | `SGS_PKG_VENTAS` | No existe el cliente |
| `-20102` | `SGS_PKG_VENTAS` | El artículo no existe, no está activo o no se vende en la sucursal |
| `-20103` | `SGS_PKG_VENTAS` | Otra sesión está usando la cuenta del cliente |
| `-20104` | `SGS_PKG_VENTAS` | Los pagos no suman el total de la factura |
| `-20105` | `SGS_PKG_VENTAS` | La venta no tiene líneas |
| `-20106` | `SGS_PKG_VENTAS` | No existe la sucursal |
| `-20107` | `SGS_PKG_VENTAS` | No existe la factura de venta |
| `-20108` | `SGS_PKG_VENTAS` | La factura no tiene saldo pendiente |
| `-20109` | `SGS_PKG_VENTAS` | El artículo no está en la factura |
| `-20110` | Trigger de devoluciones | No se puede devolver más de lo vendido |
| `-20111` | Trigger de devoluciones | La línea devuelta no pertenece a la factura de la nota de crédito |
| `-20112` | `SGS_PKG_VENTAS` | No existe o no está activo el usuario |
| `-20113` | `SGS_PKG_VENTAS` | No existe el tipo de pago |
| `-20114` | `SGS_PKG_VENTAS` | Una venta a crédito no lleva pagos: se abona después con `registrar_pago` |
| `-20120` | `SGS_PKG_PROCESOS` | Uno o más correos no se pudieron enviar |
| `-20121` | `SGS_PKG_PROCESOS` | No hay destinatarios activos de los tipos indicados |
| `-20130` | `SGS_PKG_SEGURIDAD` | Rol desconocido |
| `-20131` | `SGS_PKG_SEGURIDAD` | La clave del rol debe tener de 8 a 30 letras o números |
| `-20132` | `SGS_PKG_ROLES` | El usuario no tiene ese rol |

## B. Parámetros del sistema

Los valores iniciales de todos los parámetros están en el anexo B del manual de instalación y despliegue. Los que usa cada proceso se indican en su sección de este manual.
