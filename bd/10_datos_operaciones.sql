-- 10_datos_operaciones.sql: datos de prueba de operaciones (compras, pagos, devoluciones, traslados y ventas), cargados con los packages.
-- Se ejecuta como SGS_ADMIN despues de los demas scripts. Los triggers mantienen saldos, existencias, movimientos e historial.
-- Seccion A: operaciones hechas durante las pruebas de B3. Seccion B: el resto. Seccion C: simulacion de fechas para B6.
-- Seccion D: historial de los procesos (premiaciones de semestres anteriores, cierres, descuentos y monitoreo).
-- Seccion E: operaciones que el sistema debe rechazar (quedan en la bitacora de errores). Al final se refrescan las vistas materializadas.

-- A. Operaciones de las pruebas de B3 (en una instalacion desde cero se ejecutan antes de la seccion B)
DECLARE
    v_id         NUMBER;
    v_f1         NUMBER;
    v_f2         NUMBER;
    v_nota       NUMBER;
    v_sin_pagos  SGS_PKG_VENTAS.t_pagos;
BEGIN
    -- Clienta nacional registrada desde el padron, con credito
    SGS_PKG_CLIENTES.registrar_nacional(p_cedula => '199990005', p_sexo => 'F', p_estado_civil => 'S',
                                        p_email => 'sgs.notificaciones.una+laura@gmail.com', p_id_cliente => v_id);
    SGS_PKG_CREDITO.asignar_credito(v_id, 150000);

    -- Cambio directo del costo del arroz (queda en el historial de precios)
    UPDATE SGS_PRODUCTO SET PRO_PRECIO_COSTO = 1550 WHERE PRO_CODIGO = 'ABA-001';
    COMMIT;

    -- Compras: a credito con cambio de costo del queso, y de contado
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100001', p_numero => 'LDV-1001', p_usuario => 'crodriguez', p_es_credito => 'S',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(
                        1 => SGS_PKG_COMPRAS.t_linea(codigo => 'LAC-001', cantidad => 200, costo => 650,  vencimiento => TRUNC(SYSDATE) + 20),
                        2 => SGS_PKG_COMPRAS.t_linea(codigo => 'LAC-002', cantidad => 50,  costo => 2300, vencimiento => TRUNC(SYSDATE) + 55)),
        p_id_factura => v_f1);
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100005', p_numero => 'DAS-2001', p_usuario => 'crodriguez', p_es_credito => 'N',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(
                        1 => SGS_PKG_COMPRAS.t_linea(codigo => 'ABA-001', cantidad => 100, costo => 1550, vencimiento => NULL),
                        2 => SGS_PKG_COMPRAS.t_linea(codigo => 'FRU-001', cantidad => 80,  costo => 400,  vencimiento => TRUNC(SYSDATE) + 10)),
        p_tipo_pago => 'Transferencia', p_id_factura => v_id);
    SGS_PKG_COMPRAS.registrar_pago(p_id_factura => v_f1, p_monto => 100000, p_tipo_pago => 'Transferencia');
    SGS_PKG_COMPRAS.registrar_devolucion(p_id_factura => v_f1,
        p_lineas => SGS_PKG_COMPRAS.t_lineas_devolucion(1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'LAC-002', cantidad => 10)),
        p_motivo => 'Empaque dañado', p_usuario => 'crodriguez', p_id_nota => v_nota);

    -- Segunda compra de leche y traslados por FEFO
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

    -- Ventas: de contado con dos medios de pago, y a credito con abonos y devolucion
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => NULL, p_es_credito => 'N',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LAC-001', cantidad => 5),
                                            2 => SGS_PKG_VENTAS.t_linea(codigo => 'LAC-002', cantidad => 1),
                                            3 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 2),
                                            4 => SGS_PKG_VENTAS.t_linea(codigo => 'Entrega a domicilio', cantidad => 1)),
        p_pagos  => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'Efectivo', monto => 5000),
                                           2 => SGS_PKG_VENTAS.t_pago(tipo => 'SINPE Movil', monto => 6682.44)),
        p_id_factura => v_id);
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990001', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LAC-001', cantidad => 20),
                                            2 => SGS_PKG_VENTAS.t_linea(codigo => 'FRU-001', cantidad => 10)),
        p_pagos  => v_sin_pagos, p_id_factura => v_f2);
    SGS_PKG_VENTAS.registrar_pago(v_f2, 5000, 'SINPE Movil');
    SGS_PKG_VENTAS.registrar_devolucion(v_f2, SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LAC-001', cantidad => 4)),
                                        'Leche en mal estado', 'mcastro', v_nota);
    SGS_PKG_VENTAS.registrar_pago(v_f2, 1000, 'Efectivo');
END;
/

-- B. Resto de las operaciones: completan 5 o mas filas por tabla y dejan los casos que demuestran los procesos de B6
--    (cliente cerca del 85 % de su credito, proveedor sobre el 70 %, cliente moroso, productos por vencer, vencidos y antiguos)
DECLARE
    v_id         NUMBER;
    v_factura    NUMBER;
    v_nota       NUMBER;
    v_sin_pagos  SGS_PKG_VENTAS.t_pagos;
BEGIN
    -- Compras a credito y de contado de los demas proveedores
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100002', p_numero => 'BT-3001', p_usuario => 'crodriguez', p_es_credito => 'S',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(
                        1 => SGS_PKG_COMPRAS.t_linea(codigo => 'BEB-001', cantidad => 300, costo => 900, vencimiento => TRUNC(SYSDATE) + 180),
                        2 => SGS_PKG_COMPRAS.t_linea(codigo => 'BEB-002', cantidad => 400, costo => 350, vencimiento => TRUNC(SYSDATE) + 300)),
        p_id_factura => v_factura);
    SGS_PKG_COMPRAS.registrar_pago(p_id_factura => v_factura, p_monto => 200000, p_tipo_pago => 'Cheque');
    SGS_PKG_COMPRAS.registrar_devolucion(p_id_factura => v_factura,
        p_lineas => SGS_PKG_COMPRAS.t_lineas_devolucion(1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'BEB-001', cantidad => 5)),
        p_motivo => 'Botellas golpeadas', p_usuario => 'crodriguez', p_id_nota => v_nota);

    -- Carne que vence en 5 dias: caso de producto proximo a vencer
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100003', p_numero => 'CLP-4001', p_usuario => 'crodriguez', p_es_credito => 'S',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'CAR-001', cantidad => 60, costo => 3800, vencimiento => TRUNC(SYSDATE) + 5)),
        p_id_factura => v_factura);
    SGS_PKG_COMPRAS.registrar_devolucion(p_id_factura => v_factura,
        p_lineas => SGS_PKG_COMPRAS.t_lineas_devolucion(1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'CAR-001', cantidad => 2)),
        p_motivo => 'Cadena de frio interrumpida', p_usuario => 'crodriguez', p_id_nota => v_nota);

    -- Detergente: su lote se simula con mas de 6 meses en bodega (seccion C)
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100004', p_numero => 'LT-5001', p_usuario => 'crodriguez', p_es_credito => 'N',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'LIM-001', cantidad => 100, costo => 1700, vencimiento => NULL)),
        p_tipo_pago => 'Transferencia', p_id_factura => v_factura);
    SGS_PKG_COMPRAS.registrar_devolucion(p_id_factura => v_factura,
        p_lineas => SGS_PKG_COMPRAS.t_lineas_devolucion(1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'LIM-001', cantidad => 3)),
        p_motivo => 'Bolsas rotas', p_usuario => 'crodriguez', p_id_nota => v_nota);

    -- Arroz a credito: deja la cuenta con la Distribuidora en 71 % de su limite (caso del aviso del 70 %)
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100005', p_numero => 'DAS-2002', p_usuario => 'crodriguez', p_es_credito => 'S',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'ABA-001', cantidad => 230, costo => 1550, vencimiento => NULL)),
        p_id_factura => v_factura);

    -- Banano: su lote se simula vencido (seccion C)
    SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3101100005', p_numero => 'DAS-2003', p_usuario => 'crodriguez', p_es_credito => 'N',
        p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'FRU-001', cantidad => 40, costo => 400, vencimiento => TRUNC(SYSDATE) + 2)),
        p_tipo_pago => 'Efectivo', p_id_factura => v_factura);

    -- Devolucion de contado a la Distribuidora (banano de la primera compra)
    SELECT FP_ID INTO v_factura FROM SGS_FACTURA_PROVEEDOR WHERE FP_NUMERO = 'DAS-2001';
    SGS_PKG_COMPRAS.registrar_devolucion(p_id_factura => v_factura,
        p_lineas => SGS_PKG_COMPRAS.t_lineas_devolucion(1 => SGS_PKG_COMPRAS.t_linea_devolucion(codigo => 'FRU-001', cantidad => 5)),
        p_motivo => 'Producto maduro', p_usuario => 'crodriguez', p_id_nota => v_nota);

    -- Traslados a las cuatro sucursales
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal San Isidro', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'CAR-001', cantidad => 40),
                                    2 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-001', cantidad => 50),
                                    3 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-002', cantidad => 50),
                                    4 => SGS_PKG_INVENTARIO.t_linea(codigo => 'LIM-001', cantidad => 20),
                                    5 => SGS_PKG_INVENTARIO.t_linea(codigo => 'ABA-001', cantidad => 30)), v_id);
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal Coto Brus', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'LIM-001', cantidad => 20),
                                    2 => SGS_PKG_INVENTARIO.t_linea(codigo => 'ABA-001', cantidad => 20),
                                    3 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-002', cantidad => 30)), v_id);
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal Palmar Norte', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-002', cantidad => 40),
                                    2 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-001', cantidad => 30)), v_id);
    SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal Buenos Aires', 'crodriguez',
        SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-001', cantidad => 60)), v_id);

    -- Venta a credito a Jose: su pago se simula de hace 45 dias (caso de cliente moroso, seccion C)
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990004', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LAC-001', cantidad => 10),
                                            2 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 5)),
        p_pagos => v_sin_pagos, p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_pago(v_factura, 3000, 'Efectivo');

    -- Venta a credito a Laura: deja su cuenta en 86 % de su limite (caso del aviso del 85 %)
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990005', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'CAR-001', cantidad => 30)),
        p_pagos => v_sin_pagos, p_id_factura => v_factura);

    -- Ventas de contado en las otras sucursales (cajeros distintos para el cierre diario); el pago sin monto cubre el total
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal Buenos Aires', p_usuario => 'amonge', p_cliente => NULL, p_es_credito => 'N',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-001', cantidad => 6)),
        p_pagos  => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'Efectivo', monto => NULL)),
        p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_devolucion(v_factura, SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-001', cantidad => 1)),
                                        'Botella sin sello', 'amonge', v_nota);

    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal Coto Brus', p_usuario => 'drojas', p_cliente => '155812345678', p_es_credito => 'N',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LIM-001', cantidad => 2),
                                            2 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 1)),
        p_pagos  => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'Tarjeta', monto => NULL)),
        p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_devolucion(v_factura, SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'LIM-001', cantidad => 1)),
                                        'Producto equivocado', 'drojas', v_nota);

    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal Palmar Norte', p_usuario => 'sjimenez', p_cliente => '199990002', p_es_credito => 'N',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-002', cantidad => 8)),
        p_pagos  => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'SINPE Movil', monto => NULL)),
        p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_devolucion(v_factura, SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-002', cantidad => 2)),
                                        'Cliente cambio de opinion', 'sjimenez', v_nota);

    -- Ventas a credito a la empresa y a Carlos
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal Buenos Aires', p_usuario => 'amonge', p_cliente => '3101654321', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'BEB-001', cantidad => 20)),
        p_pagos => v_sin_pagos, p_id_factura => v_factura);
    SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990002', p_es_credito => 'S',
        p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 3)),
        p_pagos => v_sin_pagos, p_id_factura => v_factura);

    -- Devolucion de un arroz de la primera venta de contado
    SELECT MIN(f.FV_ID) INTO v_factura
      FROM SGS_FACTURA_VENTA f JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
     WHERE c.CLI_ES_DEFECTO = 'S' AND f.FV_ES_CREDITO = 'N';
    SGS_PKG_VENTAS.registrar_devolucion(v_factura, SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 1)),
                                        'Empaque roto', 'mcastro', v_nota);
END;
/

-- C. Simulacion de fechas para demostrar los procesos de B6
-- Los packages registran todo con la fecha del dia (como en la operacion real); aqui se envejecen solo estos registros de prueba
-- Cliente moroso: factura de hace 60 dias y ultimo pago de hace 45 (mas de un mes)
UPDATE SGS_FACTURA_VENTA
   SET FV_FECHA = TRUNC(SYSDATE) - 60
 WHERE FV_ID = (SELECT MAX(f.FV_ID) FROM SGS_FACTURA_VENTA f JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
                 WHERE c.CLI_CEDULA = '199990004' AND f.FV_ES_CREDITO = 'S');
UPDATE SGS_PAGO_FACTURA_VENTA
   SET PFV_FECHA = TRUNC(SYSDATE) - 45
 WHERE PFV_ID_FACTURA = (SELECT MAX(f.FV_ID) FROM SGS_FACTURA_VENTA f JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
                          WHERE c.CLI_CEDULA = '199990004' AND f.FV_ES_CREDITO = 'S');
-- Producto con mas de 6 meses en bodega: el detergente ingreso hace 7 meses
UPDATE SGS_FACTURA_PROVEEDOR SET FP_FECHA = ADD_MONTHS(TRUNC(SYSDATE), -7) WHERE FP_NUMERO = 'LT-5001';
UPDATE SGS_LOTE
   SET LOT_FECHA_INGRESO = ADD_MONTHS(TRUNC(SYSDATE), -7)
 WHERE LOT_ID = (SELECT l.LOT_ID FROM SGS_LOTE l
                   JOIN SGS_DETALLE_FACTURA_PROVEEDOR d ON d.DFP_ID = l.LOT_ID_DETALLE_COMPRA
                   JOIN SGS_FACTURA_PROVEEDOR f ON f.FP_ID = d.DFP_ID_FACTURA
                  WHERE f.FP_NUMERO = 'LT-5001');
-- Producto vencido: el segundo lote de banano ingreso hace 15 dias y vencio hace 3
UPDATE SGS_FACTURA_PROVEEDOR SET FP_FECHA = TRUNC(SYSDATE) - 15 WHERE FP_NUMERO = 'DAS-2003';
UPDATE SGS_LOTE
   SET LOT_FECHA_INGRESO = TRUNC(SYSDATE) - 15,
       LOT_FECHA_VENCIMIENTO = TRUNC(SYSDATE) - 3
 WHERE LOT_ID = (SELECT l.LOT_ID FROM SGS_LOTE l
                   JOIN SGS_DETALLE_FACTURA_PROVEEDOR d ON d.DFP_ID = l.LOT_ID_DETALLE_COMPRA
                   JOIN SGS_FACTURA_PROVEEDOR f ON f.FP_ID = d.DFP_ID_FACTURA
                  WHERE f.FP_NUMERO = 'DAS-2003');
COMMIT;

-- D. Historial de los procesos (5 filas o mas en las tablas que llenan los procesos de B6 y B8)
--    Ventas de servicios de semestres anteriores (no mueven inventario) para que cada premiacion tenga sus ganadores.
--    Cambiar la fecha de una factura queda en la bitacora como operacion critica, igual que en la seccion C.
DECLARE
    v_jose  DATE;

    PROCEDURE vender_historico (p_cliente IN VARCHAR2, p_servicio IN VARCHAR2, p_cantidad IN NUMBER, p_meses IN NUMBER) IS
        v_factura  NUMBER;
        v_fecha    DATE := ADD_MONTHS(TRUNC(SYSDATE), -p_meses);
    BEGIN
        SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => p_cliente,
            p_es_credito => 'N',
            p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => p_servicio, cantidad => p_cantidad)),
            p_pagos  => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'Efectivo', monto => NULL)),
            p_id_factura => v_factura);
        UPDATE SGS_FACTURA_VENTA SET FV_FECHA = v_fecha WHERE FV_ID = v_factura;
        UPDATE SGS_PAGO_FACTURA_VENTA SET PFV_FECHA = v_fecha WHERE PFV_ID_FACTURA = v_factura;
        COMMIT;
    END;
BEGIN
    -- Laura se registro con el package (fecha de ingreso de hoy); como los demas clientes de prueba, es cliente desde antes
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2024-03-10' WHERE CLI_CEDULA = '199990005';
    COMMIT;

    -- Dos ventas por semestre, hace 26, 20, 14 y 8 meses
    vender_historico('199990001', 'Recarga telefonica', 25, 26);
    vender_historico('199990004', 'Entrega a domicilio', 10, 26);
    vender_historico('199990002', 'Envio de encomiendas', 12, 20);
    vender_historico('3101654321', 'Entrega a domicilio', 30, 20);
    vender_historico('199990001', 'Envio de encomiendas', 8, 14);
    vender_historico('155812345678', 'Recarga telefonica', 15, 14);
    vender_historico('199990002', 'Recarga telefonica', 40, 8);
    vender_historico('199990004', 'Envio de encomiendas', 5, 8);

    -- Premiaciones semestrales: las cuatro anteriores con su fecha de corte y la de hoy
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -24));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -18));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -12));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -6));
    SGS_PKG_PROCESOS.premiar_clientes;

    -- Productos que hoy cumplen los descuentos por antiguedad y por vencimiento
    SGS_PKG_PROCESOS.incluir_descuentos;

    -- Cierres: hoy (las ventas de la seccion B), el dia de la venta a Jose (seccion C) y los tres dias anteriores
    SELECT MIN(f.FV_FECHA) INTO v_jose
      FROM SGS_FACTURA_VENTA f JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
     WHERE c.CLI_CEDULA = '199990004' AND f.FV_ES_CREDITO = 'S';
    SGS_PKG_PROCESOS.cerrar_dia(v_jose);
    SGS_PKG_PROCESOS.cerrar_dia(TRUNC(SYSDATE) - 3);
    SGS_PKG_PROCESOS.cerrar_dia(TRUNC(SYSDATE) - 2);
    SGS_PKG_PROCESOS.cerrar_dia(TRUNC(SYSDATE) - 1);
    SGS_PKG_PROCESOS.cerrar_dia(TRUNC(SYSDATE));

    -- Revisiones de monitoreo (en operacion las hace el job una vez al dia)
    FOR i IN 1 .. 5 LOOP
        SGS_PKG_MONITOREO.registrar_estado;
    END LOOP;
END;
/

-- E. Operaciones que el sistema debe rechazar: cada rechazo queda en SGS_BITACORA_ERROR con el programa que lo detecto
DECLARE
    v_id         NUMBER;
    v_laura      NUMBER;
    v_sin_pagos  SGS_PKG_VENTAS.t_pagos;
BEGIN
    -- Venta a credito que supera el limite de Laura (ya usa el 86 %)
    BEGIN
        SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Sucursal San Isidro', p_usuario => 'mcastro', p_cliente => '199990005',
            p_es_credito => 'S', p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 20)),
            p_pagos => v_sin_pagos, p_id_factura => v_id);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    -- Traslado de mas unidades de las que hay en la bodega
    BEGIN
        SGS_PKG_INVENTARIO.trasladar('Bodega Central', 'Sucursal San Isidro', 'crodriguez',
            SGS_PKG_INVENTARIO.t_lineas(1 => SGS_PKG_INVENTARIO.t_linea(codigo => 'BEB-001', cantidad => 100000)), v_id);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    -- Cliente nacional con una cedula que no esta en el padron
    BEGIN
        SGS_PKG_CLIENTES.registrar_nacional(p_cedula => '999999999', p_sexo => 'M', p_id_cliente => v_id);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    -- Compra a un proveedor que no existe
    BEGIN
        SGS_PKG_COMPRAS.registrar_compra(p_proveedor => '3109999999', p_numero => 'XX-0001', p_usuario => 'crodriguez',
            p_es_credito => 'N',
            p_lineas => SGS_PKG_COMPRAS.t_lineas(1 => SGS_PKG_COMPRAS.t_linea(codigo => 'ABA-001', cantidad => 10, costo => 1550,
                                                                              vencimiento => NULL)),
            p_id_factura => v_id);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    -- Limite de credito menor a lo que el cliente ya debe
    SELECT CLI_ID INTO v_laura FROM SGS_CLIENTE WHERE CLI_CEDULA = '199990005';
    BEGIN
        SGS_PKG_CREDITO.asignar_credito(v_laura, 1000);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    -- Venta en la Bodega Central (solo abastece a las sucursales)
    BEGIN
        SGS_PKG_VENTAS.registrar_venta(p_sucursal => 'Bodega Central', p_usuario => 'crodriguez', p_cliente => NULL,
            p_es_credito => 'N', p_lineas => SGS_PKG_VENTAS.t_lineas(1 => SGS_PKG_VENTAS.t_linea(codigo => 'ABA-001', cantidad => 1)),
            p_pagos => SGS_PKG_VENTAS.t_pagos(1 => SGS_PKG_VENTAS.t_pago(tipo => 'Efectivo', monto => NULL)),
            p_id_factura => v_id);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
END;
/

-- Vistas materializadas al dia con todos los datos cargados (en operacion las refresca su job a las 00:30)
BEGIN
    DBMS_MVIEW.REFRESH('SGS_MV_VENTAS_MENSUALES,SGS_MV_INVENTARIO_CONSOLIDADO', 'CC');
END;
/
