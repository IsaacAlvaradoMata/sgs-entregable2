-- 08_seguridad.sql: perfil de contrasenas, roles protegidos con clave y usuarios de Oracle por rol.
-- Seccion 0 como SYS (SYSDBA); el resto como SGS_ADMIN. Ambas en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB).
-- Requiere haber ejecutado 07_procesos.sql (los permisos se dan sobre objetos que ya existen).
-- Antes de ejecutar: reemplazar <CLAVE_USUARIO_*> y <CLAVE_ROL_*> por las claves del ambiente (solo letras y numeros, 8 a 30).
-- Errores propios: -20130 rol desconocido, -20131 clave invalida, -20132 el usuario no tiene el rol

-- 0. EJECUTAR COMO SYS (SYSDBA), en la PDB
BEGIN
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Cambiar a la PDB antes de seguir: ALTER SESSION SET CONTAINER = <PDB>');
    END IF;
END;
/

-- Perfil de los usuarios del negocio: expiracion, intentos fallidos, bloqueo automatico, reutilizacion y recursos
CREATE PROFILE SGS_PERFIL_USUARIO LIMIT
    FAILED_LOGIN_ATTEMPTS 3
    PASSWORD_LOCK_TIME    30/1440
    PASSWORD_LIFE_TIME    60
    PASSWORD_GRACE_TIME   7
    PASSWORD_REUSE_MAX    5
    PASSWORD_REUSE_TIME   365
    SESSIONS_PER_USER     2
    IDLE_TIME             15;

-- Un usuario por rol; solo CREATE SESSION como privilegio de sistema. DEFAULT ROLE NONE: el rol se activa con su clave
CREATE USER SGS_GERENTE IDENTIFIED BY "<CLAVE_USUARIO_GERENTE>"
    DEFAULT TABLESPACE SGS_DATA TEMPORARY TABLESPACE TEMP PROFILE SGS_PERFIL_USUARIO;
CREATE USER SGS_JEFE_DEPTO IDENTIFIED BY "<CLAVE_USUARIO_JEFE_DEPTO>"
    DEFAULT TABLESPACE SGS_DATA TEMPORARY TABLESPACE TEMP PROFILE SGS_PERFIL_USUARIO;
CREATE USER SGS_JEFE_PROVEEDURIA IDENTIFIED BY "<CLAVE_USUARIO_JEFE_PROVEEDURIA>"
    DEFAULT TABLESPACE SGS_DATA TEMPORARY TABLESPACE TEMP PROFILE SGS_PERFIL_USUARIO;
CREATE USER SGS_DIGITADOR IDENTIFIED BY "<CLAVE_USUARIO_DIGITADOR>"
    DEFAULT TABLESPACE SGS_DATA TEMPORARY TABLESPACE TEMP PROFILE SGS_PERFIL_USUARIO;

GRANT CREATE SESSION TO SGS_GERENTE, SGS_JEFE_DEPTO, SGS_JEFE_PROVEEDURIA, SGS_DIGITADOR;

ALTER USER SGS_GERENTE DEFAULT ROLE NONE;
ALTER USER SGS_JEFE_DEPTO DEFAULT ROLE NONE;
ALTER USER SGS_JEFE_PROVEEDURIA DEFAULT ROLE NONE;
ALTER USER SGS_DIGITADOR DEFAULT ROLE NONE;

-- SGS_ADMIN crea los roles (y queda con ADMIN OPTION para cambiarles la clave) y verifica a quien se le otorgaron
GRANT CREATE ROLE TO SGS_ADMIN;
GRANT SELECT ON SYS.DBA_ROLE_PRIVS TO SGS_ADMIN;

-- 1. A partir de aqui, conectado como SGS_ADMIN: validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Roles (se crean sin clave; la clave la pone asignar_clave_rol). ORA-01921 = el rol ya existe
DECLARE
    PROCEDURE crear (p_rol IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE ROLE ' || p_rol;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -1921 THEN
                RAISE;
            END IF;
    END;
BEGIN
    crear('SGS_ROL_GERENTE');
    crear('SGS_ROL_JEFE_DEPTO');
    crear('SGS_ROL_JEFE_PROVEEDURIA');
    crear('SGS_ROL_DIGITADOR');
END;
/

-- 3. Claves de los roles
-- Administracion: cambia la clave del rol y la guarda cifrada en SGS_PARAMETRO (CLAVE_ROL_*), para que nunca queden distintas
CREATE OR REPLACE PACKAGE SGS_PKG_SEGURIDAD AS
    PROCEDURE asignar_clave_rol (p_rol IN VARCHAR2, p_clave IN VARCHAR2);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_SEGURIDAD AS

    PROCEDURE asignar_clave_rol (p_rol IN VARCHAR2, p_clave IN VARCHAR2) IS
        v_rol VARCHAR2(30) := UPPER(p_rol);
    BEGIN
        IF v_rol NOT IN ('SGS_ROL_GERENTE', 'SGS_ROL_JEFE_DEPTO', 'SGS_ROL_JEFE_PROVEEDURIA', 'SGS_ROL_DIGITADOR') THEN
            RAISE_APPLICATION_ERROR(-20130, 'Rol desconocido: ' || p_rol);
        END IF;
        -- Solo letras y numeros: la clave va dentro de una sentencia dinamica
        IF NOT REGEXP_LIKE(p_clave, '^[A-Za-z0-9]{8,30}$') THEN
            RAISE_APPLICATION_ERROR(-20131, 'La clave del rol debe tener de 8 a 30 letras o numeros');
        END IF;

        EXECUTE IMMEDIATE 'ALTER ROLE ' || v_rol || ' IDENTIFIED BY "' || p_clave || '"';
        SGS_PKG_CIFRADO.guardar_parametro('CLAVE_' || SUBSTR(v_rol, 5), p_clave, 'Clave del rol ' || v_rol);
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_SEGURIDAD.asignar_clave_rol');
            RAISE;
    END;

END;
/

-- Entrega la clave descifrada solo a un usuario al que se le otorgo ese rol (derechos del dueno: lee el parametro cifrado)
CREATE OR REPLACE PACKAGE SGS_PKG_ROLES AS
    FUNCTION clave_rol (p_rol IN VARCHAR2) RETURN VARCHAR2;
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_ROLES AS

    FUNCTION clave_rol (p_rol IN VARCHAR2) RETURN VARCHAR2 IS
        v_rol      VARCHAR2(30) := UPPER(p_rol);
        v_usuario  VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
        v_tiene    NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_tiene
          FROM SYS.DBA_ROLE_PRIVS
         WHERE GRANTEE = v_usuario
           AND GRANTED_ROLE = v_rol
           AND v_rol LIKE 'SGS\_ROL\_%' ESCAPE '\';
        IF v_tiene = 0 THEN
            RAISE_APPLICATION_ERROR(-20132, 'El usuario ' || v_usuario || ' no tiene el rol ' || v_rol);
        END IF;
        RETURN SGS_PKG_CIFRADO.obtener_parametro('CLAVE_' || SUBSTR(v_rol, 5));
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_ROLES.clave_rol');
            RAISE;
    END;

END;
/

-- Activa el rol en la sesion del usuario. Derechos del invocador: SET ROLE no se permite en procedimientos con derechos del dueno
CREATE OR REPLACE PACKAGE SGS_PKG_ACCESO AUTHID CURRENT_USER AS
    PROCEDURE activar_rol (p_rol IN VARCHAR2);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_ACCESO AS

    PROCEDURE activar_rol (p_rol IN VARCHAR2) IS
        v_clave VARCHAR2(250) := SGS_ADMIN.SGS_PKG_ROLES.clave_rol(p_rol);
    BEGIN
        DBMS_SESSION.SET_ROLE(UPPER(p_rol) || ' IDENTIFIED BY "' || v_clave || '"');
    EXCEPTION
        WHEN OTHERS THEN
            SGS_ADMIN.SGS_PKG_ERRORES.registrar('SGS_PKG_ACCESO.activar_rol');
            RAISE;
    END;

END;
/

-- Claves iniciales de los roles
BEGIN
    SGS_PKG_SEGURIDAD.asignar_clave_rol('SGS_ROL_GERENTE', '<CLAVE_ROL_GERENTE>');
    SGS_PKG_SEGURIDAD.asignar_clave_rol('SGS_ROL_JEFE_DEPTO', '<CLAVE_ROL_JEFE_DEPTO>');
    SGS_PKG_SEGURIDAD.asignar_clave_rol('SGS_ROL_JEFE_PROVEEDURIA', '<CLAVE_ROL_JEFE_PROVEEDURIA>');
    SGS_PKG_SEGURIDAD.asignar_clave_rol('SGS_ROL_DIGITADOR', '<CLAVE_ROL_DIGITADOR>');
END;
/

-- 4. Privilegios de objeto de cada rol (ningun rol puede borrar)
DECLARE
    PROCEDURE dar (p_privilegio IN VARCHAR2, p_objeto IN VARCHAR2, p_rol IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'GRANT ' || p_privilegio || ' ON ' || p_objeto || ' TO ' || p_rol;
    END;
BEGIN
    -- Digitador y jefe de departamento: ventas, pagos y devoluciones de clientes, registro de clientes y consultas de venta
    FOR r IN (SELECT 'SGS_ROL_DIGITADOR' AS ROL FROM DUAL UNION ALL SELECT 'SGS_ROL_JEFE_DEPTO' FROM DUAL) LOOP
        dar('EXECUTE', 'SGS_PKG_VENTAS', r.ROL);
        dar('EXECUTE', 'SGS_PKG_CLIENTES', r.ROL);
        FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                    FROM TABLE(SYS.ODCIVARCHAR2LIST('SGS_VW_PRECIO_VENTA', 'SGS_PRODUCTO', 'SGS_ARTICULO_FACTURABLE',
                                                    'SGS_SERVICIO', 'SGS_CODIGO_BARRAS', 'SGS_EXISTENCIA', 'SGS_SUCURSAL',
                                                    'SGS_TIPO_PAGO', 'SGS_PAIS', 'SGS_CLIENTE', 'SGS_CLIENTE_PERSONA',
                                                    'SGS_CUENTA_COBRAR', 'SGS_FACTURA_VENTA', 'SGS_DETALLE_FACTURA_VENTA',
                                                    'SGS_PAGO_FACTURA_VENTA', 'SGS_NOTA_CREDITO_VENTA', 'SGS_PROMOCION',
                                                    'SGS_ACCION_OTORGADA'))) LOOP
            dar('SELECT', t.OBJETO, r.ROL);
        END LOOP;
    END LOOP;

    -- Jefe de departamento: ademas administra promociones, descuentos, utilidad y descuento maximo por sucursal
    FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                FROM TABLE(SYS.ODCIVARCHAR2LIST('SGS_TIPO_PROMOCION', 'SGS_PROMOCION', 'SGS_PROMOCION_PRODUCTO', 'SGS_PREMIO',
                                                'SGS_PROMOCION_PREMIO', 'SGS_DESCUENTO', 'SGS_DESCUENTO_FAMILIA',
                                                'SGS_DESCUENTO_PROVEEDOR'))) LOOP
        dar('SELECT, INSERT, UPDATE', t.OBJETO, 'SGS_ROL_JEFE_DEPTO');
    END LOOP;
    FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                FROM TABLE(SYS.ODCIVARCHAR2LIST('SEQ_TIPO_PROMOCION', 'SEQ_PROMOCION', 'SEQ_PROMOCION_PRODUCTO', 'SEQ_PREMIO', 'SEQ_PROMOCION_PREMIO',
                                                'SEQ_DESCUENTO', 'SEQ_DESCUENTO_FAMILIA', 'SEQ_DESCUENTO_PROVEEDOR'))) LOOP
        dar('SELECT', t.OBJETO, 'SGS_ROL_JEFE_DEPTO');
    END LOOP;
    dar('SELECT', 'SGS_DESCUENTO_DETALLE', 'SGS_ROL_JEFE_DEPTO');
    dar('SELECT', 'SGS_FAMILIA_PRODUCTO', 'SGS_ROL_JEFE_DEPTO');
    dar('SELECT', 'SGS_PROVEEDOR', 'SGS_ROL_JEFE_DEPTO');
    dar('SELECT', 'SGS_PRODUCTO_SUCURSAL', 'SGS_ROL_JEFE_DEPTO');
    dar('UPDATE (PS_PCT_UTILIDAD, PS_PCT_DESCUENTO_MAXIMO)', 'SGS_PRODUCTO_SUCURSAL', 'SGS_ROL_JEFE_DEPTO');

    -- Jefe de proveeduria: compras, pagos y devoluciones a proveedores, traslados, proveedores y productos
    dar('EXECUTE', 'SGS_PKG_COMPRAS', 'SGS_ROL_JEFE_PROVEEDURIA');
    dar('EXECUTE', 'SGS_PKG_INVENTARIO', 'SGS_ROL_JEFE_PROVEEDURIA');
    FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                FROM TABLE(SYS.ODCIVARCHAR2LIST('SGS_PROVEEDOR', 'SGS_PRODUCTO', 'SGS_ARTICULO_FACTURABLE',
                                                'SGS_CODIGO_BARRAS', 'SGS_PRODUCTO_SUCURSAL'))) LOOP
        dar('SELECT, INSERT, UPDATE', t.OBJETO, 'SGS_ROL_JEFE_PROVEEDURIA');
    END LOOP;
    FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                FROM TABLE(SYS.ODCIVARCHAR2LIST('SEQ_PROVEEDOR', 'SEQ_PRODUCTO', 'SEQ_ARTICULO_FACTURABLE',
                                                'SEQ_CODIGO_BARRAS', 'SEQ_PRODUCTO_SUCURSAL'))) LOOP
        dar('SELECT', t.OBJETO, 'SGS_ROL_JEFE_PROVEEDURIA');
    END LOOP;
    FOR t IN (SELECT COLUMN_VALUE AS OBJETO
                FROM TABLE(SYS.ODCIVARCHAR2LIST('SGS_VW_PRECIO_VENTA', 'SGS_FAMILIA_PRODUCTO', 'SGS_SUCURSAL', 'SGS_TIPO_PAGO',
                                                'SGS_LOTE', 'SGS_EXISTENCIA', 'SGS_MOVIMIENTO_INVENTARIO', 'SGS_TRASLADO',
                                                'SGS_DETALLE_TRASLADO', 'SGS_FACTURA_PROVEEDOR',
                                                'SGS_DETALLE_FACTURA_PROVEEDOR', 'SGS_PAGO_FACTURA_PROVEEDOR',
                                                'SGS_NOTA_CREDITO_PROVEEDOR', 'SGS_CUENTA_PAGAR', 'SGS_HISTORICO_PRECIO'))) LOOP
        dar('SELECT', t.OBJETO, 'SGS_ROL_JEFE_PROVEEDURIA');
    END LOOP;

    -- Gerente: consulta todo (menos usuarios del sistema y tablas externas), credito, parametros y procesos a demanda
    FOR t IN (SELECT OBJECT_NAME
                FROM USER_OBJECTS
               WHERE OBJECT_TYPE IN ('TABLE', 'VIEW')
                 AND OBJECT_NAME LIKE 'SGS\_%' ESCAPE '\'
                 AND OBJECT_NAME NOT LIKE 'SGS\_EXT\_%' ESCAPE '\'
                 AND OBJECT_NAME <> 'SGS_USUARIO') LOOP
        dar('SELECT', t.OBJECT_NAME, 'SGS_ROL_GERENTE');
    END LOOP;
    dar('EXECUTE', 'SGS_PKG_CREDITO', 'SGS_ROL_GERENTE');
    dar('EXECUTE', 'SGS_PKG_PARAMETROS', 'SGS_ROL_GERENTE');
    dar('EXECUTE', 'SGS_PKG_PROCESOS', 'SGS_ROL_GERENTE');
END;
/

-- 5. Cada usuario recibe su rol (sin activarlo) y lo minimo para activarlo: el package de acceso y el de su clave
GRANT SGS_ROL_GERENTE TO SGS_GERENTE;
GRANT SGS_ROL_JEFE_DEPTO TO SGS_JEFE_DEPTO;
GRANT SGS_ROL_JEFE_PROVEEDURIA TO SGS_JEFE_PROVEEDURIA;
GRANT SGS_ROL_DIGITADOR TO SGS_DIGITADOR;

GRANT EXECUTE ON SGS_PKG_ACCESO TO SGS_GERENTE, SGS_JEFE_DEPTO, SGS_JEFE_PROVEEDURIA, SGS_DIGITADOR;
GRANT EXECUTE ON SGS_PKG_ROLES TO SGS_GERENTE, SGS_JEFE_DEPTO, SGS_JEFE_PROVEEDURIA, SGS_DIGITADOR;
GRANT EXECUTE ON SGS_PKG_ERRORES TO SGS_GERENTE, SGS_JEFE_DEPTO, SGS_JEFE_PROVEEDURIA, SGS_DIGITADOR;
