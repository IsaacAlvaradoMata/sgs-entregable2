-- 04_reglas_negocio.sql: triggers y packages de las reglas de negocio (cuentas, inventario, compras, ventas, promociones).
-- Se ejecuta como SGS_ADMIN en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB en SGSPRI).
-- Requiere haber ejecutado 03_base_interna.sql. Los packages hacen las operaciones; los triggers, lo automatico.

-- 1. Validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Clientes y proveedores
-- Errores propios: -20040 empresa con datos de persona, -20041 enlace al padron de un no nacional,
-- -20042 cedula distinta a la del padron, -20043 cedula no esta en el padron, -20044 limite menor al saldo,
-- -20045 cuenta bloqueada por otra sesion, -20046 pais no existe

-- Todo cliente tiene su cuenta por cobrar desde que se crea (limite 0 hasta que se le asigne credito)
CREATE OR REPLACE TRIGGER TRG_CLI_CREA_CUENTA
AFTER INSERT ON SGS_CLIENTE
FOR EACH ROW
BEGIN
    INSERT INTO SGS_CUENTA_COBRAR (CXC_ID, CXC_ID_CLIENTE)
    VALUES (SEQ_CUENTA_COBRAR.NEXTVAL, :NEW.CLI_ID);
END;
/

-- Todo proveedor tiene su cuenta por pagar desde que se crea
CREATE OR REPLACE TRIGGER TRG_PRV_CREA_CUENTA
AFTER INSERT ON SGS_PROVEEDOR
FOR EACH ROW
BEGIN
    INSERT INTO SGS_CUENTA_PAGAR (CXP_ID, CXP_ID_PROVEEDOR)
    VALUES (SEQ_CUENTA_PAGAR.NEXTVAL, :NEW.PRV_ID);
END;
/

-- Los datos de persona no aplican a empresas; el enlace al padron solo para nacionales y con la misma cedula
CREATE OR REPLACE TRIGGER TRG_CLP_VALIDA
BEFORE INSERT OR UPDATE ON SGS_CLIENTE_PERSONA
FOR EACH ROW
DECLARE
    v_tipo        SGS_CLIENTE.CLI_TIPO_PERSONA%TYPE;
    v_cedula      SGS_CLIENTE.CLI_CEDULA%TYPE;
    v_cedula_pad  SGS_PADRON.PAD_CEDULA%TYPE;
BEGIN
    SELECT CLI_TIPO_PERSONA, CLI_CEDULA
      INTO v_tipo, v_cedula
      FROM SGS_CLIENTE
     WHERE CLI_ID = :NEW.CLP_ID_CLIENTE;

    IF v_tipo = 'EMPRESA' THEN
        RAISE_APPLICATION_ERROR(-20040, 'Un cliente empresa no lleva datos de persona');
    END IF;

    IF :NEW.CLP_ID_PADRON IS NOT NULL THEN
        IF v_tipo <> 'NACIONAL' THEN
            RAISE_APPLICATION_ERROR(-20041, 'Solo un cliente nacional se enlaza al padron');
        END IF;
        SELECT PAD_CEDULA
          INTO v_cedula_pad
          FROM SGS_PADRON
         WHERE PAD_ID = :NEW.CLP_ID_PADRON;
        IF v_cedula_pad <> v_cedula THEN
            RAISE_APPLICATION_ERROR(-20042, 'La cedula del cliente no coincide con la de la persona del padron');
        END IF;
    END IF;
EXCEPTION
    -- Si el cliente o la persona del padron no existen, la llave foranea da el error correspondiente
    WHEN NO_DATA_FOUND THEN
        NULL;
END;
/

CREATE OR REPLACE PACKAGE SGS_PKG_CLIENTES AS
    -- Cliente nacional: nombre y apellidos se toman del padron con la cedula
    PROCEDURE registrar_nacional (p_cedula            IN  VARCHAR2,
                                  p_sexo              IN  VARCHAR2,
                                  p_estado_civil      IN  VARCHAR2 DEFAULT NULL,
                                  p_fecha_nac         IN  DATE     DEFAULT NULL,
                                  p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                  p_email             IN  VARCHAR2 DEFAULT NULL,
                                  p_direccion_casa    IN  VARCHAR2 DEFAULT NULL,
                                  p_direccion_trabajo IN  VARCHAR2 DEFAULT NULL,
                                  p_puesto            IN  VARCHAR2 DEFAULT NULL,
                                  p_empresa_labora    IN  VARCHAR2 DEFAULT NULL,
                                  p_asegurado         IN  VARCHAR2 DEFAULT NULL,
                                  p_escolaridad       IN  VARCHAR2 DEFAULT NULL,
                                  p_id_cliente        OUT NUMBER);

    -- Cliente extranjero: se digitan todos sus datos; p_pais_* son codigos ISO (ej. NIC)
    PROCEDURE registrar_extranjero (p_identificacion    IN  VARCHAR2,
                                    p_nombre            IN  VARCHAR2,
                                    p_apellido1         IN  VARCHAR2,
                                    p_apellido2         IN  VARCHAR2 DEFAULT NULL,
                                    p_pais_nacionalidad IN  VARCHAR2,
                                    p_pais_residencia   IN  VARCHAR2 DEFAULT 'CRI',
                                    p_sexo              IN  VARCHAR2 DEFAULT NULL,
                                    p_estado_civil      IN  VARCHAR2 DEFAULT NULL,
                                    p_fecha_nac         IN  DATE     DEFAULT NULL,
                                    p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                    p_email             IN  VARCHAR2 DEFAULT NULL,
                                    p_direccion_casa    IN  VARCHAR2 DEFAULT NULL,
                                    p_id_cliente        OUT NUMBER);

    PROCEDURE registrar_empresa (p_cedula_juridica   IN  VARCHAR2,
                                 p_nombre            IN  VARCHAR2,
                                 p_direccion_trabajo IN  VARCHAR2 DEFAULT NULL,
                                 p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                 p_fax               IN  VARCHAR2 DEFAULT NULL,
                                 p_email             IN  VARCHAR2 DEFAULT NULL,
                                 p_pais_residencia   IN  VARCHAR2 DEFAULT 'CRI',
                                 p_id_cliente        OUT NUMBER);

    -- Cambia el limite de credito; con limite mayor a 0 el cliente queda como preferencial
    PROCEDURE asignar_credito (p_id_cliente IN NUMBER, p_limite IN NUMBER);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_CLIENTES AS

    FUNCTION id_pais (p_codigo IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_PAIS.PAI_ID%TYPE;
    BEGIN
        SELECT PAI_ID INTO v_id FROM SGS_PAIS WHERE PAI_CODIGO = UPPER(p_codigo);
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20046, 'No existe el pais ' || p_codigo);
    END;

    PROCEDURE registrar_nacional (p_cedula            IN  VARCHAR2,
                                  p_sexo              IN  VARCHAR2,
                                  p_estado_civil      IN  VARCHAR2 DEFAULT NULL,
                                  p_fecha_nac         IN  DATE     DEFAULT NULL,
                                  p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                  p_email             IN  VARCHAR2 DEFAULT NULL,
                                  p_direccion_casa    IN  VARCHAR2 DEFAULT NULL,
                                  p_direccion_trabajo IN  VARCHAR2 DEFAULT NULL,
                                  p_puesto            IN  VARCHAR2 DEFAULT NULL,
                                  p_empresa_labora    IN  VARCHAR2 DEFAULT NULL,
                                  p_asegurado         IN  VARCHAR2 DEFAULT NULL,
                                  p_escolaridad       IN  VARCHAR2 DEFAULT NULL,
                                  p_id_cliente        OUT NUMBER) IS
        v_padron SGS_PADRON%ROWTYPE;
        v_cri    SGS_PAIS.PAI_ID%TYPE;
    BEGIN
        SAVEPOINT sp_registrar_nacional;

        BEGIN
            SELECT * INTO v_padron FROM SGS_PADRON WHERE PAD_CEDULA = p_cedula;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20043, 'La cedula ' || p_cedula || ' no esta en el padron');
        END;

        v_cri := id_pais('CRI');

        INSERT INTO SGS_CLIENTE (CLI_ID, CLI_CEDULA, CLI_NOMBRE, CLI_TIPO_PERSONA, CLI_DIRECCION_CASA, CLI_DIRECCION_TRABAJO,
                                 CLI_TELEFONO, CLI_ID_PAIS_NACIONALIDAD, CLI_ID_PAIS_RESIDENCIA, CLI_EMAIL)
        VALUES (SEQ_CLIENTE.NEXTVAL, p_cedula, v_padron.PAD_NOMBRE, 'NACIONAL', p_direccion_casa, p_direccion_trabajo,
                p_telefono, v_cri, v_cri, p_email)
        RETURNING CLI_ID INTO p_id_cliente;

        INSERT INTO SGS_CLIENTE_PERSONA (CLP_ID, CLP_ID_CLIENTE, CLP_APELLIDO1, CLP_APELLIDO2, CLP_ESTADO_CIVIL, CLP_SEXO,
                                         CLP_FECHA_NAC, CLP_PUESTO, CLP_EMPRESA_LABORA, CLP_ASEGURADO, CLP_ESCOLARIDAD, CLP_ID_PADRON)
        VALUES (SEQ_CLIENTE_PERSONA.NEXTVAL, p_id_cliente, v_padron.PAD_APELLIDO1, v_padron.PAD_APELLIDO2, p_estado_civil, p_sexo,
                p_fecha_nac, p_puesto, p_empresa_labora, p_asegurado, p_escolaridad, v_padron.PAD_ID);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_nacional;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CLIENTES.registrar_nacional');
            RAISE;
    END;

    PROCEDURE registrar_extranjero (p_identificacion    IN  VARCHAR2,
                                    p_nombre            IN  VARCHAR2,
                                    p_apellido1         IN  VARCHAR2,
                                    p_apellido2         IN  VARCHAR2 DEFAULT NULL,
                                    p_pais_nacionalidad IN  VARCHAR2,
                                    p_pais_residencia   IN  VARCHAR2 DEFAULT 'CRI',
                                    p_sexo              IN  VARCHAR2 DEFAULT NULL,
                                    p_estado_civil      IN  VARCHAR2 DEFAULT NULL,
                                    p_fecha_nac         IN  DATE     DEFAULT NULL,
                                    p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                    p_email             IN  VARCHAR2 DEFAULT NULL,
                                    p_direccion_casa    IN  VARCHAR2 DEFAULT NULL,
                                    p_id_cliente        OUT NUMBER) IS
        -- Las funciones privadas no se pueden usar dentro de SQL: los paises se buscan antes
        v_nacionalidad SGS_PAIS.PAI_ID%TYPE := id_pais(p_pais_nacionalidad);
        v_residencia   SGS_PAIS.PAI_ID%TYPE := id_pais(p_pais_residencia);
    BEGIN
        SAVEPOINT sp_registrar_extranjero;

        INSERT INTO SGS_CLIENTE (CLI_ID, CLI_CEDULA, CLI_NOMBRE, CLI_TIPO_PERSONA, CLI_DIRECCION_CASA, CLI_TELEFONO,
                                 CLI_ID_PAIS_NACIONALIDAD, CLI_ID_PAIS_RESIDENCIA, CLI_EMAIL)
        VALUES (SEQ_CLIENTE.NEXTVAL, p_identificacion, UPPER(p_nombre), 'EXTRANJERO', p_direccion_casa, p_telefono,
                v_nacionalidad, v_residencia, p_email)
        RETURNING CLI_ID INTO p_id_cliente;

        INSERT INTO SGS_CLIENTE_PERSONA (CLP_ID, CLP_ID_CLIENTE, CLP_APELLIDO1, CLP_APELLIDO2, CLP_ESTADO_CIVIL, CLP_SEXO, CLP_FECHA_NAC)
        VALUES (SEQ_CLIENTE_PERSONA.NEXTVAL, p_id_cliente, UPPER(p_apellido1), UPPER(p_apellido2), p_estado_civil, p_sexo, p_fecha_nac);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_extranjero;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CLIENTES.registrar_extranjero');
            RAISE;
    END;

    PROCEDURE registrar_empresa (p_cedula_juridica   IN  VARCHAR2,
                                 p_nombre            IN  VARCHAR2,
                                 p_direccion_trabajo IN  VARCHAR2 DEFAULT NULL,
                                 p_telefono          IN  VARCHAR2 DEFAULT NULL,
                                 p_fax               IN  VARCHAR2 DEFAULT NULL,
                                 p_email             IN  VARCHAR2 DEFAULT NULL,
                                 p_pais_residencia   IN  VARCHAR2 DEFAULT 'CRI',
                                 p_id_cliente        OUT NUMBER) IS
        v_residencia SGS_PAIS.PAI_ID%TYPE := id_pais(p_pais_residencia);
    BEGIN
        SAVEPOINT sp_registrar_empresa;

        INSERT INTO SGS_CLIENTE (CLI_ID, CLI_CEDULA, CLI_NOMBRE, CLI_TIPO_PERSONA, CLI_DIRECCION_TRABAJO, CLI_TELEFONO,
                                 CLI_FAX, CLI_ID_PAIS_RESIDENCIA, CLI_EMAIL)
        VALUES (SEQ_CLIENTE.NEXTVAL, p_cedula_juridica, p_nombre, 'EMPRESA', p_direccion_trabajo, p_telefono,
                p_fax, v_residencia, p_email)
        RETURNING CLI_ID INTO p_id_cliente;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_empresa;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CLIENTES.registrar_empresa');
            RAISE;
    END;

    -- Bloquea la cuenta con NOWAIT: si otra sesion la esta usando (ej. facturando), falla de inmediato
    PROCEDURE asignar_credito (p_id_cliente IN NUMBER, p_limite IN NUMBER) IS
        v_saldo     SGS_CUENTA_COBRAR.CXC_SALDO%TYPE;
        e_bloqueado EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_bloqueado, -54);
    BEGIN
        SAVEPOINT sp_asignar_credito;

        SELECT CXC_SALDO
          INTO v_saldo
          FROM SGS_CUENTA_COBRAR
         WHERE CXC_ID_CLIENTE = p_id_cliente
           FOR UPDATE NOWAIT;

        IF p_limite < v_saldo THEN
            RAISE_APPLICATION_ERROR(-20044, 'El limite (' || p_limite || ') no puede ser menor a lo que el cliente debe (' || v_saldo || ')');
        END IF;

        UPDATE SGS_CUENTA_COBRAR
           SET CXC_LIMITE_CREDITO = p_limite
         WHERE CXC_ID_CLIENTE = p_id_cliente;

        UPDATE SGS_CLIENTE
           SET CLI_ES_PREFERENCIAL = CASE WHEN p_limite > 0 THEN 'S' ELSE 'N' END
         WHERE CLI_ID = p_id_cliente;

        COMMIT;
    EXCEPTION
        WHEN e_bloqueado THEN
            ROLLBACK TO sp_asignar_credito;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CLIENTES.asignar_credito');
            RAISE_APPLICATION_ERROR(-20045, 'La cuenta del cliente ' || p_id_cliente || ' la esta usando otra sesion');
        WHEN OTHERS THEN
            ROLLBACK TO sp_asignar_credito;
            SGS_PKG_ERRORES.registrar('SGS_PKG_CLIENTES.asignar_credito');
            RAISE;
    END;

END;
/

-- 3. Historial de precios de costo
-- Al crear un producto o cambiar su costo queda el registro; si el costo no cambia, no se registra nada
CREATE OR REPLACE TRIGGER TRG_PRO_HISTORICO_PRECIO
AFTER INSERT OR UPDATE OF PRO_PRECIO_COSTO ON SGS_PRODUCTO
FOR EACH ROW
BEGIN
    IF INSERTING OR :OLD.PRO_PRECIO_COSTO <> :NEW.PRO_PRECIO_COSTO THEN
        INSERT INTO SGS_HISTORICO_PRECIO (HPR_ID, HPR_ID_PRODUCTO, HPR_PRECIO_ANT, HPR_PRECIO_NUE)
        VALUES (SEQ_HISTORICO_PRECIO.NEXTVAL, :NEW.PRO_ID, :OLD.PRO_PRECIO_COSTO, :NEW.PRO_PRECIO_COSTO);
    END IF;
END;
/

-- 4. Existencias a partir de los movimientos de inventario
-- Errores propios: -20050 existencia insuficiente, -20051 movimiento no modificable

-- Entradas suman a la existencia del lote en la sucursal (la crea si no existe); salidas restan si alcanza
CREATE OR REPLACE TRIGGER TRG_MOV_EXISTENCIA
AFTER INSERT ON SGS_MOVIMIENTO_INVENTARIO
FOR EACH ROW
BEGIN
    IF :NEW.MOV_TIPO IN ('COMPRA', 'DEVOLUCION_CLIENTE', 'TRASLADO_ENTRADA') THEN
        MERGE INTO SGS_EXISTENCIA e
        USING (SELECT :NEW.MOV_ID_LOTE AS LOTE, :NEW.MOV_ID_SUCURSAL AS SUCURSAL FROM DUAL) m
           ON (e.EXI_ID_LOTE = m.LOTE AND e.EXI_ID_SUCURSAL = m.SUCURSAL)
         WHEN MATCHED THEN
              UPDATE SET e.EXI_CANTIDAD = e.EXI_CANTIDAD + :NEW.MOV_CANTIDAD
         WHEN NOT MATCHED THEN
              INSERT (EXI_ID, EXI_ID_LOTE, EXI_ID_SUCURSAL, EXI_CANTIDAD)
              VALUES (SEQ_EXISTENCIA.NEXTVAL, m.LOTE, m.SUCURSAL, :NEW.MOV_CANTIDAD);
    ELSE
        UPDATE SGS_EXISTENCIA
           SET EXI_CANTIDAD = EXI_CANTIDAD - :NEW.MOV_CANTIDAD
         WHERE EXI_ID_LOTE = :NEW.MOV_ID_LOTE
           AND EXI_ID_SUCURSAL = :NEW.MOV_ID_SUCURSAL
           AND EXI_CANTIDAD >= :NEW.MOV_CANTIDAD;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20050, 'Existencia insuficiente del lote ' || :NEW.MOV_ID_LOTE
                                            || ' en la sucursal ' || :NEW.MOV_ID_SUCURSAL);
        END IF;
    END IF;
END;
/

-- Los movimientos son la historia del inventario: un error se corrige con otro movimiento, nunca editando o borrando
CREATE OR REPLACE TRIGGER TRG_MOV_INMUTABLE
BEFORE UPDATE OR DELETE ON SGS_MOVIMIENTO_INVENTARIO
BEGIN
    RAISE_APPLICATION_ERROR(-20051, 'Los movimientos de inventario no se modifican ni se borran; se corrigen con otro movimiento');
END;
/
