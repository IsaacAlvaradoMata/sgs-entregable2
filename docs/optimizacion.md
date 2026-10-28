# Optimización SQL: planes de ejecución

Análisis con `EXPLAIN PLAN` y `DBMS_XPLAN` de las consultas que implementan los requerimientos funcionales del sistema (`bd/09_monitoreo.sql`, sección 6). Antes de analizar se actualizaron las estadísticas del esquema con `DBMS_STATS.GATHER_SCHEMA_STATS`, para que el optimizador conozca el tamaño real de cada tabla (el padrón tiene 3 762 248 filas; las tablas de operaciones, decenas).

| Consulta | Requerimiento | Costo | Índices usados | Recorridos completos |
|---|---|---|---|---|
| Q1 Precio de venta de un producto en una sucursal | RF 8 y 25 | 11 | `IDX_DSC_TIPO_CRITERIO`, `IDX_DSF_FAMILIA`, `PK_ARTICULO_FACTURABLE` y otros | Ninguno |
| Q2 Persona del padrón por cédula | RF 17, padrón | 3 | `UK_PAD_CEDULA` (unique scan) | Ninguno |
| Q2 Persona del padrón por nombre y apellido | (comparación) | 8 453 | Ninguno | `SGS_PADRON` |
| Q3 Lotes por vencer o con más de 6 meses | RF 9 | 6 | `PK_LOTE` (full scan del índice) | `SGS_EXISTENCIA` |
| Q4 Clientes morosos | RF 18 y 24 | 12 | `IDX_FV_CLIENTE`, `IDX_PFV_FACTURA` (range scan) | `SGS_CUENTA_COBRAR` |
| Q5 Ventas de un día por cajero (cierre) | RF 15 | 2 | `IDX_FV_USUARIO` (full scan del índice) | Ninguno |
| Q6 Mejores clientes de los últimos 6 meses | RF 17 y 18 | 6 | `IDX_FV_FECHA` (range scan), `PK_CLIENTE` | Ninguno |

## Conclusiones

1. **Padrón: buscar por cédula, nunca por nombre.** La búsqueda por cédula usa el índice único `UK_PAD_CEDULA`, lee una sola fila y tiene costo 3. La misma búsqueda por nombre y apellido recorre las 3,7 millones de filas, con costo 8 453: unas 2 800 veces más cara. Por eso el registro de clientes nacionales (`SGS_PKG_CLIENTES.registrar_nacional`) busca a la persona por cédula. El sistema no necesita buscar por nombre, así que no se agrega un índice para eso: ocuparía espacio y haría más lenta la carga del padrón sin ningún beneficio.
2. **Precio de venta.** Es la consulta más compleja (producto, artículo, sucursal y tres fuentes de descuento), y aun así no recorre ninguna tabla completa: cada unión entra por su llave primaria o por los índices de las llaves foráneas que se crearon en el modelo (`IDX_DSF_FAMILIA`, `IDX_DSC_TIPO_CRITERIO`). Se ejecuta en cada línea de venta, así que conviene que siga así.
3. **Ventas por fecha.** La premiación (Q6) filtra el período con `IDX_FV_FECHA` (range scan) en lugar de leer todas las facturas: con años de ventas, el costo depende del período y no del historial completo. En el cierre (Q5) el optimizador prefirió recorrer `IDX_FV_USUARIO`, porque hoy la tabla tiene muy pocas facturas y agrupar por cajero desde ese índice le sale igual de barato. Cuando las facturas crezcan, las estadísticas cambian y el filtro de un solo día pasa a resolverse con `IDX_FV_FECHA`.
4. **Recorridos completos que son correctos.** `SGS_CUENTA_COBRAR` en morosos (Q4) y `SGS_EXISTENCIA` en lotes (Q3) se leen completas porque la consulta necesita revisar todas sus filas (todos los clientes con saldo y todas las existencias mayores que cero), y son tablas pequeñas (una fila por cliente o por lote y sucursal). Un índice no evitaría leer esas filas.
5. **Lotes (Q3).** La condición combina dos columnas distintas con `OR` (fecha de vencimiento **o** fecha de ingreso), y por eso los índices `IDX_LOT_VENCIMIENTO` e `IDX_LOT_INGRESO` no se usan por separado: con pocos lotes, leer todo `PK_LOTE` es lo más barato. Si los lotes crecen, la consulta se puede reescribir como dos consultas unidas con `UNION ALL`, una por cada fecha, para que cada parte use su índice.
6. **Morosos (Q4).** Las subconsultas por cliente entran por `IDX_FV_CLIENTE` y `IDX_PFV_FACTURA`: buscan solo las facturas y los pagos de cada cliente, sin recorrer todas las facturas ni todos los pagos.

Los índices que hoy no aparecen en los planes (`IDX_LOT_VENCIMIENTO`, `IDX_LOT_INGRESO`, `IDX_NCV_FECHA`) se mantienen: el optimizador los descarta solo porque las tablas tienen pocas filas, y empiezan a usarse cuando crecen.
