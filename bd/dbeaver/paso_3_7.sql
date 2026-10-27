CREATE OR REPLACE TRIGGER TRG_DNCV_VALIDA
BEFORE INSERT ON SGS_DETALLE_NOTA_CREDITO_VENTA
FOR EACH ROW
DECLARE
    v_vendida        SGS_DETALLE_FACTURA_VENTA.DFV_CANTIDAD%TYPE;
    v_factura_linea  SGS_DETALLE_FACTURA_VENTA.DFV_ID_FACTURA%TYPE;
    v_factura_nota   SGS_NOTA_CREDITO_VENTA.NCV_ID_FACTURA%TYPE;
    v_devuelta       NUMBER;
BEGIN
    SELECT DFV_CANTIDAD, DFV_ID_FACTURA
      INTO v_vendida, v_factura_linea
      FROM SGS_DETALLE_FACTURA_VENTA
     WHERE DFV_ID = :NEW.DNCV_ID_DETALLE_FACTURA;
    SELECT NCV_ID_FACTURA
      INTO v_factura_nota
      FROM SGS_NOTA_CREDITO_VENTA
     WHERE NCV_ID = :NEW.DNCV_ID_NOTA;
    IF v_factura_linea <> v_factura_nota THEN
        RAISE_APPLICATION_ERROR(-20111, 'La linea devuelta no pertenece a la factura de la nota de credito');
    END IF;
    SELECT NVL(SUM(DNCV_CANTIDAD), 0)
      INTO v_devuelta
      FROM SGS_DETALLE_NOTA_CREDITO_VENTA
     WHERE DNCV_ID_DETALLE_FACTURA = :NEW.DNCV_ID_DETALLE_FACTURA;
    IF v_devuelta + :NEW.DNCV_CANTIDAD > v_vendida THEN
        RAISE_APPLICATION_ERROR(-20110, 'No se puede devolver mas de lo vendido (vendido ' || v_vendida
                                        || ', ya devuelto ' || v_devuelta || ')');
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        NULL;
END;

CREATE OR REPLACE PACKAGE SGS_PKG_VENTAS AS
    TYPE t_linea IS RECORD (codigo VARCHAR2(100), cantidad NUMBER);
    TYPE t_lineas IS TABLE OF t_linea INDEX BY PLS_INTEGER;
    TYPE t_pago IS RECORD (tipo VARCHAR2(50), monto NUMBER);
    TYPE t_pagos IS TABLE OF t_pago INDEX BY PLS_INTEGER;
    PROCEDURE registrar_venta (p_sucursal   IN  VARCHAR2,
                               p_usuario    IN  VARCHAR2,
                               p_cliente    IN  VARCHAR2,
                               p_es_credito IN  VARCHAR2,
                               p_lineas     IN  t_lineas,
                               p_pagos      IN  t_pagos,
                               p_id_factura OUT NUMBER);
    PROCEDURE registrar_pago (p_id_factura IN NUMBER,
                              p_monto      IN NUMBER,
                              p_tipo_pago  IN VARCHAR2 DEFAULT 'Efectivo');
    PROCEDURE registrar_devolucion (p_id_factura IN  NUMBER,
                                    p_lineas     IN  t_lineas,
                                    p_motivo     IN  VARCHAR2,
                                    p_usuario    IN  VARCHAR2,
                                    p_id_nota    OUT NUMBER);
END;

CREATE OR REPLACE PACKAGE BODY SGS_PKG_VENTAS AS
    TYPE t_calculo IS RECORD (id_articulo NUMBER, id_producto NUMBER, cantidad NUMBER, precio NUMBER,
                              descuento NUMBER, impuesto NUMBER, total NUMBER);
    TYPE t_calculos IS TABLE OF t_calculo INDEX BY PLS_INTEGER;
    FUNCTION id_usuario (p_username IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_USUARIO.USU_ID%TYPE;
    BEGIN
        SELECT USU_ID INTO v_id FROM SGS_USUARIO WHERE USU_USERNAME = LOWER(p_username) AND USU_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20112, 'No existe o no esta activo el usuario ' || p_username);
    END;
    FUNCTION id_tipo_pago (p_nombre IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_TIPO_PAGO.TPA_ID%TYPE;
    BEGIN
        SELECT TPA_ID INTO v_id FROM SGS_TIPO_PAGO WHERE TPA_NOMBRE = p_nombre AND TPA_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20113, 'No existe el tipo de pago ' || p_nombre);
    END;
    FUNCTION calcular_linea (p_codigo IN VARCHAR2, p_cantidad IN NUMBER, p_id_sucursal IN NUMBER) RETURN t_calculo IS
        v_c       t_calculo;
        v_costo   NUMBER;
        v_util    NUMBER;
        v_pct_dsc NUMBER;
        v_pct_imp NUMBER;
        v_bruto   NUMBER;
    BEGIN
        v_c.cantidad := p_cantidad;
        BEGIN
            SELECT p.PRO_ID_ARTICULO, v.PRO_ID, v.PRO_PRECIO_COSTO, v.PS_PCT_UTILIDAD, v.PCT_DESCUENTO, v.ART_PCT_IMPUESTO
              INTO v_c.id_articulo, v_c.id_producto, v_costo, v_util, v_pct_dsc, v_pct_imp
              FROM SGS_VW_PRECIO_VENTA v
              JOIN SGS_PRODUCTO p ON p.PRO_ID = v.PRO_ID
             WHERE v.PRO_CODIGO = p_codigo
               AND v.SUC_ID = p_id_sucursal;
            v_c.precio := ROUND(v_costo * (1 + v_util), 2);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                BEGIN
                    SELECT a.ART_ID, s.SER_PRECIO, a.ART_PCT_IMPUESTO
                      INTO v_c.id_articulo, v_c.precio, v_pct_imp
                      FROM SGS_SERVICIO s
                      JOIN SGS_ARTICULO_FACTURABLE a ON a.ART_ID = s.SER_ID_ARTICULO
                     WHERE a.ART_NOMBRE = p_codigo
                       AND a.ART_ESTADO = 'A';
                    v_c.id_producto := NULL;
                    v_pct_dsc := 0;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        RAISE_APPLICATION_ERROR(-20102, 'El articulo ' || p_codigo || ' no existe, no esta activo o no se vende en esta sucursal');
                END;
        END;
        v_bruto       := ROUND(v_c.precio * p_cantidad, 2);
        v_c.descuento := ROUND(v_bruto * v_pct_dsc, 2);
        v_c.impuesto  := ROUND((v_bruto - v_c.descuento) * v_pct_imp, 2);
        v_c.total     := v_bruto - v_c.descuento + v_c.impuesto;
        RETURN v_c;
    END;
    PROCEDURE registrar_venta (p_sucursal   IN  VARCHAR2,
                               p_usuario    IN  VARCHAR2,
                               p_cliente    IN  VARCHAR2,
                               p_es_credito IN  VARCHAR2,
                               p_lineas     IN  t_lineas,
                               p_pagos      IN  t_pagos,
                               p_id_factura OUT NUMBER) IS
        v_sucursal     SGS_SUCURSAL.SUC_ID%TYPE;
        v_es_central   SGS_SUCURSAL.SUC_ES_CENTRAL%TYPE;
        v_usuario      SGS_USUARIO.USU_ID%TYPE;
        v_cliente      SGS_CLIENTE.CLI_ID%TYPE;
        v_cuenta       SGS_CUENTA_COBRAR.CXC_ID%TYPE;
        v_calculos     t_calculos;
        v_subtotal     NUMBER := 0;
        v_descuento    NUMBER := 0;
        v_impuesto     NUMBER := 0;
        v_total        NUMBER;
        v_pagado       NUMBER := 0;
        v_tipo_pago    SGS_TIPO_PAGO.TPA_ID%TYPE;
        v_dfv_id       SGS_DETALLE_FACTURA_VENTA.DFV_ID%TYPE;
        v_asignaciones SGS_PKG_INVENTARIO.t_asignaciones;
        v_i            PLS_INTEGER;
        v_n            PLS_INTEGER := 0;
        e_espera       EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
    BEGIN
        SAVEPOINT sp_registrar_venta;
        IF p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20105, 'La venta no tiene lineas');
        END IF;
        BEGIN
            SELECT SUC_ID, SUC_ES_CENTRAL INTO v_sucursal, v_es_central FROM SGS_SUCURSAL WHERE SUC_NOMBRE = p_sucursal;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20106, 'No existe la sucursal ' || p_sucursal);
        END;
        IF v_es_central = 'S' THEN
            RAISE_APPLICATION_ERROR(-20100, 'La bodega central no vende: el inventario se traslada a las sucursales');
        END IF;
        v_usuario := id_usuario(p_usuario);
        BEGIN
            IF p_cliente IS NULL THEN
                SELECT CLI_ID INTO v_cliente FROM SGS_CLIENTE WHERE CLI_ES_DEFECTO = 'S';
            ELSE
                SELECT CLI_ID INTO v_cliente FROM SGS_CLIENTE WHERE CLI_CEDULA = p_cliente;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20101, 'No existe el cliente ' || NVL(p_cliente, 'por defecto'));
        END;
        IF p_es_credito = 'S' THEN
            IF p_pagos.COUNT > 0 THEN
                RAISE_APPLICATION_ERROR(-20114, 'Una venta a credito no lleva pagos: se abona despues con registrar_pago');
            END IF;
            SELECT CXC_ID INTO v_cuenta
              FROM SGS_CUENTA_COBRAR
             WHERE CXC_ID_CLIENTE = v_cliente
               FOR UPDATE WAIT 5;
        END IF;
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            v_n := v_n + 1;
            v_calculos(v_n) := calcular_linea(p_lineas(v_i).codigo, p_lineas(v_i).cantidad, v_sucursal);
            v_subtotal  := v_subtotal + ROUND(v_calculos(v_n).precio * v_calculos(v_n).cantidad, 2);
            v_descuento := v_descuento + v_calculos(v_n).descuento;
            v_impuesto  := v_impuesto + v_calculos(v_n).impuesto;
            v_i := p_lineas.NEXT(v_i);
        END LOOP;
        v_total := v_subtotal - v_descuento + v_impuesto;
        IF p_es_credito = 'N' THEN
            v_i := p_pagos.FIRST;
            WHILE v_i IS NOT NULL LOOP
                v_pagado := v_pagado + p_pagos(v_i).monto;
                v_i := p_pagos.NEXT(v_i);
            END LOOP;
            IF v_pagado <> v_total THEN
                RAISE_APPLICATION_ERROR(-20104, 'Los pagos (' || v_pagado || ') no suman el total de la factura (' || v_total || ')');
            END IF;
        END IF;
        INSERT INTO SGS_FACTURA_VENTA (FV_ID, FV_ID_CLIENTE, FV_ID_SUCURSAL, FV_ID_USUARIO, FV_SUBTOTAL, FV_DESCUENTO,
                                       FV_IMPUESTO, FV_TOTAL, FV_ES_CREDITO, FV_ESTADO)
        VALUES (SEQ_FACTURA_VENTA.NEXTVAL, v_cliente, v_sucursal, v_usuario, v_subtotal, v_descuento,
                v_impuesto, v_total, p_es_credito, CASE WHEN p_es_credito = 'S' THEN 'P' ELSE 'C' END)
        RETURNING FV_ID INTO p_id_factura;
        FOR j IN 1 .. v_calculos.COUNT LOOP
            INSERT INTO SGS_DETALLE_FACTURA_VENTA (DFV_ID, DFV_ID_FACTURA, DFV_ID_ARTICULO, DFV_CANTIDAD, DFV_PRECIO_UNITARIO,
                                                   DFV_DESCUENTO, DFV_IMPUESTO, DFV_SUBTOTAL)
            VALUES (SEQ_DETALLE_FACTURA_VENTA.NEXTVAL, p_id_factura, v_calculos(j).id_articulo, v_calculos(j).cantidad,
                    v_calculos(j).precio, v_calculos(j).descuento, v_calculos(j).impuesto, v_calculos(j).total)
            RETURNING DFV_ID INTO v_dfv_id;
            IF v_calculos(j).id_producto IS NOT NULL THEN
                v_asignaciones := SGS_PKG_INVENTARIO.reservar_fefo(v_sucursal, v_calculos(j).id_producto, v_calculos(j).cantidad);
                FOR k IN 1 .. v_asignaciones.COUNT LOOP
                    INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_VENTA)
                    VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, v_asignaciones(k).id_lote, v_sucursal, 'VENTA',
                            v_asignaciones(k).cantidad, v_dfv_id);
                END LOOP;
            END IF;
        END LOOP;
        v_i := p_pagos.FIRST;
        WHILE v_i IS NOT NULL LOOP
            v_tipo_pago := id_tipo_pago(p_pagos(v_i).tipo);
            INSERT INTO SGS_PAGO_FACTURA_VENTA (PFV_ID, PFV_ID_FACTURA, PFV_ID_TIPO_PAGO, PFV_MONTO)
            VALUES (SEQ_PAGO_FACTURA_VENTA.NEXTVAL, p_id_factura, v_tipo_pago, p_pagos(v_i).monto);
            v_i := p_pagos.NEXT(v_i);
        END LOOP;
        FOR r IN (SELECT pr.PRM_ID, SUM(dv.DFV_CANTIDAD) AS PATROCINADORES,
                         FLOOR(SUM(dv.DFV_CANTIDAD) / pr.PRM_CANTIDAD_REQUERIDA) * pr.PRM_CANTIDAD_ACCIONES AS ACCIONES
                    FROM SGS_DETALLE_FACTURA_VENTA dv
                    JOIN SGS_PRODUCTO p ON p.PRO_ID_ARTICULO = dv.DFV_ID_ARTICULO
                    JOIN SGS_PROMOCION_PRODUCTO pp ON pp.PP_ID_PRODUCTO = p.PRO_ID
                    JOIN SGS_PROMOCION pr ON pr.PRM_ID = pp.PP_ID_PROMOCION
                   WHERE dv.DFV_ID_FACTURA = p_id_factura
                     AND pr.PRM_ESTADO = 'A'
                     AND pr.PRM_FECHA_INICIO <= SYSDATE
                     AND (pr.PRM_FECHA_FIN IS NULL OR pr.PRM_FECHA_FIN >= TRUNC(SYSDATE))
                   GROUP BY pr.PRM_ID, pr.PRM_CANTIDAD_REQUERIDA, pr.PRM_CANTIDAD_ACCIONES) LOOP
            IF r.ACCIONES > 0 THEN
                INSERT INTO SGS_ACCION_OTORGADA (ACO_ID, ACO_ID_FACTURA, ACO_ID_PROMOCION, ACO_CANTIDAD_PRODUCTOS, ACO_CANTIDAD_ACCIONES)
                VALUES (SEQ_ACCION_OTORGADA.NEXTVAL, p_id_factura, r.PRM_ID, r.PATROCINADORES, r.ACCIONES);
            END IF;
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_venta;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_venta');
            RAISE_APPLICATION_ERROR(-20103, 'La cuenta del cliente la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_venta;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_venta');
            RAISE;
    END;
    PROCEDURE registrar_pago (p_id_factura IN NUMBER,
                              p_monto      IN NUMBER,
                              p_tipo_pago  IN VARCHAR2 DEFAULT 'Efectivo') IS
        v_credito   SGS_FACTURA_VENTA.FV_ES_CREDITO%TYPE;
        v_estado    SGS_FACTURA_VENTA.FV_ESTADO%TYPE;
        v_cliente   SGS_FACTURA_VENTA.FV_ID_CLIENTE%TYPE;
        v_cuenta    SGS_CUENTA_COBRAR.CXC_ID%TYPE;
        v_tipo_pago SGS_TIPO_PAGO.TPA_ID%TYPE;
        e_espera    EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
    BEGIN
        SAVEPOINT sp_registrar_pago;
        BEGIN
            SELECT FV_ES_CREDITO, FV_ESTADO, FV_ID_CLIENTE INTO v_credito, v_estado, v_cliente
              FROM SGS_FACTURA_VENTA WHERE FV_ID = p_id_factura;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20107, 'No existe la factura de venta ' || p_id_factura);
        END;
        IF v_credito <> 'S' OR v_estado <> 'P' THEN
            RAISE_APPLICATION_ERROR(-20108, 'La factura ' || p_id_factura || ' no tiene saldo pendiente');
        END IF;
        SELECT CXC_ID INTO v_cuenta
          FROM SGS_CUENTA_COBRAR
         WHERE CXC_ID_CLIENTE = v_cliente
           FOR UPDATE WAIT 5;
        v_tipo_pago := id_tipo_pago(p_tipo_pago);
        INSERT INTO SGS_PAGO_FACTURA_VENTA (PFV_ID, PFV_ID_FACTURA, PFV_ID_TIPO_PAGO, PFV_MONTO)
        VALUES (SEQ_PAGO_FACTURA_VENTA.NEXTVAL, p_id_factura, v_tipo_pago, p_monto);
        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_pago;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_pago');
            RAISE_APPLICATION_ERROR(-20103, 'La cuenta del cliente la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_pago;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_pago');
            RAISE;
    END;
    PROCEDURE registrar_devolucion (p_id_factura IN  NUMBER,
                                    p_lineas     IN  t_lineas,
                                    p_motivo     IN  VARCHAR2,
                                    p_usuario    IN  VARCHAR2,
                                    p_id_nota    OUT NUMBER) IS
        v_estado    SGS_FACTURA_VENTA.FV_ESTADO%TYPE;
        v_credito   SGS_FACTURA_VENTA.FV_ES_CREDITO%TYPE;
        v_cliente   SGS_FACTURA_VENTA.FV_ID_CLIENTE%TYPE;
        v_sucursal  SGS_FACTURA_VENTA.FV_ID_SUCURSAL%TYPE;
        v_usuario   SGS_USUARIO.USU_ID%TYPE;
        v_cuenta    SGS_CUENTA_COBRAR.CXC_ID%TYPE;
        v_dfv_id    SGS_DETALLE_FACTURA_VENTA.DFV_ID%TYPE;
        v_vendida   SGS_DETALLE_FACTURA_VENTA.DFV_CANTIDAD%TYPE;
        v_total_lin SGS_DETALLE_FACTURA_VENTA.DFV_SUBTOTAL%TYPE;
        v_monto     NUMBER := 0;
        v_monto_lin NUMBER;
        v_dncv_id   SGS_DETALLE_NOTA_CREDITO_VENTA.DNCV_ID%TYPE;
        v_pendiente NUMBER;
        v_toma      NUMBER;
        v_i         PLS_INTEGER;
        e_espera    EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
        PROCEDURE buscar_linea (p_codigo IN VARCHAR2) IS
        BEGIN
            SELECT dv.DFV_ID, dv.DFV_CANTIDAD, dv.DFV_SUBTOTAL
              INTO v_dfv_id, v_vendida, v_total_lin
              FROM SGS_DETALLE_FACTURA_VENTA dv
              JOIN SGS_ARTICULO_FACTURABLE a ON a.ART_ID = dv.DFV_ID_ARTICULO
              LEFT JOIN SGS_PRODUCTO p ON p.PRO_ID_ARTICULO = a.ART_ID
             WHERE dv.DFV_ID_FACTURA = p_id_factura
               AND (p.PRO_CODIGO = p_codigo OR a.ART_NOMBRE = p_codigo);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20109, 'El articulo ' || p_codigo || ' no esta en la factura ' || p_id_factura);
        END;
    BEGIN
        SAVEPOINT sp_registrar_devolucion;
        BEGIN
            SELECT FV_ESTADO, FV_ES_CREDITO, FV_ID_CLIENTE, FV_ID_SUCURSAL INTO v_estado, v_credito, v_cliente, v_sucursal
              FROM SGS_FACTURA_VENTA WHERE FV_ID = p_id_factura;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20107, 'No existe la factura de venta ' || p_id_factura);
        END;
        v_usuario := id_usuario(p_usuario);
        IF v_credito = 'S' AND v_estado = 'P' THEN
            SELECT CXC_ID INTO v_cuenta
              FROM SGS_CUENTA_COBRAR
             WHERE CXC_ID_CLIENTE = v_cliente
               FOR UPDATE WAIT 5;
        END IF;
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            buscar_linea(p_lineas(v_i).codigo);
            v_monto := v_monto + ROUND(v_total_lin * p_lineas(v_i).cantidad / v_vendida, 2);
            v_i := p_lineas.NEXT(v_i);
        END LOOP;
        INSERT INTO SGS_NOTA_CREDITO_VENTA (NCV_ID, NCV_ID_FACTURA, NCV_ID_USUARIO, NCV_MOTIVO, NCV_MONTO)
        VALUES (SEQ_NOTA_CREDITO_VENTA.NEXTVAL, p_id_factura, v_usuario, p_motivo, v_monto)
        RETURNING NCV_ID INTO p_id_nota;
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            buscar_linea(p_lineas(v_i).codigo);
            v_monto_lin := ROUND(v_total_lin * p_lineas(v_i).cantidad / v_vendida, 2);
            INSERT INTO SGS_DETALLE_NOTA_CREDITO_VENTA (DNCV_ID, DNCV_ID_NOTA, DNCV_ID_DETALLE_FACTURA, DNCV_CANTIDAD, DNCV_SUBTOTAL)
            VALUES (SEQ_DETALLE_NOTA_CREDITO_VENTA.NEXTVAL, p_id_nota, v_dfv_id, p_lineas(v_i).cantidad, v_monto_lin)
            RETURNING DNCV_ID INTO v_dncv_id;
            v_pendiente := p_lineas(v_i).cantidad;
            FOR r IN (SELECT m.MOV_ID_LOTE,
                             m.MOV_CANTIDAD - NVL((SELECT SUM(m2.MOV_CANTIDAD)
                                                     FROM SGS_MOVIMIENTO_INVENTARIO m2
                                                     JOIN SGS_DETALLE_NOTA_CREDITO_VENTA d2 ON d2.DNCV_ID = m2.MOV_ID_DETALLE_NC_VENTA
                                                    WHERE d2.DNCV_ID_DETALLE_FACTURA = v_dfv_id
                                                      AND m2.MOV_ID_LOTE = m.MOV_ID_LOTE), 0) AS DISPONIBLE
                        FROM SGS_MOVIMIENTO_INVENTARIO m
                       WHERE m.MOV_ID_DETALLE_VENTA = v_dfv_id
                       ORDER BY m.MOV_ID) LOOP
                EXIT WHEN v_pendiente <= 0;
                v_toma := LEAST(r.DISPONIBLE, v_pendiente);
                IF v_toma > 0 THEN
                    INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_NC_VENTA)
                    VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, r.MOV_ID_LOTE, v_sucursal, 'DEVOLUCION_CLIENTE', v_toma, v_dncv_id);
                    v_pendiente := v_pendiente - v_toma;
                END IF;
            END LOOP;
            v_i := p_lineas.NEXT(v_i);
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_devolucion;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_devolucion');
            RAISE_APPLICATION_ERROR(-20103, 'La cuenta del cliente la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_devolucion;
            SGS_PKG_ERRORES.registrar('SGS_PKG_VENTAS.registrar_devolucion');
            RAISE;
    END;
END;

