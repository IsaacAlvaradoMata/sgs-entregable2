-- Paso 4.1, pruebas de la bitacora. Conexion: Docker - SGS_ADMIN (FREEPDB1).

-- PARTE 1 (Cmd + Enter sobre el bloque, sin la /): una operacion normal por area con los packages
DECLARE
    v_factura    NUMBER;
    v_id         NUMBER;
    v_cliente    NUMBER;
    v_limite     NUMBER;
    v_sin_pagos  SGS_PKG_VENTAS.t_pagos;
BEGIN
    -- Facturacion, precios e inventario: compra de contado de BEB-002 con costo nuevo (350 -> 360)
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100002', p_numero => 'BT-3002', p_usuario => 'crodriguez', p_es_credito => 'N',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'BEB-002', cantidad => 100, costo => 360, vencimiento => TRUNC(SYSDATE) + 300)),
        p_tipo_pago => 'Transferencia', p_id_factura => v_factura);
    -- Inventario: traslado a San Isidro
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal San Isidro', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-002', cantidad => 20)), v_id);
    -- Clientes: Carlos recibe 50 000 mas de credito (critico)
    SELECT c.CLI_ID, x.CXC_LIMITE_CREDITO
      INTO v_cliente, v_limite
      FROM SGS_CLIENTE c
      JOIN SGS_CUENTA_COBRAR x ON x.CXC_ID_CLIENTE = c.CLI_ID
     WHERE c.CLI_CEDULA = '199990002';
    SGS_PKG_CREDITO.asignar_credito(v_cliente, v_limite + 50000);
    -- Facturacion y clientes: venta a credito a Carlos y un abono
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990002', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-002', cantidad => 6)),
        p_pagos => v_sin_pagos, p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_pago(v_factura, 1000, 'Efectivo');
    -- Proveedores: cambio de telefono (no critico)
    UPDATE SGS_PROVEEDOR SET PRV_TELEFONO = '2293-2001' WHERE PRV_CEDULA_JURIDICA = '3101100002';
    -- Promociones: cambio de descripcion (no critico)
    UPDATE SGS_PROMOCION
       SET PRM_DESCRIPCION = PRM_DESCRIPCION || ' (bases en cada sucursal)'
     WHERE PRM_ID = (SELECT MIN(PRM_ID) FROM SGS_PROMOCION);
    -- Descuentos: descuento de diciembre para bebidas
    INSERT INTO SGS_DESCUENTO (DSC_ID, DSC_NOMBRE, DSC_TIPO_CRITERIO, DSC_PORCENTAJE, DSC_FECHA_INICIO, DSC_FECHA_FIN)
    VALUES (SEQ_DESCUENTO.NEXTVAL, 'Bebidas navidad', 'FAMILIA', 0.12, DATE '2026-12-15', DATE '2026-12-31')
    RETURNING DSC_ID INTO v_id;
    INSERT INTO SGS_DESCUENTO_FAMILIA (DSF_ID, DSF_ID_DESCUENTO, DSF_ID_FAMILIA)
    VALUES (SEQ_DESCUENTO_FAMILIA.NEXTVAL, v_id, (SELECT FAM_ID FROM SGS_FAMILIA_PRODUCTO WHERE FAM_NOMBRE = 'Bebidas'));
    COMMIT;
END;
/

-- PARTE 2 (Cmd + Enter): verificacion OK/FALLA de la parte 1
WITH b AS (SELECT * FROM SGS_BITACORA WHERE BIT_FECHA >= SYSTIMESTAMP - INTERVAL '30' MINUTE)
SELECT 'Rastro en ' || a.AREA AS PRUEBA,
       CASE WHEN COUNT(b.BIT_ID) > 0 THEN 'OK' ELSE 'FALLA' END AS RESULTADO, COUNT(b.BIT_ID) AS FILAS
  FROM (SELECT 'FACTURACION' AS AREA FROM DUAL UNION ALL SELECT 'PRECIOS' FROM DUAL UNION ALL
        SELECT 'INVENTARIO' FROM DUAL UNION ALL SELECT 'CLIENTES' FROM DUAL UNION ALL
        SELECT 'PROVEEDORES' FROM DUAL UNION ALL SELECT 'PROMOCIONES' FROM DUAL UNION ALL
        SELECT 'DESCUENTOS' FROM DUAL) a
  LEFT JOIN b ON b.BIT_AREA = a.AREA
 GROUP BY a.AREA
UNION ALL
SELECT 'Costo cambiado por la compra no es critico',
       CASE WHEN COUNT(*) > 0 AND MAX(BIT_ES_CRITICA) = 'N' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b WHERE BIT_TABLA = 'SGS_PRODUCTO' AND BIT_OPERACION = 'U'
UNION ALL
SELECT 'Existencias movidas por movimientos no son criticas',
       CASE WHEN COUNT(*) > 0 AND MAX(BIT_ES_CRITICA) = 'N' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b WHERE BIT_TABLA = 'SGS_EXISTENCIA'
UNION ALL
SELECT 'Pagos de cliente y proveedor son criticos',
       CASE WHEN COUNT(*) >= 2 AND MIN(BIT_ES_CRITICA) = 'S' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b WHERE BIT_TABLA IN ('SGS_PAGO_FACTURA_VENTA', 'SGS_PAGO_FACTURA_PROVEEDOR')
UNION ALL
SELECT 'Cambio de limite de credito es critico',
       CASE WHEN COUNT(*) > 0 AND MIN(b.BIT_ES_CRITICA) = 'S' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b JOIN SGS_BITACORA_DETALLE d ON d.BID_ID_BITACORA = b.BIT_ID
 WHERE d.BID_COLUMNA = 'CXC_LIMITE_CREDITO' AND b.BIT_OPERACION = 'U'
UNION ALL
SELECT 'Cambio de saldo por la venta no es critico',
       CASE WHEN COUNT(*) > 0 AND MAX(b.BIT_ES_CRITICA) = 'N' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b WHERE b.BIT_TABLA = 'SGS_CUENTA_COBRAR' AND b.BIT_OPERACION = 'U'
   AND NOT EXISTS (SELECT 1 FROM SGS_BITACORA_DETALLE d WHERE d.BID_ID_BITACORA = b.BIT_ID AND d.BID_COLUMNA = 'CXC_LIMITE_CREDITO')
UNION ALL
SELECT 'Cambio de telefono de proveedor no es critico',
       CASE WHEN COUNT(*) > 0 AND MAX(BIT_ES_CRITICA) = 'N' THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM b WHERE BIT_TABLA = 'SGS_PROVEEDOR' AND BIT_OPERACION = 'U'
UNION ALL
SELECT 'Sin errores en los triggers de auditoria',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FALLA' END, COUNT(*)
  FROM SGS_BITACORA_ERROR WHERE BER_PROGRAMA LIKE 'TRG_AUD%' AND BER_FECHA >= SYSTIMESTAMP - INTERVAL '30' MINUTE;

-- PARTE 3 (MODO MANUAL de commit; Option + X sobre las 6 sentencias): operaciones criticas hechas a mano
UPDATE SGS_FACTURA_VENTA SET FV_ESTADO = 'N' WHERE FV_ID = (SELECT MAX(FV_ID) FROM SGS_FACTURA_VENTA);
UPDATE SGS_PRODUCTO SET PRO_PRECIO_COSTO = PRO_PRECIO_COSTO + 100 WHERE PRO_CODIGO = 'ABA-001';
UPDATE SGS_EXISTENCIA SET EXI_CANTIDAD = EXI_CANTIDAD + 5 WHERE EXI_ID = (SELECT MIN(EXI_ID) FROM SGS_EXISTENCIA);
UPDATE SGS_PROVEEDOR SET PRV_ESTADO = 'I' WHERE PRV_CEDULA_JURIDICA = '3101100004';
UPDATE SGS_PROMOCION SET PRM_CANTIDAD_REQUERIDA = PRM_CANTIDAD_REQUERIDA + 1 WHERE PRM_ID = (SELECT MIN(PRM_ID) FROM SGS_PROMOCION);
DELETE FROM SGS_DESCUENTO_FAMILIA WHERE DSF_ID_DESCUENTO = (SELECT DSC_ID FROM SGS_DESCUENTO WHERE DSC_NOMBRE = 'Bebidas navidad');

-- PARTE 4 (Cmd + Enter): operaciones criticas de las ultimas 2 horas; correrla antes y despues del ROLLBACK
SELECT BIT_ID, BIT_AREA, BIT_TABLA, BIT_OPERACION, BIT_REGISTRO_ID, BID_COLUMNA, BID_VALOR_ANTERIOR, BID_VALOR_NUEVO, BIT_USUARIO_BD
  FROM SGS_VW_BITACORA_CRITICA
 WHERE BIT_FECHA >= SYSTIMESTAMP - INTERVAL '2' HOUR
 ORDER BY BIT_ID, BID_COLUMNA;

-- PARTE 5 (Cmd + Enter): deshace la parte 3 y su rastro
ROLLBACK;
