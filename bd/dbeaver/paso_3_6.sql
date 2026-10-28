CREATE OR REPLACE PACKAGE SGS_PKG_INVENTARIO AS
    TYPE t_asignacion IS RECORD (id_lote NUMBER, cantidad NUMBER);
    TYPE t_asignaciones IS TABLE OF t_asignacion INDEX BY PLS_INTEGER;
    TYPE t_linea IS RECORD (codigo VARCHAR2(30), cantidad NUMBER);
    TYPE t_lineas IS TABLE OF t_linea INDEX BY PLS_INTEGER;
    FUNCTION reservar_fefo (p_id_sucursal IN NUMBER, p_id_producto IN NUMBER, p_cantidad IN NUMBER) RETURN t_asignaciones;
    PROCEDURE trasladar (p_origen      IN  VARCHAR2,
                         p_destino     IN  VARCHAR2,
                         p_usuario     IN  VARCHAR2,
                         p_lineas      IN  t_lineas,
                         p_id_traslado OUT NUMBER);
END;

CREATE OR REPLACE PACKAGE BODY SGS_PKG_INVENTARIO AS
    FUNCTION id_sucursal (p_nombre IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_SUCURSAL.SUC_ID%TYPE;
    BEGIN
        SELECT SUC_ID INTO v_id FROM SGS_SUCURSAL WHERE SUC_NOMBRE = p_nombre;
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20091, 'No existe la sucursal ' || p_nombre);
    END;
    FUNCTION id_producto (p_codigo IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_PRODUCTO.PRO_ID%TYPE;
    BEGIN
        SELECT PRO_ID INTO v_id FROM SGS_PRODUCTO WHERE PRO_CODIGO = p_codigo;
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20092, 'No existe el producto ' || p_codigo);
    END;
    FUNCTION id_usuario (p_username IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_USUARIO.USU_ID%TYPE;
    BEGIN
        SELECT USU_ID INTO v_id FROM SGS_USUARIO WHERE USU_USERNAME = LOWER(p_username) AND USU_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20095, 'No existe o no esta activo el usuario ' || p_username);
    END;
    FUNCTION reservar_fefo (p_id_sucursal IN NUMBER, p_id_producto IN NUMBER, p_cantidad IN NUMBER) RETURN t_asignaciones IS
        CURSOR c_lotes IS
            SELECT e.EXI_ID_LOTE, e.EXI_CANTIDAD
              FROM SGS_EXISTENCIA e
              JOIN SGS_LOTE l ON l.LOT_ID = e.EXI_ID_LOTE
              JOIN SGS_DETALLE_FACTURA_PROVEEDOR d ON d.DFP_ID = l.LOT_ID_DETALLE_COMPRA
             WHERE e.EXI_ID_SUCURSAL = p_id_sucursal
               AND d.DFP_ID_PRODUCTO = p_id_producto
               AND e.EXI_CANTIDAD > 0
               AND (l.LOT_FECHA_VENCIMIENTO IS NULL OR l.LOT_FECHA_VENCIMIENTO >= TRUNC(SYSDATE))
             ORDER BY l.LOT_FECHA_VENCIMIENTO NULLS LAST, l.LOT_FECHA_INGRESO, l.LOT_ID
               FOR UPDATE OF e.EXI_CANTIDAD WAIT 5;
        v_asignaciones t_asignaciones;
        v_pendiente    NUMBER := p_cantidad;
        v_toma         NUMBER;
        v_n            PLS_INTEGER := 0;
        e_espera       EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
    BEGIN
        FOR r IN c_lotes LOOP
            EXIT WHEN v_pendiente <= 0;
            v_toma := LEAST(r.EXI_CANTIDAD, v_pendiente);
            v_n := v_n + 1;
            v_asignaciones(v_n).id_lote  := r.EXI_ID_LOTE;
            v_asignaciones(v_n).cantidad := v_toma;
            v_pendiente := v_pendiente - v_toma;
        END LOOP;
        IF v_pendiente > 0 THEN
            RAISE_APPLICATION_ERROR(-20090, 'Existencia insuficiente del producto ' || p_id_producto || ' en la sucursal '
                                            || p_id_sucursal || ': faltan ' || v_pendiente);
        END IF;
        RETURN v_asignaciones;
    EXCEPTION
        WHEN e_espera THEN
            RAISE_APPLICATION_ERROR(-20094, 'Las existencias las esta usando otra sesion; intente de nuevo');
    END;
    PROCEDURE trasladar (p_origen      IN  VARCHAR2,
                         p_destino     IN  VARCHAR2,
                         p_usuario     IN  VARCHAR2,
                         p_lineas      IN  t_lineas,
                         p_id_traslado OUT NUMBER) IS
        v_origen       SGS_SUCURSAL.SUC_ID%TYPE;
        v_destino      SGS_SUCURSAL.SUC_ID%TYPE;
        v_usuario      SGS_USUARIO.USU_ID%TYPE;
        v_producto     SGS_PRODUCTO.PRO_ID%TYPE;
        v_asignaciones t_asignaciones;
        v_dtr_id       SGS_DETALLE_TRASLADO.DTR_ID%TYPE;
        v_i            PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_trasladar;
        IF p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20093, 'El traslado no tiene lineas');
        END IF;
        v_origen  := id_sucursal(p_origen);
        v_destino := id_sucursal(p_destino);
        v_usuario := id_usuario(p_usuario);
        INSERT INTO SGS_TRASLADO (TRA_ID, TRA_ID_SUCURSAL_ORIGEN, TRA_ID_SUCURSAL_DESTINO, TRA_ID_USUARIO)
        VALUES (SEQ_TRASLADO.NEXTVAL, v_origen, v_destino, v_usuario)
        RETURNING TRA_ID INTO p_id_traslado;
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            v_producto     := id_producto(p_lineas(v_i).codigo);
            v_asignaciones := reservar_fefo(v_origen, v_producto, p_lineas(v_i).cantidad);
            FOR j IN 1 .. v_asignaciones.COUNT LOOP
                INSERT INTO SGS_DETALLE_TRASLADO (DTR_ID, DTR_ID_TRASLADO, DTR_ID_LOTE, DTR_CANTIDAD)
                VALUES (SEQ_DETALLE_TRASLADO.NEXTVAL, p_id_traslado, v_asignaciones(j).id_lote, v_asignaciones(j).cantidad)
                RETURNING DTR_ID INTO v_dtr_id;
                INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_TRASLADO)
                VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, v_asignaciones(j).id_lote, v_origen, 'TRASLADO_SALIDA',
                        v_asignaciones(j).cantidad, v_dtr_id);
                INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_TRASLADO)
                VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, v_asignaciones(j).id_lote, v_destino, 'TRASLADO_ENTRADA',
                        v_asignaciones(j).cantidad, v_dtr_id);
            END LOOP;
            v_i := p_lineas.NEXT(v_i);
        END LOOP;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_trasladar;
            SGS_PKG_ERRORES.registrar('SGS_PKG_INVENTARIO.trasladar');
            RAISE;
    END;
END;

