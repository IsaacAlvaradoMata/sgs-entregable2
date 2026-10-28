-- Paso 7: prueba de permisos de un usuario de rol. Se ejecuta con SQL*Plus conectado como el usuario a probar.
-- Intenta las mismas 9 acciones antes y despues de activar su rol, y muestra PERMITIDO o RECHAZADO con el error de Oracle.
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET DEFINE OFF
DECLARE
    v_rol VARCHAR2(30) := 'SGS_ROL_' || SUBSTR(USER, 5);

    PROCEDURE probar (p_accion IN VARCHAR2, p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE(RPAD(p_accion, 34) || 'PERMITIDO');
        ROLLBACK;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(p_accion, 34) || 'RECHAZADO  ' || SUBSTR(SQLERRM, 1, 60));
    END;

    PROCEDURE probar_todo IS
    BEGIN
        probar('Consultar precios de venta', 'SELECT COUNT(*) FROM SGS_ADMIN.SGS_VW_PRECIO_VENTA');
        probar('Usar el package de ventas', 'DECLARE v SGS_ADMIN.SGS_PKG_VENTAS.t_pagos; BEGIN NULL; END;');
        probar('Usar el package de compras', 'DECLARE v SGS_ADMIN.SGS_PKG_COMPRAS.t_lineas; BEGIN NULL; END;');
        probar('Asignar credito a un cliente', 'BEGIN IF 1 = 0 THEN SGS_ADMIN.SGS_PKG_CREDITO.asignar_credito(0, 0); END IF; END;');
        probar('Modificar proveedores', 'UPDATE SGS_ADMIN.SGS_PROVEEDOR SET PRV_TELEFONO = PRV_TELEFONO WHERE 1 = 0');
        probar('Modificar descuentos', 'UPDATE SGS_ADMIN.SGS_DESCUENTO SET DSC_NOMBRE = DSC_NOMBRE WHERE 1 = 0');
        probar('Ver operaciones criticas', 'SELECT COUNT(*) FROM SGS_ADMIN.SGS_VW_BITACORA_CRITICA');
        probar('Ejecutar procesos a demanda', 'BEGIN IF 1 = 0 THEN SGS_ADMIN.SGS_PKG_PROCESOS.cerrar_dia; END IF; END;');
        probar('Borrar clientes', 'DELETE FROM SGS_ADMIN.SGS_CLIENTE WHERE 1 = 0');
    END;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Usuario: ' || USER);
    DBMS_OUTPUT.PUT_LINE('--- Sin activar el rol ---');
    probar_todo;

    DBMS_OUTPUT.PUT_LINE('--- Activar un rol ajeno ---');
    probar('Activar ' || CASE WHEN v_rol = 'SGS_ROL_GERENTE' THEN 'SGS_ROL_DIGITADOR' ELSE 'SGS_ROL_GERENTE' END,
           'BEGIN SGS_ADMIN.SGS_PKG_ACCESO.activar_rol(''' || CASE WHEN v_rol = 'SGS_ROL_GERENTE' THEN 'SGS_ROL_DIGITADOR' ELSE 'SGS_ROL_GERENTE' END || '''); END;');

    DBMS_OUTPUT.PUT_LINE('--- Activar ' || v_rol || ' con su clave ---');
    SGS_ADMIN.SGS_PKG_ACCESO.activar_rol(v_rol);
    FOR r IN (SELECT ROLE FROM SESSION_ROLES) LOOP
        DBMS_OUTPUT.PUT_LINE('Rol activo: ' || r.ROLE);
    END LOOP;
    probar_todo;
END;
/
EXIT
