DECLARE
    v_cierre  DATE;
    v_jose    DATE;
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
    INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
    VALUES (SEQ_DESTINATARIO.NEXTVAL, 'COORDINADOR', 'Coordinacion de sucursales', 'sgs.notificaciones.una+sucursales@gmail.com');
    INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
    VALUES (SEQ_DESTINATARIO.NEXTVAL, 'DBA', 'Soporte de base de datos', 'sgs.notificaciones.una+soporte@gmail.com');
    INSERT INTO SGS_DESCUENTO (DSC_ID, DSC_NOMBRE, DSC_TIPO_CRITERIO, DSC_PORCENTAJE, DSC_DIAS_PARA_VENCER, DSC_FECHA_INICIO)
    VALUES (SEQ_DESCUENTO.NEXTVAL, 'Perecederos a 21 dias', 'VENCIMIENTO', 0.15, 21, DATE '2026-10-01');
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2023-01-01' WHERE CLI_ES_DEFECTO = 'S';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2023-02-10' WHERE CLI_CEDULA = '199990001';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2023-03-05' WHERE CLI_CEDULA = '199990002';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2023-04-18' WHERE CLI_CEDULA = '199990003';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2023-01-20' WHERE CLI_CEDULA = '199990004';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2024-03-10' WHERE CLI_CEDULA = '199990005';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2024-05-02' WHERE CLI_CEDULA = '155812345678';
    UPDATE SGS_CLIENTE SET CLI_FECHA_INGRESO = DATE '2024-02-25' WHERE CLI_CEDULA = '3101654321';
    COMMIT;
    vender_historico('199990001', 'Recarga telefonica', 25, 26);
    vender_historico('199990004', 'Entrega a domicilio', 10, 26);
    vender_historico('199990002', 'Envio de encomiendas', 12, 20);
    vender_historico('3101654321', 'Entrega a domicilio', 30, 20);
    vender_historico('199990001', 'Envio de encomiendas', 8, 14);
    vender_historico('155812345678', 'Recarga telefonica', 15, 14);
    vender_historico('199990002', 'Recarga telefonica', 40, 8);
    vender_historico('199990004', 'Envio de encomiendas', 5, 8);
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -24));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -18));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -12));
    SGS_PKG_PROCESOS.premiar_clientes(ADD_MONTHS(TRUNC(SYSDATE), -6));
    SGS_PKG_PROCESOS.incluir_descuentos;
    SELECT MIN(CIE_FECHA) INTO v_cierre FROM SGS_CIERRE_DIARIO;
    SELECT MIN(f.FV_FECHA) INTO v_jose
      FROM SGS_FACTURA_VENTA f JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
     WHERE c.CLI_CEDULA = '199990004' AND f.FV_ES_CREDITO = 'S';
    SGS_PKG_PROCESOS.cerrar_dia(v_jose);
    SGS_PKG_PROCESOS.cerrar_dia(v_cierre - 3);
    SGS_PKG_PROCESOS.cerrar_dia(v_cierre - 2);
    SGS_PKG_PROCESOS.cerrar_dia(v_cierre - 1);
    FOR i IN 1 .. 3 LOOP
        SGS_PKG_MONITOREO.registrar_estado;
    END LOOP;
END;
