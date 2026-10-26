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

**Porcentajes** (2026-10-26): todos los porcentajes del modelo y de los parámetros se guardan como **fracción** (`0.15` = 15 %), en `NUMBER(5,4)` con `CHECK BETWEEN 0 AND 1`. Se mantiene la convención del E1, que el profesor no corrigió. Los textos dirigidos a personas (correos, reportes) los muestran como porcentaje (`85 %`).

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
| `PCT_AVISO_CLIENTE` | 0.85 | 🟢 | Isaac |
| `PCT_AVISO_COORDINADOR` | 0.85 | 🟢 | Isaac |
| `PCT_AVISO_GERENTE_CXP` | 0.70 | 🟢 | Isaac |
| `DIAS_MOROSIDAD` | 30 | 🟢 | Isaac |
| `DIAS_PROXIMO_VENCER` | 7 | 🟢 | Isaac |
| `MESES_ANTIGUEDAD_BODEGA` | 6 | 🟢 | Isaac |
| `PREMIO_CANTIDAD_CLIENTES` | 10 | 🟢 | Isaac |
| `PREMIO_MONTO_ORDEN` | 100000 | 🔴 | Isaac |
| `PREMIO_FRECUENCIA_MESES` | 6 | 🔴 | Isaac |

### Monitoreo

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `PCT_MAX_TABLESPACE` | 0.85 | 🟢 | Isaac |

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

**Decisión 4 — Estrategia de bitácoras** · 2026-10-26

Bitácora general de encabezado y detalle (audit trail genérico) en lugar de una tabla de auditoría por área.
- **`SGS_BITACORA`** (encabezado, una fila por operación): área (una de las 7 del enunciado, con CHECK), tabla, operación (`I/U/D`), id del registro, usuario de base de datos, usuario del sistema operativo y equipo, fecha (`TIMESTAMP`) e indicador `ES_CRITICA` `'S'/'N'`.
- **`SGS_BITACORA_DETALLE`** (una fila por columna modificada): columna, valor anterior y valor nuevo en `VARCHAR2(250)`, sin CLOB.
- **`SGS_BITACORA_ERROR`** aparte: package o procedimiento, código y mensaje de error, usuario y fecha. La usa el manejo de excepciones de todos los packages.
- Las tres en `SGS_AUD`.
- Cambios respecto al E1: se elimina el CLOB de `BIT_DETALLE`, la FK a `SGS_USUARIO` (los triggers ven al usuario de base de datos) y las acciones `LOGIN/LOGOUT` (el monitoreo de sesiones va en B8).
- `SGS_HISTORICO_PRECIO` se mantiene como historial tipado del negocio; el cambio de costo queda también en la bitácora como auditoría.
- Pendiente para B4: definir qué operaciones se marcan como críticas, tabla por tabla.

**Decisión 5 — Enlace padrón ↔ clientes** · 2026-10-26

- Tablas nuevas: **`SGS_PADRON`** (una fila por persona: cédula, nombre, apellidos, sexo, distrito electoral) y **`SGS_DISTRITO_ELECTORAL`** (catálogo `Distelec`: provincia, cantón, distrito).
- El padrón trae ciudadanos costarricenses mayores de edad (nacidos en Costa Rica y naturalizados). En el modelo, `NACIONAL` = cliente con cédula costarricense; `EXTRANJERO` = DIMEX o pasaporte (no está en el padrón); las empresas tampoco están.
- **FK opcional** desde `SGS_CLIENTE_PERSONA` hacia `SGS_PADRON` (columna nueva, nula para extranjeros). Un trigger impide el enlace si el cliente no es `NACIONAL`.
- `CLI_CEDULA` de un cliente `NACIONAL` debe tener 9 dígitos sin guiones (CHECK), igual que el padrón.
- Al registrar un cliente nacional, el procedimiento de registro busca la cédula en el padrón y llena nombre, apellidos y sexo (`1/2` → `M/F`). A los extranjeros se les digita todo.
- La carga del padrón hace `MERGE` (inserta nuevos, actualiza existentes); nunca vacía la tabla, para no romper la FK de los clientes.
- Padrón en `SGS_DATA`. El formato del archivo (TXT del TSE o CSV del laboratorio) solo afecta el procedimiento de carga (B5), no el modelo.
- Consecuencias: los clientes nacionales de prueba deben usar cédulas que existan en el padrón cargado; el padrón se carga antes que los clientes.

**Decisión 6 — Modelado de lotes** · 2026-10-26

- **`SGS_LOTE`**: cada ingreso de un producto, nacido de una línea de factura de proveedor. Producto, fecha de ingreso, fecha de vencimiento (nula si no vence) y costo.
- **`SGS_EXISTENCIA`**: cantidad por lote y sucursal (la bodega central es la sucursal con `SUC_ES_CENTRAL = 'S'`). Una fila por lote y sucursal.
- **Traslado** con encabezado (origen, destino, fecha, usuario) y detalle por lote; reemplaza a `SGS_TRASLADO_INVENTARIO` por producto.
- **`SGS_MOVIMIENTO_INVENTARIO`**: una fila por cada entrada o salida de un lote en una sucursal, con tipo (compra, venta, devolución de cliente, devolución a proveedor, traslado) y la línea del documento que la causó.
- Las ventas consumen los lotes por FEFO (primero los que vencen antes). La factura de venta no lleva lote: el lote consumido queda en el movimiento, y de ahí se sabe a qué lote regresa una devolución.
- La tabla de movimientos cubre el ítem "Movimientos de inventario" de la guía y respalda el área de bitácora del mismo nombre.

**Bloque 2 del modelo (personas)** · 2026-10-26
- El límite de crédito sale de `SGS_CLIENTE` y `SGS_PROVEEDOR` y vive en el encabezado de su cuenta (decisión 2). Cada cliente tiene su encabezado, con límite 0 si no tiene crédito.
- Cliente por defecto: indicador `CLI_ES_DEFECTO` con índice único funcional (`UX_CLI_UNICO_DEFECTO`), mismo patrón que la bodega central.
- Enlace al padrón por id (`CLP_ID_PADRON → PAD_ID`), único por persona; se busca por cédula al registrar. El id se conserva entre recargas porque el `MERGE` es por cédula.
- `SEQ_PADRON` con `CACHE 1000` (única excepción a `NOCACHE`) por la carga masiva.

**Usuarios del sistema vs. usuarios de base de datos** · 2026-10-26

Son dos mundos separados; ninguna tabla los mezcla.
- **Usuarios del sistema (`SGS_USUARIO`)**: personas del negocio (cajeros, gerentes); vienen del requisito "multiusuario" del E1. No se conectan a Oracle. El cajero de una factura (`FV_ID_USUARIO`) y el del cierre diario son **datos del negocio**, como el cliente. Se mantiene la contraseña: hash SHA-256 con `DBMS_CRYPTO.HASH` y una sal por usuario (`USU_SAL`); estado `A/I`.
- **Usuarios de base de datos (Oracle)**: `SGS_ADMIN` y las cuentas con los roles Gerente, Jefe Departamento, Jefe Proveeduría y Digitador, con sus perfiles (E2, seguridad). No son filas de ninguna tabla. La bitácora registra la cuenta de Oracle que hizo el cambio; no lleva columna de usuario del sistema.
- Si las cuentas de Oracle son por función o por persona se decide en B7, releyendo el enunciado del E2 (fuente de verdad). Si el enunciado no lo define, se sigue el patrón del laboratorio #3 (una cuenta por función, como `AGRO_OPER`, con su rol y su perfil).

**Forma de trabajo** · 2026-10-13
- Desarrollo en Docker (`FREEPDB1`); oficial en `SGSPRI` (`SGSPDB`).
- El script es lo oficial: nada se cambia solo en la base.
- Un script consolidado por etapa, probado desde cero antes de subirlo e integrarlo.
- El esquema del E1 (`IALVARADO`) se elimina del Docker; queda respaldado en `SGS_IsaacAlvarado.sql`.

## Carril S — Servidores

*(Se completa a medida que avanza Andrés.)*