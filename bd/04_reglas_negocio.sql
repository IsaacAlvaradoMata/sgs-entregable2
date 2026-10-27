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

-- 5. Cuentas por cobrar
-- Errores propios: -20060 cliente sin credito, -20061 supera el limite, -20062 pago mayor al saldo

-- Solo un cliente preferencial y activo (y no el cliente por defecto) compra a credito
CREATE OR REPLACE TRIGGER TRG_FV_VALIDA_CREDITO
BEFORE INSERT OR UPDATE OF FV_ES_CREDITO, FV_ID_CLIENTE ON SGS_FACTURA_VENTA
FOR EACH ROW
WHEN (NEW.FV_ES_CREDITO = 'S')
DECLARE
    v_preferencial SGS_CLIENTE.CLI_ES_PREFERENCIAL%TYPE;
    v_estado       SGS_CLIENTE.CLI_ESTADO%TYPE;
    v_defecto      SGS_CLIENTE.CLI_ES_DEFECTO%TYPE;
BEGIN
    SELECT CLI_ES_PREFERENCIAL, CLI_ESTADO, CLI_ES_DEFECTO
      INTO v_preferencial, v_estado, v_defecto
      FROM SGS_CLIENTE
     WHERE CLI_ID = :NEW.FV_ID_CLIENTE;

    IF v_preferencial <> 'S' OR v_estado <> 'A' OR v_defecto = 'S' THEN
        RAISE_APPLICATION_ERROR(-20060, 'El cliente no puede comprar a credito: debe ser preferencial y estar activo');
    END IF;
EXCEPTION
    -- Si el cliente no existe, la llave foranea da el error correspondiente
    WHEN NO_DATA_FOUND THEN
        NULL;
END;
/

-- Factura a credito pendiente: entra al detalle de la cuenta por cobrar del cliente
CREATE OR REPLACE TRIGGER TRG_FV_CUENTA_COBRAR
AFTER INSERT ON SGS_FACTURA_VENTA
FOR EACH ROW
WHEN (NEW.FV_ES_CREDITO = 'S' AND NEW.FV_ESTADO = 'P')
BEGIN
    INSERT INTO SGS_DETALLE_CUENTA_COBRAR (DCC_ID, DCC_ID_CUENTA, DCC_ID_FACTURA, DCC_MONTO_ORIGINAL, DCC_SALDO)
    SELECT SEQ_DETALLE_CUENTA_COBRAR.NEXTVAL, CXC_ID, :NEW.FV_ID, :NEW.FV_TOTAL, :NEW.FV_TOTAL
      FROM SGS_CUENTA_COBRAR
     WHERE CXC_ID_CLIENTE = :NEW.FV_ID_CLIENTE;
END;
/

-- Cada cambio en el saldo de una factura se refleja en el saldo total de la cuenta;
-- el CHECK de la cuenta impide superar el limite. Saldo de la factura en 0: pasa a cancelada
CREATE OR REPLACE TRIGGER TRG_DCC_SALDO
AFTER INSERT OR UPDATE OF DCC_SALDO ON SGS_DETALLE_CUENTA_COBRAR
FOR EACH ROW
DECLARE
    e_check EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_check, -2290);
BEGIN
    UPDATE SGS_CUENTA_COBRAR
       SET CXC_SALDO = CXC_SALDO + (:NEW.DCC_SALDO - NVL(:OLD.DCC_SALDO, 0))
     WHERE CXC_ID = :NEW.DCC_ID_CUENTA;

    IF UPDATING AND :NEW.DCC_SALDO = 0 THEN
        UPDATE SGS_FACTURA_VENTA
           SET FV_ESTADO = 'C'
         WHERE FV_ID = :NEW.DCC_ID_FACTURA
           AND FV_ESTADO = 'P';
    END IF;
EXCEPTION
    WHEN e_check THEN
        RAISE_APPLICATION_ERROR(-20061, 'La factura supera el limite de credito del cliente');
END;
/

-- Un pago o abono a una factura a credito baja su saldo (las de contado no tienen detalle en la cuenta)
CREATE OR REPLACE TRIGGER TRG_PFV_ABONO
AFTER INSERT ON SGS_PAGO_FACTURA_VENTA
FOR EACH ROW
DECLARE
    e_check EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_check, -2290);
BEGIN
    UPDATE SGS_DETALLE_CUENTA_COBRAR
       SET DCC_SALDO = DCC_SALDO - :NEW.PFV_MONTO
     WHERE DCC_ID_FACTURA = :NEW.PFV_ID_FACTURA;
EXCEPTION
    WHEN e_check THEN
        RAISE_APPLICATION_ERROR(-20062, 'El pago supera el saldo pendiente de la factura');
END;
/

-- Una nota de credito rebaja el saldo pendiente de la factura, hasta dejarlo en 0
CREATE OR REPLACE TRIGGER TRG_NCV_SALDO
AFTER INSERT ON SGS_NOTA_CREDITO_VENTA
FOR EACH ROW
BEGIN
    UPDATE SGS_DETALLE_CUENTA_COBRAR
       SET DCC_SALDO = GREATEST(DCC_SALDO - :NEW.NCV_MONTO, 0)
     WHERE DCC_ID_FACTURA = :NEW.NCV_ID_FACTURA
       AND DCC_SALDO > 0;
END;
/

-- 6. Cuentas por pagar (mismas reglas del lado de los proveedores)
-- Errores propios: -20063 supera el limite con el proveedor, -20064 pago mayor al saldo

CREATE OR REPLACE TRIGGER TRG_FP_CUENTA_PAGAR
AFTER INSERT ON SGS_FACTURA_PROVEEDOR
FOR EACH ROW
WHEN (NEW.FP_ES_CREDITO = 'S' AND NEW.FP_ESTADO = 'P')
BEGIN
    INSERT INTO SGS_DETALLE_CUENTA_PAGAR (DCP_ID, DCP_ID_CUENTA, DCP_ID_FACTURA, DCP_MONTO_ORIGINAL, DCP_SALDO)
    SELECT SEQ_DETALLE_CUENTA_PAGAR.NEXTVAL, CXP_ID, :NEW.FP_ID, :NEW.FP_TOTAL, :NEW.FP_TOTAL
      FROM SGS_CUENTA_PAGAR
     WHERE CXP_ID_PROVEEDOR = :NEW.FP_ID_PROVEEDOR;
END;
/

CREATE OR REPLACE TRIGGER TRG_DCP_SALDO
AFTER INSERT OR UPDATE OF DCP_SALDO ON SGS_DETALLE_CUENTA_PAGAR
FOR EACH ROW
DECLARE
    e_check EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_check, -2290);
BEGIN
    UPDATE SGS_CUENTA_PAGAR
       SET CXP_SALDO = CXP_SALDO + (:NEW.DCP_SALDO - NVL(:OLD.DCP_SALDO, 0))
     WHERE CXP_ID = :NEW.DCP_ID_CUENTA;

    IF UPDATING AND :NEW.DCP_SALDO = 0 THEN
        UPDATE SGS_FACTURA_PROVEEDOR
           SET FP_ESTADO = 'C'
         WHERE FP_ID = :NEW.DCP_ID_FACTURA
           AND FP_ESTADO = 'P';
    END IF;
EXCEPTION
    WHEN e_check THEN
        RAISE_APPLICATION_ERROR(-20063, 'La factura supera el limite de credito con el proveedor');
END;
/

CREATE OR REPLACE TRIGGER TRG_PFP_ABONO
AFTER INSERT ON SGS_PAGO_FACTURA_PROVEEDOR
FOR EACH ROW
DECLARE
    e_check EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_check, -2290);
BEGIN
    UPDATE SGS_DETALLE_CUENTA_PAGAR
       SET DCP_SALDO = DCP_SALDO - :NEW.PFP_MONTO
     WHERE DCP_ID_FACTURA = :NEW.PFP_ID_FACTURA;
EXCEPTION
    WHEN e_check THEN
        RAISE_APPLICATION_ERROR(-20064, 'El pago supera el saldo pendiente con el proveedor');
END;
/

CREATE OR REPLACE TRIGGER TRG_NCP_SALDO
AFTER INSERT ON SGS_NOTA_CREDITO_PROVEEDOR
FOR EACH ROW
BEGIN
    UPDATE SGS_DETALLE_CUENTA_PAGAR
       SET DCP_SALDO = GREATEST(DCP_SALDO - :NEW.NCP_MONTO, 0)
     WHERE DCP_ID_FACTURA = :NEW.NCP_ID_FACTURA
       AND DCP_SALDO > 0;
END;
/
