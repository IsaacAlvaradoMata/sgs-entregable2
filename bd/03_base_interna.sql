-- 03_base_interna.sql: packages internos que usan todos los procesos (errores, parametros, cifrado y correo).
-- Seccion 0 como SYS (SYSDBA); el resto como SGS_ADMIN. Ambas en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB).
-- Requiere haber ejecutado 02_modelo.sql. Antes de la seccion de cifrado: reemplazar <LLAVE_CIFRADO> por la llave real.

-- 0. EJECUTAR COMO SYS (SYSDBA), en la PDB: privilegios sobre paquetes del sistema que usan los packages
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO SGS_ADMIN;
GRANT EXECUTE ON SYS.UTL_SMTP TO SGS_ADMIN;
GRANT EXECUTE ON SYS.UTL_TCP TO SGS_ADMIN;

-- Lista de control de red: Oracle bloquea las conexiones salientes; se autoriza solo el servidor de correo
-- en sus dos puertos seguros: 465 (TLS desde el inicio) y 587 (STARTTLS); se usa el que permita la red
BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host       => 'smtp.gmail.com',
        lower_port => 465,
        upper_port => 465,
        ace        => xs$ace_type(privilege_list => xs$name_list('connect'),
                                  principal_name => 'SGS_ADMIN',
                                  principal_type => xs_acl.ptype_db));
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host       => 'smtp.gmail.com',
        lower_port => 587,
        upper_port => 587,
        ace        => xs$ace_type(privilege_list => xs$name_list('connect'),
                                  principal_name => 'SGS_ADMIN',
                                  principal_type => xs_acl.ptype_db));
    -- Resolver el nombre del servidor (este privilegio no lleva puertos)
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => 'smtp.gmail.com',
        ace  => xs$ace_type(privilege_list => xs$name_list('resolve'),
                            principal_name => 'SGS_ADMIN',
                            principal_type => xs_acl.ptype_db));
END;
/

-- 1. A partir de aqui, conectado como SGS_ADMIN: validar que la sesion es del dueno del esquema
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
VALUES (SEQ_PARAMETRO.NEXTVAL, 'CORREO_PUERTO', '465', 'Puerto SMTP: 465 = TLS desde el inicio, 587 = STARTTLS');
-- Ruta del wallet con los certificados de Google; cambia segun el servidor (ver servidores/configuracion)
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION)
VALUES (SEQ_PARAMETRO.NEXTVAL, 'CORREO_WALLET', 'file:/opt/oracle/oradata/wallet_sgs', 'Wallet con los certificados para la conexion cifrada con el servidor de correo');
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

-- 6. Cifrado: AES-256 para parametros sensibles y SHA-256 para las contrasenas de los usuarios del sistema
-- Errores propios: -20020 no existe el parametro cifrado, -20021 el parametro existe sin cifrar, -20022 no se pudo descifrar
CREATE OR REPLACE PACKAGE SGS_PKG_CIFRADO AS
    PROCEDURE guardar_parametro (p_codigo IN VARCHAR2, p_valor IN VARCHAR2, p_descripcion IN VARCHAR2 DEFAULT NULL);
    FUNCTION obtener_parametro (p_codigo IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION hash_clave (p_sal IN VARCHAR2, p_clave IN VARCHAR2) RETURN VARCHAR2;
    -- Devuelve 'S' si la clave del usuario del sistema es correcta y esta activo; 'N' en otro caso
    FUNCTION validar_usuario (p_username IN VARCHAR2, p_clave IN VARCHAR2) RETURN VARCHAR2;
END;
/

-- El cuerpo se instala ofuscado (wrap) porque contiene la llave; en el repo la llave va como marcador
BEGIN
    DBMS_DDL.CREATE_WRAPPED(q'[
CREATE OR REPLACE PACKAGE BODY SGS_PKG_CIFRADO AS

    -- Llave AES de 256 bits (64 caracteres hexadecimales)
    c_llave CONSTANT RAW(32) := HEXTORAW('<LLAVE_CIFRADO>');
    c_tipo  CONSTANT PLS_INTEGER := DBMS_CRYPTO.ENCRYPT_AES256 + DBMS_CRYPTO.CHAIN_CBC + DBMS_CRYPTO.PAD_PKCS5;

    -- Vector inicial aleatorio de 16 bytes al inicio del resultado: el mismo valor cifrado dos veces da textos distintos
    FUNCTION cifrar (p_valor IN VARCHAR2) RETURN VARCHAR2 IS
        v_iv RAW(16) := DBMS_CRYPTO.RANDOMBYTES(16);
    BEGIN
        RETURN RAWTOHEX(UTL_RAW.CONCAT(v_iv,
               DBMS_CRYPTO.ENCRYPT(src => UTL_I18N.STRING_TO_RAW(p_valor, 'AL32UTF8'),
                                   typ => c_tipo, key => c_llave, iv => v_iv)));
    END;

    FUNCTION descifrar (p_hex IN VARCHAR2) RETURN VARCHAR2 IS
        v_raw RAW(2000) := HEXTORAW(p_hex);
    BEGIN
        RETURN UTL_I18N.RAW_TO_CHAR(
               DBMS_CRYPTO.DECRYPT(src => UTL_RAW.SUBSTR(v_raw, 17),
                                   typ => c_tipo, key => c_llave, iv => UTL_RAW.SUBSTR(v_raw, 1, 16)), 'AL32UTF8');
    END;

    -- Crea o reemplaza un parametro cifrado; bloquea la fila con NOWAIT si ya existe
    PROCEDURE guardar_parametro (p_codigo IN VARCHAR2, p_valor IN VARCHAR2, p_descripcion IN VARCHAR2 DEFAULT NULL) IS
        v_cifrado SGS_PARAMETRO.PAR_ES_CIFRADO%TYPE;
        -- Las funciones privadas no se pueden usar dentro de SQL: el valor se cifra antes
        v_valor   SGS_PARAMETRO.PAR_VALOR%TYPE := cifrar(p_valor);
    BEGIN
        BEGIN
            SELECT PAR_ES_CIFRADO
              INTO v_cifrado
              FROM SGS_PARAMETRO
             WHERE PAR_CODIGO = UPPER(p_codigo)
               FOR UPDATE NOWAIT;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_cifrado := NULL;
        END;

        IF v_cifrado IS NULL THEN
            INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION, PAR_ES_CIFRADO)
            VALUES (SEQ_PARAMETRO.NEXTVAL, UPPER(p_codigo), v_valor, p_descripcion, 'S');
        ELSIF v_cifrado = 'S' THEN
            UPDATE SGS_PARAMETRO
               SET PAR_VALOR = v_valor,
                   PAR_DESCRIPCION = NVL(p_descripcion, PAR_DESCRIPCION)
             WHERE PAR_CODIGO = UPPER(p_codigo);
        ELSE
            RAISE_APPLICATION_ERROR(-20021, 'El parametro ' || p_codigo || ' existe sin cifrar');
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CIFRADO.guardar_parametro');
            RAISE;
    END;

    FUNCTION obtener_parametro (p_codigo IN VARCHAR2) RETURN VARCHAR2 IS
        v_valor SGS_PARAMETRO.PAR_VALOR%TYPE;
    BEGIN
        SELECT PAR_VALOR
          INTO v_valor
          FROM SGS_PARAMETRO
         WHERE PAR_CODIGO = UPPER(p_codigo)
           AND PAR_ES_CIFRADO = 'S';
        RETURN descifrar(v_valor);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_CIFRADO.obtener_parametro');
            RAISE_APPLICATION_ERROR(-20020, 'No existe el parametro cifrado ' || p_codigo);
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_CIFRADO.obtener_parametro');
            RAISE_APPLICATION_ERROR(-20022, 'No se pudo descifrar el parametro ' || p_codigo);
    END;

    -- SHA-256 de (sal || clave) en hexadecimal; da el mismo resultado que STANDARD_HASH en SQL
    FUNCTION hash_clave (p_sal IN VARCHAR2, p_clave IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN RAWTOHEX(DBMS_CRYPTO.HASH(UTL_I18N.STRING_TO_RAW(p_sal || p_clave, 'AL32UTF8'), DBMS_CRYPTO.HASH_SH256));
    END;

    FUNCTION validar_usuario (p_username IN VARCHAR2, p_clave IN VARCHAR2) RETURN VARCHAR2 IS
        v_hash SGS_USUARIO.USU_PASSWORD_HASH%TYPE;
        v_sal  SGS_USUARIO.USU_SAL%TYPE;
    BEGIN
        SELECT USU_PASSWORD_HASH, USU_SAL
          INTO v_hash, v_sal
          FROM SGS_USUARIO
         WHERE USU_USERNAME = LOWER(p_username)
           AND USU_ESTADO = 'A';
        IF hash_clave(v_sal, p_clave) = v_hash THEN
            RETURN 'S';
        END IF;
        RETURN 'N';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'N';
    END;

END;
]');
END;
/

-- 7. Correo: envia por SMTP con STARTTLS leyendo servidor, puerto, wallet, remitente y clave (descifrada) de los parametros
-- Errores propios: -20030 fallo el envio, -20031 no hay destinatarios activos del tipo
CREATE OR REPLACE PACKAGE SGS_PKG_CORREO AS
    -- p_destinatarios: uno o varios correos separados por coma
    PROCEDURE enviar (p_destinatarios IN VARCHAR2, p_asunto IN VARCHAR2, p_cuerpo IN VARCHAR2);
    -- Envia a todos los destinatarios activos de un tipo: GERENTE, COORDINADOR o DBA
    PROCEDURE enviar_a_tipo (p_tipo IN VARCHAR2, p_asunto IN VARCHAR2, p_cuerpo IN VARCHAR2);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_CORREO AS

    -- Escribe texto en UTF-8 por partes, para no superar el limite de un RAW
    PROCEDURE escribir (p_conexion IN OUT NOCOPY UTL_SMTP.CONNECTION, p_texto IN VARCHAR2) IS
        v_pos PLS_INTEGER := 1;
    BEGIN
        WHILE v_pos <= NVL(LENGTH(p_texto), 0) LOOP
            UTL_SMTP.WRITE_RAW_DATA(p_conexion, UTL_I18N.STRING_TO_RAW(SUBSTR(p_texto, v_pos, 8000), 'AL32UTF8'));
            v_pos := v_pos + 8000;
        END LOOP;
    END;

    PROCEDURE enviar (p_destinatarios IN VARCHAR2, p_asunto IN VARCHAR2, p_cuerpo IN VARCHAR2) IS
        v_conexion   UTL_SMTP.CONNECTION;
        v_remitente  VARCHAR2(250) := SGS_PKG_PARAMETROS.obtener('CORREO_REMITENTE');
        v_servidor   VARCHAR2(250) := SGS_PKG_PARAMETROS.obtener('CORREO_SERVIDOR');
        v_puerto     PLS_INTEGER   := SGS_PKG_PARAMETROS.obtener_numero('CORREO_PUERTO');
        v_wallet     VARCHAR2(250) := SGS_PKG_PARAMETROS.obtener('CORREO_WALLET');
        v_clave      VARCHAR2(250) := SGS_PKG_CIFRADO.obtener_parametro('CORREO_CLAVE');
        v_correo     VARCHAR2(250);
        v_i          PLS_INTEGER := 1;
        v_error      VARCHAR2(200);
        -- El asunto va en UTF-8 codificado en base64 para que se vean bien las tildes
        v_asunto     VARCHAR2(1000) := '=?UTF-8?B?' || UTL_RAW.CAST_TO_VARCHAR2(UTL_ENCODE.BASE64_ENCODE(
                                         UTL_I18N.STRING_TO_RAW(p_asunto, 'AL32UTF8'))) || '?=';
    BEGIN
        -- 465: la conexion es cifrada desde el inicio; 587: se cifra despues con STARTTLS
        -- tx_timeout evita que la sesion quede esperando si el servidor no responde
        v_conexion := UTL_SMTP.OPEN_CONNECTION(host => v_servidor, port => v_puerto, tx_timeout => 30,
                                               wallet_path => v_wallet, wallet_password => NULL,
                                               secure_connection_before_smtp => (v_puerto = 465));
        UTL_SMTP.EHLO(v_conexion, v_servidor);
        IF v_puerto <> 465 THEN
            UTL_SMTP.STARTTLS(v_conexion);
            UTL_SMTP.EHLO(v_conexion, v_servidor);
        END IF;
        UTL_SMTP.AUTH(c => v_conexion, username => v_remitente, password => v_clave, schemes => 'PLAIN');
        UTL_SMTP.MAIL(v_conexion, v_remitente);

        LOOP
            v_correo := TRIM(REGEXP_SUBSTR(p_destinatarios, '[^,]+', 1, v_i));
            EXIT WHEN v_correo IS NULL;
            UTL_SMTP.RCPT(v_conexion, v_correo);
            v_i := v_i + 1;
        END LOOP;

        UTL_SMTP.OPEN_DATA(v_conexion);
        escribir(v_conexion, 'From: SGS Notificaciones <' || v_remitente || '>' || UTL_TCP.CRLF
                          || 'To: ' || p_destinatarios || UTL_TCP.CRLF
                          || 'Subject: ' || REPLACE(v_asunto, UTL_TCP.CRLF) || UTL_TCP.CRLF
                          || 'Date: ' || TO_CHAR(SYSTIMESTAMP, 'Dy, DD Mon YYYY HH24:MI:SS TZHTZM', 'NLS_DATE_LANGUAGE=ENGLISH') || UTL_TCP.CRLF
                          || 'MIME-Version: 1.0' || UTL_TCP.CRLF
                          || 'Content-Type: text/plain; charset=UTF-8' || UTL_TCP.CRLF
                          || 'Content-Transfer-Encoding: 8bit' || UTL_TCP.CRLF
                          || UTL_TCP.CRLF);
        escribir(v_conexion, p_cuerpo);
        UTL_SMTP.CLOSE_DATA(v_conexion);
        UTL_SMTP.QUIT(v_conexion);
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SUBSTR(SQLERRM, 1, 200);
            SGS_PKG_ERRORES.registrar('SGS_PKG_CORREO.enviar');
            -- Cierra la conexion si quedo abierta; si ya estaba cerrada se ignora
            BEGIN
                UTL_SMTP.QUIT(v_conexion);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            RAISE_APPLICATION_ERROR(-20030, 'No se pudo enviar el correo: ' || v_error);
    END;

    PROCEDURE enviar_a_tipo (p_tipo IN VARCHAR2, p_asunto IN VARCHAR2, p_cuerpo IN VARCHAR2) IS
        v_destinatarios VARCHAR2(4000);
    BEGIN
        SELECT LISTAGG(DES_EMAIL, ',') WITHIN GROUP (ORDER BY DES_ID)
          INTO v_destinatarios
          FROM SGS_DESTINATARIO
         WHERE DES_TIPO = UPPER(p_tipo)
           AND DES_ESTADO = 'A';

        IF v_destinatarios IS NULL THEN
            RAISE_APPLICATION_ERROR(-20031, 'No hay destinatarios activos del tipo ' || p_tipo);
        END IF;

        enviar(v_destinatarios, p_asunto, p_cuerpo);
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_CORREO.enviar_a_tipo');
            RAISE;
    END;

END;
/
