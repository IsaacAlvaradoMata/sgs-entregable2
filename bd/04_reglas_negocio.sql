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

-- 7. Compras
-- Errores propios: -20070 producto de otro proveedor, -20071 cuenta en uso por otra sesion, -20072 usuario no existe o inactivo,
-- -20073 tipo de pago no existe, -20074 compra sin lineas, -20075 proveedor no existe o inactivo, -20076 producto no existe,
-- -20077 factura no existe, -20078 factura sin saldo pendiente, -20079 producto no esta en la factura,
-- -20080 devolucion mayor a lo comprado, -20081 linea de otra factura

-- No se puede devolver mas de lo comprado (sumando todas las notas) ni una linea de otra factura
CREATE OR REPLACE TRIGGER TRG_DNCP_VALIDA
BEFORE INSERT ON SGS_DETALLE_NOTA_CREDITO_PROVEEDOR
FOR EACH ROW
DECLARE
    v_comprada        SGS_DETALLE_FACTURA_PROVEEDOR.DFP_CANTIDAD%TYPE;
    v_factura_linea   SGS_DETALLE_FACTURA_PROVEEDOR.DFP_ID_FACTURA%TYPE;
    v_factura_nota    SGS_NOTA_CREDITO_PROVEEDOR.NCP_ID_FACTURA%TYPE;
    v_devuelta        NUMBER;
BEGIN
    SELECT DFP_CANTIDAD, DFP_ID_FACTURA
      INTO v_comprada, v_factura_linea
      FROM SGS_DETALLE_FACTURA_PROVEEDOR
     WHERE DFP_ID = :NEW.DNCP_ID_DETALLE_FACTURA;

    SELECT NCP_ID_FACTURA
      INTO v_factura_nota
      FROM SGS_NOTA_CREDITO_PROVEEDOR
     WHERE NCP_ID = :NEW.DNCP_ID_NOTA;

    IF v_factura_linea <> v_factura_nota THEN
        RAISE_APPLICATION_ERROR(-20081, 'La linea devuelta no pertenece a la factura de la nota de credito');
    END IF;

    SELECT NVL(SUM(DNCP_CANTIDAD), 0)
      INTO v_devuelta
      FROM SGS_DETALLE_NOTA_CREDITO_PROVEEDOR
     WHERE DNCP_ID_DETALLE_FACTURA = :NEW.DNCP_ID_DETALLE_FACTURA;

    IF v_devuelta + :NEW.DNCP_CANTIDAD > v_comprada THEN
        RAISE_APPLICATION_ERROR(-20080, 'No se puede devolver mas de lo comprado (comprado ' || v_comprada
                                        || ', ya devuelto ' || v_devuelta || ')');
    END IF;
EXCEPTION
    -- Si la linea o la nota no existen, la llave foranea da el error correspondiente
    WHEN NO_DATA_FOUND THEN
        NULL;
END;
/

CREATE OR REPLACE PACKAGE SGS_PKG_COMPRAS AS
    -- Linea de compra: codigo del producto, cantidad, costo unitario y vencimiento del lote (nulo si no vence)
    TYPE t_linea IS RECORD (codigo VARCHAR2(30), cantidad NUMBER, costo NUMBER, vencimiento DATE);
    TYPE t_lineas IS TABLE OF t_linea INDEX BY PLS_INTEGER;

    -- Linea devuelta: codigo del producto y cantidad
    TYPE t_linea_devolucion IS RECORD (codigo VARCHAR2(30), cantidad NUMBER);
    TYPE t_lineas_devolucion IS TABLE OF t_linea_devolucion INDEX BY PLS_INTEGER;

    -- Registra la factura del proveedor, sus lotes y la entrada a la bodega central
    PROCEDURE registrar_compra (p_proveedor  IN  VARCHAR2,
                                p_numero     IN  VARCHAR2,
                                p_usuario    IN  VARCHAR2,
                                p_es_credito IN  VARCHAR2,
                                p_lineas     IN  t_lineas,
                                p_tipo_pago  IN  VARCHAR2 DEFAULT 'Transferencia',
                                p_id_factura OUT NUMBER);

    -- Abono a una factura de proveedor a credito
    PROCEDURE registrar_pago (p_id_factura IN NUMBER,
                              p_monto      IN NUMBER,
                              p_tipo_pago  IN VARCHAR2 DEFAULT 'Transferencia');

    -- Devolucion al proveedor: sale de la bodega central el lote que entro con esa compra
    PROCEDURE registrar_devolucion (p_id_factura IN  NUMBER,
                                    p_lineas     IN  t_lineas_devolucion,
                                    p_motivo     IN  VARCHAR2,
                                    p_usuario    IN  VARCHAR2,
                                    p_id_nota    OUT NUMBER);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_COMPRAS AS

    -- Las funciones privadas no se usan dentro de SQL: su resultado se guarda antes en variables

    FUNCTION id_usuario (p_username IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_USUARIO.USU_ID%TYPE;
    BEGIN
        SELECT USU_ID INTO v_id FROM SGS_USUARIO WHERE USU_USERNAME = LOWER(p_username) AND USU_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20072, 'No existe o no esta activo el usuario ' || p_username);
    END;

    FUNCTION id_tipo_pago (p_nombre IN VARCHAR2) RETURN NUMBER IS
        v_id SGS_TIPO_PAGO.TPA_ID%TYPE;
    BEGIN
        SELECT TPA_ID INTO v_id FROM SGS_TIPO_PAGO WHERE TPA_NOMBRE = p_nombre AND TPA_ESTADO = 'A';
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20073, 'No existe el tipo de pago ' || p_nombre);
    END;

    FUNCTION id_central RETURN NUMBER IS
        v_id SGS_SUCURSAL.SUC_ID%TYPE;
    BEGIN
        SELECT SUC_ID INTO v_id FROM SGS_SUCURSAL WHERE SUC_ES_CENTRAL = 'S';
        RETURN v_id;
    END;

    PROCEDURE registrar_compra (p_proveedor  IN  VARCHAR2,
                                p_numero     IN  VARCHAR2,
                                p_usuario    IN  VARCHAR2,
                                p_es_credito IN  VARCHAR2,
                                p_lineas     IN  t_lineas,
                                p_tipo_pago  IN  VARCHAR2 DEFAULT 'Transferencia',
                                p_id_factura OUT NUMBER) IS
        v_prv_id     SGS_PROVEEDOR.PRV_ID%TYPE;
        v_prv_estado SGS_PROVEEDOR.PRV_ESTADO%TYPE;
        v_usuario    SGS_USUARIO.USU_ID%TYPE;
        v_central    SGS_SUCURSAL.SUC_ID%TYPE;
        v_tipo_pago  SGS_TIPO_PAGO.TPA_ID%TYPE;
        v_cuenta     SGS_CUENTA_PAGAR.CXP_ID%TYPE;
        v_pro_id     SGS_PRODUCTO.PRO_ID%TYPE;
        v_pro_prv    SGS_PRODUCTO.PRO_ID_PROVEEDOR%TYPE;
        v_costo_act  SGS_PRODUCTO.PRO_PRECIO_COSTO%TYPE;
        v_pct_imp    SGS_ARTICULO_FACTURABLE.ART_PCT_IMPUESTO%TYPE;
        v_subtotal   NUMBER := 0;
        v_impuesto   NUMBER := 0;
        v_imp_linea  NUMBER;
        v_dfp_id     SGS_DETALLE_FACTURA_PROVEEDOR.DFP_ID%TYPE;
        v_lote_id    SGS_LOTE.LOT_ID%TYPE;
        v_i          PLS_INTEGER;
        e_espera     EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
    BEGIN
        SAVEPOINT sp_registrar_compra;

        IF p_lineas.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20074, 'La compra no tiene lineas');
        END IF;

        BEGIN
            SELECT PRV_ID, PRV_ESTADO INTO v_prv_id, v_prv_estado
              FROM SGS_PROVEEDOR WHERE PRV_CEDULA_JURIDICA = p_proveedor;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prv_estado := NULL;
        END;
        IF v_prv_estado IS NULL OR v_prv_estado <> 'A' THEN
            RAISE_APPLICATION_ERROR(-20075, 'No existe o no esta activo el proveedor ' || p_proveedor);
        END IF;

        v_usuario := id_usuario(p_usuario);
        v_central := id_central;

        -- A credito: se bloquea la cuenta del proveedor; si otra sesion la usa, espera hasta 5 segundos
        IF p_es_credito = 'S' THEN
            SELECT CXP_ID INTO v_cuenta
              FROM SGS_CUENTA_PAGAR
             WHERE CXP_ID_PROVEEDOR = v_prv_id
               FOR UPDATE WAIT 5;
        END IF;

        -- Primera pasada: validar productos y calcular totales
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            BEGIN
                SELECT p.PRO_ID_PROVEEDOR, a.ART_PCT_IMPUESTO
                  INTO v_pro_prv, v_pct_imp
                  FROM SGS_PRODUCTO p
                  JOIN SGS_ARTICULO_FACTURABLE a ON a.ART_ID = p.PRO_ID_ARTICULO
                 WHERE p.PRO_CODIGO = p_lineas(v_i).codigo;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20076, 'No existe el producto ' || p_lineas(v_i).codigo);
            END;
            IF v_pro_prv <> v_prv_id THEN
                RAISE_APPLICATION_ERROR(-20070, 'El producto ' || p_lineas(v_i).codigo || ' no es de este proveedor');
            END IF;
            v_subtotal := v_subtotal + p_lineas(v_i).cantidad * p_lineas(v_i).costo;
            v_impuesto := v_impuesto + ROUND(p_lineas(v_i).cantidad * p_lineas(v_i).costo * v_pct_imp, 2);
            v_i := p_lineas.NEXT(v_i);
        END LOOP;

        -- La factura a credito queda pendiente (los triggers la llevan a la cuenta por pagar); la de contado, cancelada
        INSERT INTO SGS_FACTURA_PROVEEDOR (FP_ID, FP_ID_PROVEEDOR, FP_ID_USUARIO, FP_NUMERO, FP_SUBTOTAL, FP_IMPUESTO,
                                           FP_TOTAL, FP_ES_CREDITO, FP_ESTADO)
        VALUES (SEQ_FACTURA_PROVEEDOR.NEXTVAL, v_prv_id, v_usuario, p_numero, v_subtotal, v_impuesto,
                v_subtotal + v_impuesto, p_es_credito, CASE WHEN p_es_credito = 'S' THEN 'P' ELSE 'C' END)
        RETURNING FP_ID INTO p_id_factura;

        -- Segunda pasada: detalle, lote y entrada a la bodega central; costo distinto actualiza el producto
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            SELECT p.PRO_ID, p.PRO_PRECIO_COSTO, a.ART_PCT_IMPUESTO
              INTO v_pro_id, v_costo_act, v_pct_imp
              FROM SGS_PRODUCTO p
              JOIN SGS_ARTICULO_FACTURABLE a ON a.ART_ID = p.PRO_ID_ARTICULO
             WHERE p.PRO_CODIGO = p_lineas(v_i).codigo;

            v_imp_linea := ROUND(p_lineas(v_i).cantidad * p_lineas(v_i).costo * v_pct_imp, 2);

            INSERT INTO SGS_DETALLE_FACTURA_PROVEEDOR (DFP_ID, DFP_ID_FACTURA, DFP_ID_PRODUCTO, DFP_CANTIDAD,
                                                       DFP_PRECIO_UNITARIO, DFP_IMPUESTO, DFP_SUBTOTAL)
            VALUES (SEQ_DETALLE_FACTURA_PROVEEDOR.NEXTVAL, p_id_factura, v_pro_id, p_lineas(v_i).cantidad,
                    p_lineas(v_i).costo, v_imp_linea, p_lineas(v_i).cantidad * p_lineas(v_i).costo + v_imp_linea)
            RETURNING DFP_ID INTO v_dfp_id;

            INSERT INTO SGS_LOTE (LOT_ID, LOT_ID_DETALLE_COMPRA, LOT_FECHA_VENCIMIENTO)
            VALUES (SEQ_LOTE.NEXTVAL, v_dfp_id, p_lineas(v_i).vencimiento)
            RETURNING LOT_ID INTO v_lote_id;

            INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_COMPRA)
            VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, v_lote_id, v_central, 'COMPRA', p_lineas(v_i).cantidad, v_dfp_id);

            IF p_lineas(v_i).costo <> v_costo_act THEN
                UPDATE SGS_PRODUCTO SET PRO_PRECIO_COSTO = p_lineas(v_i).costo WHERE PRO_ID = v_pro_id;
            END IF;

            v_i := p_lineas.NEXT(v_i);
        END LOOP;

        -- De contado: se registra el pago completo
        IF p_es_credito = 'N' THEN
            v_tipo_pago := id_tipo_pago(p_tipo_pago);
            INSERT INTO SGS_PAGO_FACTURA_PROVEEDOR (PFP_ID, PFP_ID_FACTURA, PFP_ID_TIPO_PAGO, PFP_MONTO)
            VALUES (SEQ_PAGO_FACTURA_PROVEEDOR.NEXTVAL, p_id_factura, v_tipo_pago, v_subtotal + v_impuesto);
        END IF;

        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_compra;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_compra');
            RAISE_APPLICATION_ERROR(-20071, 'La cuenta del proveedor la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_compra;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_compra');
            RAISE;
    END;

    PROCEDURE registrar_pago (p_id_factura IN NUMBER,
                              p_monto      IN NUMBER,
                              p_tipo_pago  IN VARCHAR2 DEFAULT 'Transferencia') IS
        v_credito   SGS_FACTURA_PROVEEDOR.FP_ES_CREDITO%TYPE;
        v_estado    SGS_FACTURA_PROVEEDOR.FP_ESTADO%TYPE;
        v_prv_id    SGS_FACTURA_PROVEEDOR.FP_ID_PROVEEDOR%TYPE;
        v_cuenta    SGS_CUENTA_PAGAR.CXP_ID%TYPE;
        v_tipo_pago SGS_TIPO_PAGO.TPA_ID%TYPE;
        e_espera    EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);
    BEGIN
        SAVEPOINT sp_registrar_pago;

        BEGIN
            SELECT FP_ES_CREDITO, FP_ESTADO, FP_ID_PROVEEDOR INTO v_credito, v_estado, v_prv_id
              FROM SGS_FACTURA_PROVEEDOR WHERE FP_ID = p_id_factura;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20077, 'No existe la factura de proveedor ' || p_id_factura);
        END;
        IF v_credito <> 'S' OR v_estado <> 'P' THEN
            RAISE_APPLICATION_ERROR(-20078, 'La factura ' || p_id_factura || ' no tiene saldo pendiente');
        END IF;

        -- Se bloquea la cuenta del proveedor mientras se aplica el pago
        SELECT CXP_ID INTO v_cuenta
          FROM SGS_CUENTA_PAGAR
         WHERE CXP_ID_PROVEEDOR = v_prv_id
           FOR UPDATE WAIT 5;

        v_tipo_pago := id_tipo_pago(p_tipo_pago);
        INSERT INTO SGS_PAGO_FACTURA_PROVEEDOR (PFP_ID, PFP_ID_FACTURA, PFP_ID_TIPO_PAGO, PFP_MONTO)
        VALUES (SEQ_PAGO_FACTURA_PROVEEDOR.NEXTVAL, p_id_factura, v_tipo_pago, p_monto);

        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_pago;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_pago');
            RAISE_APPLICATION_ERROR(-20071, 'La cuenta del proveedor la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_pago;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_pago');
            RAISE;
    END;

    PROCEDURE registrar_devolucion (p_id_factura IN  NUMBER,
                                    p_lineas     IN  t_lineas_devolucion,
                                    p_motivo     IN  VARCHAR2,
                                    p_usuario    IN  VARCHAR2,
                                    p_id_nota    OUT NUMBER) IS
        v_estado    SGS_FACTURA_PROVEEDOR.FP_ESTADO%TYPE;
        v_credito   SGS_FACTURA_PROVEEDOR.FP_ES_CREDITO%TYPE;
        v_prv_id    SGS_FACTURA_PROVEEDOR.FP_ID_PROVEEDOR%TYPE;
        v_usuario   SGS_USUARIO.USU_ID%TYPE;
        v_central   SGS_SUCURSAL.SUC_ID%TYPE;
        v_cuenta    SGS_CUENTA_PAGAR.CXP_ID%TYPE;
        v_dfp_id    SGS_DETALLE_FACTURA_PROVEEDOR.DFP_ID%TYPE;
        v_cantidad  SGS_DETALLE_FACTURA_PROVEEDOR.DFP_CANTIDAD%TYPE;
        v_total_lin SGS_DETALLE_FACTURA_PROVEEDOR.DFP_SUBTOTAL%TYPE;
        v_lote_id   SGS_LOTE.LOT_ID%TYPE;
        v_monto     NUMBER := 0;
        v_monto_lin NUMBER;
        v_dncp_id   SGS_DETALLE_NOTA_CREDITO_PROVEEDOR.DNCP_ID%TYPE;
        v_i         PLS_INTEGER;
        e_espera    EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_espera, -30006);

        -- Linea de la factura donde se compro el producto y el lote que nacio de ella
        PROCEDURE buscar_linea (p_codigo IN VARCHAR2) IS
        BEGIN
            SELECT d.DFP_ID, d.DFP_CANTIDAD, d.DFP_SUBTOTAL, l.LOT_ID
              INTO v_dfp_id, v_cantidad, v_total_lin, v_lote_id
              FROM SGS_DETALLE_FACTURA_PROVEEDOR d
              JOIN SGS_PRODUCTO p ON p.PRO_ID = d.DFP_ID_PRODUCTO
              JOIN SGS_LOTE l ON l.LOT_ID_DETALLE_COMPRA = d.DFP_ID
             WHERE d.DFP_ID_FACTURA = p_id_factura
               AND p.PRO_CODIGO = p_codigo;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20079, 'El producto ' || p_codigo || ' no esta en la factura ' || p_id_factura);
        END;
    BEGIN
        SAVEPOINT sp_registrar_devolucion;

        BEGIN
            SELECT FP_ESTADO, FP_ES_CREDITO, FP_ID_PROVEEDOR INTO v_estado, v_credito, v_prv_id
              FROM SGS_FACTURA_PROVEEDOR WHERE FP_ID = p_id_factura;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20077, 'No existe la factura de proveedor ' || p_id_factura);
        END;

        v_usuario := id_usuario(p_usuario);
        v_central := id_central;

        -- Si la nota rebaja un saldo pendiente, se bloquea la cuenta del proveedor
        IF v_credito = 'S' AND v_estado = 'P' THEN
            SELECT CXP_ID INTO v_cuenta
              FROM SGS_CUENTA_PAGAR
             WHERE CXP_ID_PROVEEDOR = v_prv_id
               FOR UPDATE WAIT 5;
        END IF;

        -- Monto de la nota: parte proporcional del total de cada linea devuelta
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            buscar_linea(p_lineas(v_i).codigo);
            v_monto := v_monto + ROUND(v_total_lin * p_lineas(v_i).cantidad / v_cantidad, 2);
            v_i := p_lineas.NEXT(v_i);
        END LOOP;

        INSERT INTO SGS_NOTA_CREDITO_PROVEEDOR (NCP_ID, NCP_ID_FACTURA, NCP_ID_USUARIO, NCP_MOTIVO, NCP_MONTO)
        VALUES (SEQ_NOTA_CREDITO_PROVEEDOR.NEXTVAL, p_id_factura, v_usuario, p_motivo, v_monto)
        RETURNING NCP_ID INTO p_id_nota;

        -- Cada linea devuelta sale de la bodega central desde su lote
        v_i := p_lineas.FIRST;
        WHILE v_i IS NOT NULL LOOP
            buscar_linea(p_lineas(v_i).codigo);
            v_monto_lin := ROUND(v_total_lin * p_lineas(v_i).cantidad / v_cantidad, 2);

            INSERT INTO SGS_DETALLE_NOTA_CREDITO_PROVEEDOR (DNCP_ID, DNCP_ID_NOTA, DNCP_ID_DETALLE_FACTURA, DNCP_CANTIDAD, DNCP_SUBTOTAL)
            VALUES (SEQ_DETALLE_NOTA_CREDITO_PROVEEDOR.NEXTVAL, p_id_nota, v_dfp_id, p_lineas(v_i).cantidad, v_monto_lin)
            RETURNING DNCP_ID INTO v_dncp_id;

            INSERT INTO SGS_MOVIMIENTO_INVENTARIO (MOV_ID, MOV_ID_LOTE, MOV_ID_SUCURSAL, MOV_TIPO, MOV_CANTIDAD, MOV_ID_DETALLE_NC_PROVEEDOR)
            VALUES (SEQ_MOVIMIENTO_INVENTARIO.NEXTVAL, v_lote_id, v_central, 'DEVOLUCION_PROVEEDOR', p_lineas(v_i).cantidad, v_dncp_id);

            v_i := p_lineas.NEXT(v_i);
        END LOOP;

        COMMIT;
    EXCEPTION
        WHEN e_espera THEN
            ROLLBACK TO sp_registrar_devolucion;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_devolucion');
            RAISE_APPLICATION_ERROR(-20071, 'La cuenta del proveedor la esta usando otra sesion; intente de nuevo');
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_devolucion;
            SGS_PKG_ERRORES.registrar('SGS_PKG_COMPRAS.registrar_devolucion');
            RAISE;
    END;

END;
/

-- 8. Inventario: seleccion de lotes por FEFO y traslados
-- Errores propios: -20090 existencia insuficiente, -20091 sucursal no existe, -20092 producto no existe,
-- -20093 traslado sin lineas, -20094 existencias en uso por otra sesion, -20095 usuario no existe o inactivo

CREATE OR REPLACE PACKAGE SGS_PKG_INVENTARIO AS
    -- Lote y cantidad que se toma de el
    TYPE t_asignacion IS RECORD (id_lote NUMBER, cantidad NUMBER);
    TYPE t_asignaciones IS TABLE OF t_asignacion INDEX BY PLS_INTEGER;

    -- Linea de traslado: codigo del producto y cantidad
    TYPE t_linea IS RECORD (codigo VARCHAR2(30), cantidad NUMBER);
    TYPE t_lineas IS TABLE OF t_linea INDEX BY PLS_INTEGER;

    -- Reparte la cantidad entre los lotes de la sucursal, primero los que vencen antes (FEFO), y los deja bloqueados
    -- hasta que el que llama haga COMMIT o ROLLBACK. No registra movimientos: eso lo hace el que llama
    FUNCTION reservar_fefo (p_id_sucursal IN NUMBER, p_id_producto IN NUMBER, p_cantidad IN NUMBER) RETURN t_asignaciones;

    -- Traslada productos entre sucursales (normalmente de la bodega central a una sucursal)
    PROCEDURE trasladar (p_origen      IN  VARCHAR2,
                         p_destino     IN  VARCHAR2,
                         p_usuario     IN  VARCHAR2,
                         p_lineas      IN  t_lineas,
                         p_id_traslado OUT NUMBER);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_INVENTARIO AS

    -- Las funciones privadas no se usan dentro de SQL: su resultado se guarda antes en variables

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
        -- Lotes con existencia y sin vencer, del que vence antes al que vence despues; los que no vencen, por ingreso
        -- Se bloquean con WAIT 5: si otra sesion los esta usando, se espera hasta 5 segundos
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

        -- Por cada lote asignado: su detalle, la salida del origen y la entrada al destino
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
/
