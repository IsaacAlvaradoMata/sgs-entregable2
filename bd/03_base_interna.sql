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
