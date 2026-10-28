-- 07_procesos.sql: procesos automaticos del negocio y sus notificaciones, programados con DBMS_SCHEDULER.
-- Se ejecuta como SGS_ADMIN en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB en SGSPRI).
-- Requiere haber ejecutado 03_base_interna.sql (correo y parametros) y 04_reglas_negocio.sql.
-- Errores propios: -20120 correos que no se pudieron enviar

-- 1. Validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Procesos
-- Cada procedimiento lo ejecuta su job; tambien se puede llamar directo para correrlo a demanda.
-- Si un proceso no encuentra casos, no envia correo.
CREATE OR REPLACE PACKAGE SGS_PKG_PROCESOS AS
    -- Aviso a cada cliente que debe el porcentaje PCT_AVISO_CLIENTE o mas de su limite de credito
    PROCEDURE avisar_clientes_limite;
    -- Un solo correo al coordinador con todos los clientes que deben el porcentaje PCT_AVISO_COORDINADOR o mas de su limite
    PROCEDURE avisar_coordinador_limite;
    -- Un solo correo al gerente si a algun proveedor se le debe el porcentaje PCT_AVISO_GERENTE_CXP o mas de su limite
    PROCEDURE avisar_gerente_proveedores;
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_PROCESOS AS

    -- Clientes activos con credito que deben el porcentaje indicado o mas de su limite (N1 y N2 usan el mismo criterio)
    CURSOR c_clientes_limite (p_pct IN NUMBER) IS
        SELECT TRIM(c.CLI_NOMBRE || ' ' || p.CLP_APELLIDO1) AS NOMBRE,
               c.CLI_EMAIL,
               x.CXC_LIMITE_CREDITO AS LIMITE,
               x.CXC_SALDO AS SALDO
          FROM SGS_CUENTA_COBRAR x
          JOIN SGS_CLIENTE c ON c.CLI_ID = x.CXC_ID_CLIENTE
          LEFT JOIN SGS_CLIENTE_PERSONA p ON p.CLP_ID_CLIENTE = c.CLI_ID
         WHERE c.CLI_ESTADO = 'A'
           AND x.CXC_LIMITE_CREDITO > 0
           AND x.CXC_SALDO >= x.CXC_LIMITE_CREDITO * p_pct
         ORDER BY x.CXC_SALDO / x.CXC_LIMITE_CREDITO DESC;

    -- Montos y porcentajes como se muestran en los correos: ₡129.000,00 y 86 %
    FUNCTION monto (p_valor IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '₡' || TO_CHAR(p_valor, 'FM999G999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''');
    END;

    FUNCTION porcentaje (p_fraccion IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND(p_fraccion * 100, 1), 'FM990D0', 'NLS_NUMERIC_CHARACTERS='',.''') || ' %';
    END;

    -- Fecha de hoy en Costa Rica para los reportes
    FUNCTION hoy RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica', 'DD/MM/YYYY');
    END;

    -- Un correo por cliente con correo registrado; si falla el de uno, se registra y se sigue con los demas
    PROCEDURE avisar_clientes_limite IS
        v_pct       NUMBER := SGS_PKG_PARAMETROS.obtener_numero('PCT_AVISO_CLIENTE');
        v_fallidos  PLS_INTEGER := 0;
    BEGIN
        FOR r IN c_clientes_limite(v_pct) LOOP
            CONTINUE WHEN r.CLI_EMAIL IS NULL;
            BEGIN
                SGS_PKG_CORREO.enviar(
                    r.CLI_EMAIL,
                    'Su crédito alcanzó el ' || porcentaje(r.SALDO / r.LIMITE) || ' del límite',
                    'Estimado(a) ' || r.NOMBRE || ':' || CHR(10) || CHR(10)
                    || 'Le informamos que su cuenta de crédito alcanzó el ' || porcentaje(r.SALDO / r.LIMITE)
                    || ' del límite autorizado.' || CHR(10) || CHR(10)
                    || 'Límite de crédito: ' || monto(r.LIMITE) || CHR(10)
                    || 'Saldo pendiente:   ' || monto(r.SALDO) || CHR(10)
                    || 'Disponible:        ' || monto(r.LIMITE - r.SALDO) || CHR(10) || CHR(10)
                    || 'Le recomendamos realizar un abono para seguir comprando a crédito sin inconvenientes.'
                    || CHR(10) || CHR(10) || 'Mensaje automático del Sistema de Gestión de Supermercados.');
            EXCEPTION
                WHEN OTHERS THEN
                    SGS_PKG_ERRORES.registrar('SGS_PKG_PROCESOS.avisar_clientes_limite');
                    v_fallidos := v_fallidos + 1;
            END;
        END LOOP;

        IF v_fallidos > 0 THEN
            RAISE_APPLICATION_ERROR(-20120, v_fallidos || ' correo(s) no se pudieron enviar; ver SGS_BITACORA_ERROR');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_PROCESOS.avisar_clientes_limite');
            RAISE;
    END;

    PROCEDURE avisar_coordinador_limite IS
        v_pct     NUMBER := SGS_PKG_PARAMETROS.obtener_numero('PCT_AVISO_COORDINADOR');
        v_lista   VARCHAR2(32000);
        v_total   NUMBER := 0;
        v_cuenta  PLS_INTEGER := 0;
    BEGIN
        FOR r IN c_clientes_limite(v_pct) LOOP
            v_cuenta := v_cuenta + 1;
            v_total  := v_total + r.SALDO;
            v_lista  := v_lista || v_cuenta || '. ' || r.NOMBRE || CHR(10)
                        || '   Usado: ' || porcentaje(r.SALDO / r.LIMITE)
                        || ' | Saldo: ' || monto(r.SALDO) || ' de ' || monto(r.LIMITE)
                        || ' | Correo: ' || NVL(r.CLI_EMAIL, 'sin correo') || CHR(10);
        END LOOP;

        IF v_cuenta > 0 THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'COORDINADOR',
                'Clientes con ' || porcentaje(v_pct) || ' o más de su crédito (' || hoy || ')',
                'Clientes que deben el ' || porcentaje(v_pct) || ' o más de su límite de crédito al ' || hoy || ':'
                || CHR(10) || CHR(10) || v_lista || CHR(10)
                || 'Total de clientes: ' || v_cuenta || CHR(10)
                || 'Saldo total de estos clientes: ' || monto(v_total) || CHR(10) || CHR(10)
                || 'Mensaje automático del Sistema de Gestión de Supermercados.');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_PROCESOS.avisar_coordinador_limite');
            RAISE;
    END;

    -- Primero los proveedores que llegaron al umbral y despues el estado de todos los proveedores con credito
    PROCEDURE avisar_gerente_proveedores IS
        v_pct      NUMBER := SGS_PKG_PARAMETROS.obtener_numero('PCT_AVISO_GERENTE_CXP');
        v_alerta   VARCHAR2(32000);
        v_todos    VARCHAR2(32000);
        v_cuenta   PLS_INTEGER := 0;
        v_total    NUMBER := 0;
    BEGIN
        FOR r IN (SELECT v.PRV_NOMBRE AS NOMBRE,
                         x.CXP_LIMITE_CREDITO AS LIMITE,
                         x.CXP_SALDO AS SALDO
                    FROM SGS_CUENTA_PAGAR x
                    JOIN SGS_PROVEEDOR v ON v.PRV_ID = x.CXP_ID_PROVEEDOR
                   WHERE v.PRV_ESTADO = 'A'
                     AND x.CXP_LIMITE_CREDITO > 0
                   ORDER BY x.CXP_SALDO / x.CXP_LIMITE_CREDITO DESC) LOOP
            v_total := v_total + r.SALDO;
            v_todos := v_todos || '- ' || r.NOMBRE || ': ' || porcentaje(r.SALDO / r.LIMITE)
                       || ' (' || monto(r.SALDO) || ' de ' || monto(r.LIMITE) || ')' || CHR(10);
            IF r.SALDO >= r.LIMITE * v_pct THEN
                v_cuenta := v_cuenta + 1;
                v_alerta := v_alerta || v_cuenta || '. ' || r.NOMBRE || CHR(10)
                            || '   Usado: ' || porcentaje(r.SALDO / r.LIMITE)
                            || ' | Saldo: ' || monto(r.SALDO) || ' de ' || monto(r.LIMITE)
                            || ' | Disponible: ' || monto(r.LIMITE - r.SALDO) || CHR(10);
            END IF;
        END LOOP;

        IF v_cuenta > 0 THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'GERENTE',
                'Proveedores con ' || porcentaje(v_pct) || ' o más del crédito usado (' || hoy || ')',
                'Proveedores a los que se les debe el ' || porcentaje(v_pct) || ' o más de su límite de crédito al ' || hoy || ':'
                || CHR(10) || CHR(10) || v_alerta || CHR(10)
                || 'Estado de todos los proveedores con crédito:' || CHR(10) || v_todos || CHR(10)
                || 'Total adeudado a proveedores: ' || monto(v_total) || CHR(10) || CHR(10)
                || 'Mensaje automático del Sistema de Gestión de Supermercados.');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_PROCESOS.avisar_gerente_proveedores');
            RAISE;
    END;

END;
/

-- 3. Jobs
-- La fecha de inicio va en hora de Costa Rica: el scheduler calcula BYHOUR en esa zona aunque el servidor este en otra.
-- Cada job se borra si ya existe (ORA-27475 = no existe) para poder volver a ejecutar el bloque.
DECLARE
    PROCEDURE programar (p_job IN VARCHAR2, p_accion IN VARCHAR2, p_intervalo IN VARCHAR2, p_comentario IN VARCHAR2) IS
    BEGIN
        BEGIN
            DBMS_SCHEDULER.DROP_JOB(p_job, force => TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE <> -27475 THEN
                    RAISE;
                END IF;
        END;
        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => p_job,
            job_type        => 'STORED_PROCEDURE',
            job_action      => p_accion,
            start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
            repeat_interval => p_intervalo,
            enabled         => TRUE,
            comments        => p_comentario);
    END;
BEGIN
    programar('SGS_JOB_AVISO_CLIENTES', 'SGS_PKG_PROCESOS.avisar_clientes_limite',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Aviso diario a los clientes con 85 % o mas de su limite de credito');
    programar('SGS_JOB_AVISO_COORDINADOR', 'SGS_PKG_PROCESOS.avisar_coordinador_limite',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Lista diaria al coordinador de los clientes con 85 % o mas de su limite de credito');
    programar('SGS_JOB_AVISO_GERENTE_CXP', 'SGS_PKG_PROCESOS.avisar_gerente_proveedores',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Aviso diario al gerente de los proveedores con 70 % o mas de su limite de credito');
END;
/
