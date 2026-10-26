# Análisis de los esquemas del Entregable #1

Base para el modelo del Entregable #2: se parte del esquema de Isaac (`IALVARADO`, nota 95), se toma de Andrés (`CADENA_NEGOCIOS`, nota 91) lo que aporta y se agrega lo que pide el E2. Revisado el 2026-10-25 sobre `entregable_1/isaac/SGS_IsaacAlvarado.sql` y `entregable_1/andres/Script/02_CONSTRUCCION_COMPLETA.sql`.

## 1. Esquema de Isaac (34 tablas)

### Se mantiene
- Supertipo `SGS_ARTICULO_FACTURABLE` con subtipos `SGS_PRODUCTO` y `SGS_SERVICIO`: el detalle de factura apunta a una sola FK.
- `SGS_CLIENTE` con subtipo 1:1 `SGS_CLIENTE_PERSONA` (persona vs. empresa).
- Índices únicos funcionales: una sola sucursal central (`UX_SUC_UNICA_CENTRAL`) y un solo tipo de negocio activo (`UX_TNE_UNICO_ACTIVO`).
- Ruta de datafiles detectada desde el datafile SYSTEM; índices en `SGS_IDX`.
- Cantidad requerida y acciones en `SGS_PROMOCION`, donde el E2 la ubica ("se define en la misma tabla de promociones").
- `SGS_HISTORICO_PRECIO` sobre precio de costo, que es lo que pide el E2.
- Notas de crédito ligadas a la línea del detalle de factura (devolución parcial).
- Pago inmediato y abono parcial con el mismo mecanismo (`SGS_PAGO_FACTURA_VENTA` / `SGS_PAGO_FACTURA_PROVEEDOR`).

### Se corrige
| Problema | Dónde | Corrección |
|---|---|---|
| CLOB | `SGS_BITACORA.BIT_DETALLE` | `VARCHAR2(250)` (corrección del profesor) |
| Estados en texto largo | `USU_ESTADO`, `CLI_ESTADO` (`VARCHAR2(50)`, `'ACTIVO'`) | `VARCHAR2(1)` con CHECK |
| Dominios cortos en texto largo | `CLP_SEXO`, `CLP_ESTADO_CIVIL` | `VARCHAR2(1)` con CHECK |
| Nacionalidad y residencia en texto libre | `CLI_NACIONALIDAD`, `CLI_RESIDENCIA` | FK a tabla de países |
| Catálogos sin estado | proveedor, producto, familia, tipo de pago, promoción, descuento | Estado `'A'/'I'` |
| Montos cortos | `NUMBER(10,2)` (tope ≈ ₡99,9 millones) | `NUMBER(14,2)` |
| Factura de proveedor incompleta | `SGS_FACTURA_PROVEEDOR` solo tiene total | Número de factura (único por proveedor), subtotal, descuento, impuesto, condición y estado |
| Pago a proveedor sin medio de pago | `SGS_PAGO_FACTURA_PROVEEDOR` | FK a `SGS_TIPO_PAGO` |
| Existencia y lote mezclados | `SGS_EXISTENCIA` | Lote separado de la existencia |
| Traslado por producto | `SGS_TRASLADO_INVENTARIO` | Traslado por lote |
| Esquema y PDB fijos | `IALVARADO.` y `ALTER SESSION SET CONTAINER = FREEPDB1` | Objetos de `SGS_ADMIN`, sin PDB fija |

## 2. Esquema de Andrés (41 tablas)

Correcciones generales del profesor visibles en el script: `CHAR(1)` en todos los indicadores, nombres sin prefijo ni estándar, rutas de datafiles fijas y clave escrita en el script.

### Se integra (traducido a la convención SGS)
| Pieza | Origen | Uso en el SGS |
|---|---|---|
| Cuenta por cobrar / pagar por factura con estado | `CUENTA_POR_COBRAR`, `CUENTA_POR_PAGAR` | Detalle por factura de las cuentas (ver decisión 2) |
| Condición contado/crédito y estado en facturas | `FACTURA_VENTA`, `COMPRA` | Reemplaza `FV_ES_CREDITO`; habilita el cambio automático de estado |
| Lote separado de la existencia, ligado al detalle de compra | `LOTE_PRODUCTO`, `EXISTENCIA_LOTE` | Vencimientos y antigüedad por lote |
| Traslado por lote | `TRASLADO`, `DETALLE_TRASLADO` | Forma final en decisión 6 |
| Validación de días por tipo de criterio | `CK_DESCUENTO_DIAS` | Reemplaza `DSC_DIAS_UMBRAL` único |
| Tipo de pago en abonos a proveedor | `ABONO_CXP` | Se agrega a `SGS_PAGO_FACTURA_PROVEEDOR` |
| Porcentaje de impuesto por producto | `PRODUCTO.PORCENTAJE_IMPUESTO` | Complementa `ART_EXENTO_IMPUESTO` |
| Estado `'A'/'I'` en catálogos | Todas las tablas | Patrón pedido por el profesor |
| Montos `NUMBER(14,2)` | Todas las tablas | Cierres y saldos acumulados |
| Número de factura único por proveedor y desglose de montos | `COMPRA` | Completa `SGS_FACTURA_PROVEEDOR` |

Opcionales, sin decidir: cliente genérico de contado (`CLIENTE.ES_GENERICO`) y referencia del pago (`REFERENCIA` en abonos).

### No se integra
| Pieza | Motivo |
|---|---|
| `EMPRESA` | Cubierto por `SGS_TIPO_NEGOCIO` |
| `BODEGA` | Se mantiene `SUC_ES_CENTRAL` |
| `PRECIO_PRODUCTO` | Es precio de venta; el E2 pide historial de costo (`SGS_HISTORICO_PRECIO`) |
| Cliente único | Se mantiene cliente / cliente persona |
| `CLIENTE_DIRECCION` | Dos direcciones fijas (casa y trabajo) |
| Cantidades en `PROMOCION_PRODUCTO` | El E2 las ubica en la tabla de promociones |
| Pago y abono separados (`PAGO_FACTURA` + `ABONO_CXC`) | Redundante; se usa el mecanismo único del E1 |
| Devolución separada de la nota de crédito | La nota de crédito del E1 ya cumple ese papel |

## 3. Lo que pide el E2 y no tiene ningún esquema

| Requisito | Qué se agrega al modelo |
|---|---|
| "Deben existir tipos de promociones" | Tipo de promoción |
| Descuentos planeados: "incluir los productos al detalle automáticamente" | Detalle de productos o lotes por descuento |
| Premio a los 10 mejores clientes con orden de compra | Órdenes de compra / premios a clientes |
| Cierre diario con detalle por cajero | Encabezado y detalle de cierre |
| Padrón nacional enlazado a clientes | Tabla del padrón (decisión 5) |
| Saldo del cliente y del proveedor | Encabezado de cuentas por cobrar / pagar (decisión 2) |
| Parametrización y destinatarios | Tabla de parámetros y tabla de destinatarios |
| Bitácoras de facturación, precios, inventario, clientes, proveedores, promociones y descuentos | Decisión 4 |
| Nacionalidad y residencia normalizadas | Tabla de países |

Vistas materializadas, seguridad, jobs y monitoreo no cambian el modelo base; se implementan en B3 a B8.

## 4. Lo que el enunciado del E1 sigue exigiendo

Revisado el 2026-10-26 sobre `entregable_1/Enunciado Entregable #1 - Proyecto.pdf`. El E2 dice que "se calificará nuevamente el modelo relacional", así que estos requisitos siguen vigentes:

| Requisito del E1 | Efecto en el modelo del E2 |
|---|---|
| "la aplicación sea multisucursal y multiusuario" (RF1) | Origen de `SGS_USUARIO` (usuarios del sistema). Se mantiene; la seguridad del E2 (usuarios, roles y perfiles de Oracle) se agrega encima |
| "en caso de no contar con un cliente registrado en la factura deberá tener uno por defecto" (RF14) | Cliente por defecto obligatorio. En el E1 era la fila "Consumidor Final" (id 1); hay que identificarlo de forma explícita (bloque 2) |
| "Las cédulas de los extranjeros pueden variar de tipo y tamaño" | La cédula solo se valida a 9 dígitos para clientes `NACIONAL` (decisión 5) |
| "Toda tabla necesitará de una secuencia" | Cada tabla nueva lleva su `SEQ_` |
| "Deberán tener 5 registros mínimo por tabla" | Datos de prueba: mínimo 5 filas por tabla, también en las nuevas |
| "normalizada en 5FN" | Las redundancias (saldo del encabezado de cuenta) se justifican como desnormalización controlada |
| Tablespaces: tablas, índices y auditoría | Ya cubierto por `01_infraestructura.sql` |
| Script con usuario, tablespaces, tablas, restricciones, índices, secuencias, vistas y comentarios | Estructura de `01` + `02` |
