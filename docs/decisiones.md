# Decisiones del proyecto

Registro de acuerdos tomados. Antes de usar un nombre, valor o criterio nuevo, se anota aquí.

## Etapa 0 — Acuerdos previos

| Fecha | Decisión | Valor |
|---|---|---|
| 2026-10-13 | Usuario dueño del esquema | `SGS_ADMIN` |
| 2026-10-13 | Pluggable database | `SGSPDB` |
| 2026-10-13 | Servidor principal (`DB_UNIQUE_NAME`) | `SGSPRI` |
| 2026-10-13 | Servidor standby (`DB_UNIQUE_NAME`) | `SGSSTB` |
| 2026-10-13 | Prefijo de objetos | `SGS_` |
| 2026-10-13 | Arquitectura | 2 VMs (Oracle Linux + Oracle 21c EE) en la HP de Andrés; Mac de Isaac como cliente con DBeaver. Validado con el profesor. |
| 2026-10-13 | Red | Principal ↔ standby por red interna de las VMs. Tailscale solo para que el Mac llegue a las VMs, **sin exit node**. |
| 2026-10-13 | Documentación de trabajo | Vive en este repositorio (guía en `guia.md`, en la raíz). |
| 2026-10-13 | Cuenta remitente de notificaciones | `sgs.notificaciones.una@gmail.com` (la contraseña NO se guarda en el repo) |

## Parámetros

Los parámetros se guardan como **filas** dentro de la tabla de parámetros (no llevan prefijo `SGS_`; la tabla sí). Los valores se guardan en `VARCHAR2(250)` (sin CLOB). 🔴 = obligatorio por el enunciado · 🟢 = recomendado · 🔒 = cifrado con `DBMS_CRYPTO`.

**Destinatarios de notificaciones:** no van como parámetros. Se guardan en una **tabla de destinatarios** aparte (tipo: gerente, coordinador, DBA; uno o varios correos por tipo), porque el enunciado habla de "correo(s)". Su diseño se cierra en B1.

### Correo

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `CORREO_REMITENTE` | `sgs.notificaciones.una@gmail.com` | 🔴 | Isaac |
| `CORREO_CLAVE` | contraseña de aplicación de Gmail | 🔴🔒 | Isaac |
| `CORREO_SERVIDOR` | `smtp.gmail.com` | 🟢 | Isaac |
| `CORREO_PUERTO` | `587` | 🟢 | Isaac |

### Reglas de negocio

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `PCT_AVISO_CLIENTE` | 85 | 🟢 | Isaac |
| `PCT_AVISO_COORDINADOR` | 85 | 🟢 | Isaac |
| `PCT_AVISO_GERENTE_CXP` | 70 | 🟢 | Isaac |
| `DIAS_MOROSIDAD` | 30 | 🟢 | Isaac |
| `DIAS_PROXIMO_VENCER` | 7 | 🟢 | Isaac |
| `MESES_ANTIGUEDAD_BODEGA` | 6 | 🟢 | Isaac |
| `PREMIO_CANTIDAD_CLIENTES` | 10 | 🟢 | Isaac |
| `PREMIO_MONTO_ORDEN` | 100000 | 🔴 | Isaac |
| `PREMIO_FRECUENCIA_MESES` | 6 | 🔴 | Isaac |

### Monitoreo

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `PCT_MAX_TABLESPACE` | 85 | 🟢 | Isaac |

### Standby y respaldos

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `STB_MINUTOS_ARCHIVO` | 5 | 🔴 | Andrés |
| `STB_MB_ARCHIVO` | 50 | 🔴 | Andrés |
| `STB_MINUTOS_TRASLADO` | 10 | 🔴 | Andrés |
| `STB_DIAS_BORRADO` | 3 | 🔴 | Andrés |
| `RESP_HORA_DIARIO` | **pendiente (Andrés)** | 🟢 | Andrés |

### Claves de roles

| Código | Valor | Tipo | Lo usa |
|---|---|---|---|
| `CLAVE_ROL_GERENTE` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_JEFE_DEPTO` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_JEFE_PROVEEDURIA` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_DIGITADOR` | se define en B7 | 🔴🔒 | Isaac |

## Carril B — Base de datos

### B1 — Esquema

**Decisión 1 — Qué se integra del esquema de Andrés (`CADENA_NEGOCIOS`)** · 2026-10-13

Se integra (traducido a la convención SGS):
- Cuentas por cobrar y por pagar con sus abonos y estado.
- Condición (contado/crédito) y estado en las facturas de venta y de proveedor.
- Lote separado de la existencia, ligado al detalle de compra y con fecha de vencimiento.
- Descuento con días desde ingreso / días para vencer y validación por tipo de criterio.
- Tipo de pago en los abonos a proveedor.
- Porcentaje de impuesto por producto (opcional elegido).

Ampliación · 2026-10-25 (tras revisar los scripts del E1, ver [`notas/analisis_e1.md`](../notas/analisis_e1.md)):
- Estado activo/inactivo (`VARCHAR2(1)` `'A'/'I'` con CHECK) en los catálogos que no lo tienen: proveedor, producto, familia, tipo de pago, promoción y descuento.
- Montos en `NUMBER(14,2)` en lugar de `NUMBER(10,2)`.
- Número de factura del proveedor (único por proveedor) y desglose de subtotal, descuento e impuesto en la factura de proveedor.
- Traslado por lote en lugar de por producto; su forma final se cierra con la decisión 6 (modelado de lotes).
- Los abonos se manejan con el mecanismo único del E1 (`SGS_PAGO_FACTURA_*`, pago inmediato o abono parcial); no se separa pago y abono como en `CADENA_NEGOCIOS`.

No se integra: `BODEGA` (se mantiene `SUC_ES_CENTRAL`), `EMPRESA` (cubierto por tipo de negocio), `PRECIO_PRODUCTO` (el E2 pide historial de costo, ya cubierto), `CLIENTE` único (se mantiene la separación cliente / cliente persona), `CLIENTE_DIRECCION` (dos direcciones fijas), cantidades de promoción en `PROMOCION_PRODUCTO` (el E2 las ubica en la tabla de promociones).

**Decisión 2 — Dónde vive el saldo de clientes y proveedores** · 2026-10-25

Opción C: encabezado de cuenta por cliente y por proveedor + detalle por factura.
- **Encabezado** (uno por cliente / proveedor): límite de crédito y saldo total. Es la fila que se bloquea con `SELECT ... FOR UPDATE NOWAIT/WAIT` y contra la que se validan el límite y los avisos del 85 % y 70 %.
- **Detalle** (uno por factura a crédito pendiente): monto original y saldo de esa factura. Equivale a la CxC / CxP por factura de `CADENA_NEGOCIOS`.
- **Abonos**: en `SGS_PAGO_FACTURA_*`, ligados a la factura; el último pago de un cliente sale de ahí (morosidad).
- El saldo del encabezado y del detalle **solo lo mantienen los triggers**; nunca se edita a mano. La redundancia es una desnormalización controlada para cumplir literalmente el enunciado ("aumentar el saldo del cliente" + "agregar esta factura al detalle") y para la concurrencia.

**Decisión 3 — Códigos de atributos de dominio corto** · 2026-10-25

Regla (sigue la corrección del profesor: estados y género en `VARCHAR2(1)` con CHECK, sin `CHAR`):

| Tipo de atributo | Formato |
|---|---|
| Estados de registros y documentos | `VARCHAR2(1)` + CHECK |
| Indicadores sí/no | `VARCHAR2(1)` `'S'/'N'` + CHECK |
| Datos personales cortos | `VARCHAR2(1)` + CHECK |
| Tipos que guían la lógica (`CLI_TIPO_PERSONA`, `DSC_TIPO_CRITERIO`, etc.) | Palabra corta en `VARCHAR2` + CHECK |

Códigos:

| Atributo | Códigos |
|---|---|
| Estado de catálogos y usuarios | `A` activo · `I` inactivo |
| Estado de factura (venta y proveedor) | `P` pendiente · `C` cancelada · `N` anulada |
| Sexo | `M` masculino · `F` femenino |
| Estado civil | `S` soltero · `C` casado · `D` divorciado · `V` viudo · `U` unión libre |

- Contado/crédito se mantiene como indicador `'S'/'N'` (`FV_ES_CREDITO` del E1) y se agrega el equivalente en la factura de proveedor; no se usa el campo `CONTADO/CREDITO` de `CADENA_NEGOCIOS`.
- El detalle de cuenta por cobrar / pagar **no lleva estado propio**: el estado vive en la factura; un abono parcial se identifica comparando el saldo del detalle con su monto original.

**Forma de trabajo** · 2026-10-13
- Desarrollo en Docker (`FREEPDB1`); oficial en `SGSPRI` (`SGSPDB`).
- El script es lo oficial: nada se cambia solo en la base.
- Un script consolidado por etapa, probado desde cero antes de subirlo e integrarlo.
- El esquema del E1 (`IALVARADO`) se elimina del Docker; queda respaldado en `SGS_IsaacAlvarado.sql`.

## Carril S — Servidores

*(Se completa a medida que avanza Andrés.)*