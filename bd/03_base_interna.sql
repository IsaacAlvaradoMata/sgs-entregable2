-- 03_base_interna.sql: packages internos que usan todos los procesos (errores, parametros, cifrado y correo).
-- Se ejecuta como SGS_ADMIN en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB en SGSPRI).
-- Requiere haber ejecutado 02_modelo.sql.

-- 1. Validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Errores: registra en SGS_BITACORA_ERROR el error que se esta manejando
-- Uso en el bloque EXCEPTION de cualquier procedimiento:
--   WHEN OTHERS THEN ROLLBACK; SGS_PKG_ERRORES.registrar('PAQUETE.procedimiento'); RAISE;
CREATE OR REPLACE PACKAGE SGS_PKG_ERRORES AS
    PROCEDURE registrar (p_programa IN VARCHAR2);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_ERRORES AS

    PROCEDURE registrar (p_programa IN VARCHAR2) IS
        -- Transaccion propia: el registro queda aunque el programa que fallo haga ROLLBACK
        PRAGMA AUTONOMOUS_TRANSACTION;
        -- SQLERRM no puede ir directo en un INSERT (ORA-00984): se toma en variables
        v_codigo   NUMBER         := SQLCODE;
        v_mensaje  VARCHAR2(512)  := SUBSTR(SQLERRM, 1, 512);
        v_traza    VARCHAR2(2000) := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000);
    BEGIN
        INSERT INTO SGS_BITACORA_ERROR (BER_ID, BER_PROGRAMA, BER_CODIGO, BER_MENSAJE, BER_TRAZA)
        VALUES (SEQ_BITACORA_ERROR.NEXTVAL, SUBSTR(p_programa, 1, 128), v_codigo, v_mensaje, v_traza);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            -- Si el registro falla no se bloquea al programa que llamo; su error original sigue con RAISE
            ROLLBACK;
    END;

END;
/

-- 3. Parametros: lectura y actualizacion centralizada de SGS_PARAMETRO
-- Errores propios: -20010 no existe, -20011 no es numerico, -20012 es cifrado, -20013 bloqueado por otra sesion
CREATE OR REPLACE PACKAGE SGS_PKG_PARAMETROS AS
    FUNCTION obtener (p_codigo IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION obtener_numero (p_codigo IN VARCHAR2) RETURN NUMBER;
    PROCEDURE actualizar (p_codigo IN VARCHAR2, p_valor IN VARCHAR2);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_PARAMETROS AS

    -- Valor tal como esta guardado; los cifrados se leen con SGS_PKG_CIFRADO
    FUNCTION obtener (p_codigo IN VARCHAR2) RETURN VARCHAR2 IS
        v_valor SGS_PARAMETRO.PAR_VALOR%TYPE;
    BEGIN
        SELECT PAR_VALOR
          INTO v_valor
          FROM SGS_PARAMETRO
         WHERE PAR_CODIGO = UPPER(p_codigo);
        RETURN v_valor;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_PARAMETROS.obtener');
            RAISE_APPLICATION_ERROR(-20010, 'No existe el parametro ' || p_codigo);
    END;

    -- Los numeros se guardan con punto decimal; la conversion no depende del idioma de la sesion
    FUNCTION obtener_numero (p_codigo IN VARCHAR2) RETURN NUMBER IS
        v_valor SGS_PARAMETRO.PAR_VALOR%TYPE := obtener(p_codigo);
    BEGIN
        RETURN TO_NUMBER(v_valor, '999999999999990D9999', 'NLS_NUMERIC_CHARACTERS=''.,''');
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_PARAMETROS.obtener_numero');
            RAISE_APPLICATION_ERROR(-20011, 'El parametro ' || p_codigo || ' no es numerico: ' || v_valor);
    END;

    -- Bloquea la fila con NOWAIT para que dos sesiones no cambien el mismo parametro a la vez
    PROCEDURE actualizar (p_codigo IN VARCHAR2, p_valor IN VARCHAR2) IS
        v_cifrado   SGS_PARAMETRO.PAR_ES_CIFRADO%TYPE;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -54);
    BEGIN
        SELECT PAR_ES_CIFRADO
          INTO v_cifrado
          FROM SGS_PARAMETRO
         WHERE PAR_CODIGO = UPPER(p_codigo)
           FOR UPDATE NOWAIT;

        IF v_cifrado = 'S' THEN
            RAISE_APPLICATION_ERROR(-20012, 'El parametro ' || p_codigo || ' es cifrado: se cambia con SGS_PKG_CIFRADO');
        END IF;

        UPDATE SGS_PARAMETRO
           SET PAR_VALOR = p_valor
         WHERE PAR_CODIGO = UPPER(p_codigo);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            SGS_PKG_ERRORES.registrar('SGS_PKG_PARAMETROS.actualizar');
            RAISE_APPLICATION_ERROR(-20010, 'No existe el parametro ' || p_codigo);
        WHEN e_bloqueado THEN
            ROLLBACK;
            SGS_PKG_ERRORES.registrar('SGS_PKG_PARAMETROS.actualizar');
            RAISE_APPLICATION_ERROR(-20013, 'El parametro ' || p_codigo || ' lo esta modificando otra sesion');
        WHEN OTHERS THEN
            ROLLBACK;
            SGS_PKG_ERRORES.registrar('SGS_PKG_PARAMETROS.actualizar');
            RAISE;
    END;

END;
/

-- 4. Parametros iniciales no cifrados (definidos en docs/decisiones.md); porcentajes como fraccion
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'CORREO_REMITENTE', 'sgs.notificaciones.una@gmail.com', 'Cuenta que envia las notificaciones');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'CORREO_SERVIDOR', 'smtp.gmail.com', 'Servidor SMTP');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'CORREO_PUERTO', '587', 'Puerto SMTP con STARTTLS');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PCT_AVISO_CLIENTE', '0.85', 'Uso del credito a partir del cual se avisa al cliente');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PCT_AVISO_COORDINADOR', '0.85', 'Uso del credito para la lista que recibe el coordinador');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PCT_AVISO_GERENTE_CXP', '0.70', 'Uso del credito con proveedores a partir del cual se avisa al gerente');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'DIAS_MOROSIDAD', '30', 'Dias sin pagar para considerar moroso a un cliente con saldo');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'DIAS_PROXIMO_VENCER', '7', 'Dias antes del vencimiento para reportar un producto');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'MESES_ANTIGUEDAD_BODEGA', '6', 'Meses en bodega para reportar un producto como antiguo');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PREMIO_CANTIDAD_CLIENTES', '10', 'Cantidad de mejores clientes que se premian');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PREMIO_MONTO_ORDEN', '100000', 'Monto de la orden de compra de cada cliente premiado');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PREMIO_FRECUENCIA_MESES', '6', 'Cada cuantos meses se ejecuta la premiacion');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'PCT_MAX_TABLESPACE', '0.85', 'Uso maximo permitido de un tablespace antes de notificar');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'STB_MINUTOS_ARCHIVO', '5', 'Minutos para generar un archivo de actualizacion (standby)');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'STB_MB_ARCHIVO', '50', 'Tamano en MB que genera un archivo de actualizacion (standby)');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'STB_MINUTOS_TRASLADO', '10', 'Minutos entre traslados de informacion al standby');
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'STB_DIAS_BORRADO', '3', 'Dias tras los cuales se borran los archivos ya trasladados y aplicados');

-- 5. Destinatarios de las notificaciones: alias de la cuenta del proyecto; antes de la defensa se cambian por el correo que indique el profesor
INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
VALUES (SEQ_DESTINATARIO.NEXTVAL, 'GERENTE', 'Gerencia general', 'sgs.notificaciones.una+gerente@gmail.com');
INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
VALUES (SEQ_DESTINATARIO.NEXTVAL, 'COORDINADOR', 'Coordinacion', 'sgs.notificaciones.una+coordinador@gmail.com');
INSERT INTO SGS_DESTINATARIO (DES_ID, DES_TIPO, DES_NOMBRE, DES_EMAIL)
VALUES (SEQ_DESTINATARIO.NEXTVAL, 'DBA', 'Administracion de base de datos', 'sgs.notificaciones.una+dba@gmail.com');

COMMIT;
