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

**Correos de desarrollo** (2026-10-26): los destinatarios y los clientes de prueba usan alias de la cuenta del proyecto (`sgs.notificaciones.una+gerente@gmail.com`, `+coordinador`, `+dba`, `+maria`, etc.). Todo llega a la bandeja del proyecto y no se publica ningún correo personal en el repo. Antes de la defensa se actualizan las filas de `SGS_DESTINATARIO` con el correo externo que indique el profesor.

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
- Al registrar un cliente nacional, el procedimiento de registro busca la cédula en el padrón y llena nombre y apellidos. El sexo se digita (el archivo del TSE no lo trae). A los extranjeros se les digita todo.
- Ajuste (2026-10-26, tras revisar `PADRON_COMPLETO.txt`): se quitan `PAD_SEXO` (el campo viene vacío en las 3.762.240 filas) y `PAD_JUNTA` (siempre `00000`). Personas de prueba del padrón: inventadas con el formato exacto del TSE y cédulas que no existen en el archivo real, porque los datos de prueba les asignan compras y deudas y el repo es público.
- Formato de los archivos (para B5): `PADRON_COMPLETO.txt` = cédula(9), codelec(6), sexo(1, vacío), caducidad(8, `AAAAMMDD`), junta(5), nombre(30), apellido1(26), apellido2(26), separados por coma y rellenos con espacios; 3.762.240 filas; Latin-1 (Ñ = `D1`); fin de línea `\r\n`. `distelec.txt` = codelec, provincia, cantón, distrito; 2.178 filas; una fila trae coma dentro del nombre del distrito (línea 521) y la última línea viene vacía. Ninguno de los dos se sube al repo (pesan y son públicos en el TSE).
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
- Ajuste al escribir el bloque 7 (2026-10-26): el lote **no guarda producto ni costo**; se leen de la línea de compra de origen (FK obligatoria y única), para no repetir datos (5FN). El movimiento tiene una FK opcional por tipo de documento y un CHECK que exige exactamente la que corresponde a su tipo.

**Bloque 2 del modelo (personas)** · 2026-10-26
- El límite de crédito sale de `SGS_CLIENTE` y `SGS_PROVEEDOR` y vive en el encabezado de su cuenta (decisión 2). Cada cliente tiene su encabezado, con límite 0 si no tiene crédito.
- Cliente por defecto: indicador `CLI_ES_DEFECTO` con índice único funcional (`UX_CLI_UNICO_DEFECTO`), mismo patrón que la bodega central.
- Enlace al padrón por id (`CLP_ID_PADRON → PAD_ID`), único por persona; se busca por cédula al registrar. El id se conserva entre recargas porque el `MERGE` es por cédula.
- `SEQ_PADRON` con `CACHE 1000` (única excepción a `NOCACHE`) por la carga masiva.

**Tablas de monitoreo** · 2026-10-26

Revisión de B2 a B8 contra el enunciado: todo tiene dónde guardarse salvo el "crecimiento de la base de datos" del paquete de monitoreo, que requiere mediciones en el tiempo.
- **`SGS_MONITOREO`** (una fila por revisión diaria): tamaño total de la base, sesiones totales y activas, objetos inválidos e índices dañados.
- **`SGS_MONITOREO_TABLESPACE`** (detalle): espacio usado y máximo de cada tablespace en cada revisión. El porcentaje de uso no se guarda: se calcula (usado / máximo).
- Ambas en `SGS_AUD`, como registros históricos.
- No se agrega registro de notificaciones enviadas (el enunciado no lo pide). Pendiente: preguntar a Andrés si sus procesos de standby y RMAN necesitan alguna tabla.

**Datos de prueba en dos partes** · 2026-10-26
- **B1:** datos de catálogos que no dependen de triggers (países, sucursales, tipos de negocio, familias, tipos de pago, distritos, proveedores, clientes, productos, tipos de promoción, premios, descuentos).
- **Después de B3:** operaciones (compras, ventas, pagos, devoluciones, traslados) cargadas **a través de los packages**, para que saldos, existencias, movimientos, bitácoras e histórico de precios los llenen los triggers y queden consistentes. Esa carga sirve además como prueba de los packages.
- Meta del E1: mínimo 5 filas por tabla, con casos que demuestren los requisitos (clientes cerca del 85 %, lotes por vencer y antiguos, morosos).


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


### B3 — Reglas de negocio

**Definiciones de B3** · 2026-10-26

1. **Arquitectura híbrida.** Packages para las operaciones (`registrar_venta`, `registrar_compra`, `registrar_pago`, devoluciones, traslados): validan, bloquean con `FOR UPDATE NOWAIT/WAIT`, eligen lotes, usan `SAVEPOINT`/`COMMIT`/`ROLLBACK` y dan mensajes claros. Triggers para lo que el enunciado llama "automático" (saldos, estado de facturas, existencias, historial de precios, cuenta de cada cliente y proveedor) y para validaciones que cruzan tablas; funcionan aunque se inserte directo sin el package. Reglas: cada trigger solo modifica tablas distintas a la suya (sin tabla mutante) y el package no repite lo que hace un trigger.
2. **Notas de crédito.** Si la factura es a crédito y tiene saldo, la nota rebaja el saldo de la factura y de la cuenta (hasta 0); si llega a 0, la factura pasa a cancelada. Si es de contado o ya está cancelada, la nota es dinero devuelto y no toca saldos. En todos los casos la mercadería regresa al lote del que salió. Igual para proveedores.
3. **Lote en una venta (FEFO).** Primero los lotes que vencen antes; los que no vencen, por orden de ingreso. Solo de la sucursal donde se vende. Si no alcanza, la venta se rechaza completa.
4. **Costo diferente.** Cuenta tanto una compra con costo distinto (el package actualiza el costo del producto) como un cambio directo; el historial lo genera un trigger sobre el costo del producto.

### B4 — Bitácoras de auditoría

**Definiciones de B4** · 2026-10-27

1. **Tablas auditadas (33, un trigger `TRG_AUD_<prefijo>` por tabla).** FACTURACION: facturas, detalles, pagos, notas de crédito y sus detalles, de venta y de proveedor. PRECIOS: producto, producto por sucursal, artículo facturable y servicio. INVENTARIO: movimientos, existencias, lotes, traslados y su detalle. CLIENTES: cliente, cliente persona y cuenta por cobrar. PROVEEDORES: proveedor y cuenta por pagar. PROMOCIONES: promoción, sus productos, premios, premios por promoción y acciones otorgadas. DESCUENTOS: descuento y sus enlaces a familia, proveedor y producto. No se auditan `DETALLE_CUENTA_*` (las calcula un trigger a partir de facturas y pagos, que ya se auditan), `HISTORICO_PRECIO` (ya es historial), padrón, catálogos ni las bitácoras.
2. **Mecanismo.** `SGS_PKG_BITACORA` acumula las columnas que cambiaron (`columna`) y guarda encabezado y detalle (`guardar`). Inserción: valores nuevos; actualización: solo lo que cambió; borrado: valores anteriores; una actualización sin cambios no deja rastro. Los triggers se generan a partir de las columnas de `02_modelo.sql`.
3. **Misma transacción, sin bloquear.** El registro no es autónomo: si la operación hace `ROLLBACK` (o `ROLLBACK TO` un savepoint), su rastro también se deshace. Si la auditoría falla, el trigger registra el error en `SGS_BITACORA_ERROR` y la operación sigue.
4. **Operaciones críticas (`BIT_ES_CRITICA = 'S'`).** Todo borrado. FACTURACION: anular (estado `N`) o modificar una factura o línea existente, todo pago y toda nota de crédito. PRECIOS: utilidad, descuento máximo, impuesto, precio de servicio, y el costo cuando **no** lo cambia `SGS_PKG_COMPRAS` (se detecta con la pila de llamadas). INVENTARIO: existencia cambiada sin pasar por `TRG_MOV_EXISTENCIA` (ajuste a mano) y cualquier cambio a un lote o traslado registrado. CLIENTES: cédula, estado, preferencial y límite de crédito (el saldo no: lo mueven ventas y pagos). PROVEEDORES: cédula jurídica, estado y límite. PROMOCIONES: tipo, fechas, cantidades y estado de la promoción, y cambios a sus productos, premios y acciones otorgadas. DESCUENTOS: criterio, porcentaje, días, fechas y estado, y cambios a sus enlaces.
5. **Consulta.** Vistas `SGS_VW_BITACORA` (encabezado con detalle) y `SGS_VW_BITACORA_CRITICA` (solo críticas, para la gerencia; en B7 se le da `SELECT` al rol Gerente).

### B5 — Padrón

**Definiciones de B5** · 2026-10-27

El enunciado pide cargar el padrón con la información actual, enlazarlo con clientes (hecho en B1 y B3) y "un procedimiento que cargue automáticamente el padrón". Se implementa lo mínimo que lo cumple:
1. **Archivos del TSE** (`PADRON_COMPLETO.txt` y `distelec.txt`) en un directorio del servidor, con el objeto de directorio `SGS_DIR_PADRON` creado desde SYSDBA. Docker: `/opt/oracle/oradata/padron`; SGSPRI: a acordar con Andrés.
2. **Dos tablas externas** (`ORACLE_LOADER`, Latin-1): el padrón por posiciones fijas (todas las líneas miden 118 caracteres) y `distelec` por línea completa, separando solo las tres primeras comas (una fila trae coma en el nombre del distrito).
3. **`SGS_PKG_PADRON.cargar`**: `MERGE` de distritos por codelec y de personas por cédula, sin borrar nunca; con `SAVEPOINT`/`ROLLBACK TO` y `SGS_PKG_ERRORES.registrar` como los demás packages. Sin `NOLOGGING` para que la standby reciba la carga.
4. **Sin job:** "automáticamente" es que el procedimiento hace la carga completa solo; el enunciado no pide que corra programado. Se ejecuta cuando hay que cargar o actualizar el padrón.

### B6 — Procesos programados y notificaciones

**Definiciones de B6** · 2026-10-27

1. **Organización.** Un package `SGS_PKG_PROCESOS` con un procedimiento por proceso y un job de `DBMS_SCHEDULER` (`SGS_JOB_*`) por procedimiento. Cada proceso se puede correr a demanda (llamando al procedimiento o con `DBMS_SCHEDULER.RUN_JOB`). Si un proceso no encuentra casos, no envía correo.
2. **Frecuencia de las notificaciones (N1 a N5).** El enunciado no la define. Job **diario a las 07:00** (hora de Costa Rica) para cada una, y sin recordar a quién ya se avisó: mientras el caso siga, el correo se repite cada día como recordatorio. No se usan triggers para notificar: la morosidad y los vencidos dependen del paso del tiempo, N2 y N3 deben ser un solo correo agrupado, y un correo enviado desde un trigger sale aunque la operación haga `ROLLBACK`.
3. **Hora de los jobs.** La fecha de inicio de cada job se fija en `America/Costa_Rica`, así el scheduler calcula la hora en Costa Rica aunque el servidor esté en otra zona (Docker está en UTC).
4. **N2 (lista al coordinador).** El enunciado dice "clientes" y "cuentas por pagar"; se toma como **clientes**: un solo correo al coordinador con todos los clientes al 85 % o más de su límite (`PCT_AVISO_COORDINADOR`). N1 y N2 comparten la consulta. Pregunta enviada al profesor; si responde que son proveedores, solo cambia esa consulta.
5. **N3 (proveedores al 70 %).** Sobre el límite **de cada proveedor** (`SGS_CUENTA_PAGAR`), con saldo ≥ 70 % (`PCT_AVISO_GERENTE_CXP`); "cerca de" se toma como "70 % o más". Un solo correo al gerente con los proveedores que llegaron al umbral y, para cumplir "que incluya a todos los proveedores", el estado de todos los proveedores con crédito y el total adeudado.
6. **N4 (morosos).** Cliente con saldo y más de `DIAS_MOROSIDAD` días (30) desde su **último abono a una factura a crédito** (las compras de contado no cuentan como abono a la deuda); si nunca abonó, desde su factura a crédito pendiente más vieja. Mismo parámetro para los dos casos. Un solo correo a gerente y coordinador.
7. **P1 (inventario semanal).** Lunes 07:00, un correo al coordinador con dos secciones: lotes con existencia que vencen en los próximos `DIAS_PROXIMO_VENCER` días y lotes con existencia que ingresaron hace más de `MESES_ANTIGUEDAD_BODEGA` meses, **en cualquier sucursal** (el producto sigue siendo antiguo aunque se haya trasladado).
8. **P2 (descuentos planeados).** Lunes 06:00, antes de P1. Para cada descuento activo y no terminado de criterio `INGRESO` o `VENCIMIENTO`, agrega al detalle los productos con lotes en existencia que cumplen los días; **solo agrega** (el detalle queda como historial) y no incluye lotes vencidos. Sin correo: el enunciado no lo pide.
9. **P3 (premiación).** Cada `PREMIO_FRECUENCIA_MESES` meses, el día 1 a las 08:00. Período = los últimos `PREMIO_FRECUENCIA_MESES` meses hasta hoy (el enunciado fija la frecuencia; cada premiación mira ese mismo período). Compras netas: facturas no anuladas menos sus notas de crédito, sin el cliente por defecto. Los `PREMIO_CANTIDAD_CLIENTES` mejores reciben una orden de `PREMIO_MONTO_ORDEN`; correo al coordinador. Si cambia la frecuencia, se vuelve a ejecutar el bloque de jobs.
10. **P4 (cierre diario).** 00:05, cierra el día anterior (el procedimiento recibe la fecha para cerrar otro día a demanda). Facturas no anuladas y monto vendido, devoluciones (notas de crédito) y monto devuelto, total = vendido − devuelto, y detalle por cajero (quien facturó o hizo la devolución). Si el cierre de esa fecha ya existe se **recalcula y reemplaza**. Se guarda antes de enviar el correo a gerente y coordinador, para no perder el cierre si el correo falla. Se envía aunque el día no tenga ventas.

## Carril S — Servidores

*(Se completa a medida que avanza Andrés.)*