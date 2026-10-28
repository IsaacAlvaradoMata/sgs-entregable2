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
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_PROCESOS AS

    -- Montos y porcentajes como se muestran en los correos: ₡129.000,00 y 86 %
    FUNCTION monto (p_valor IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '₡' || TO_CHAR(p_valor, 'FM999G999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''');
    END;

    FUNCTION porcentaje (p_fraccion IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND(p_fraccion * 100, 1), 'FM990D0', 'NLS_NUMERIC_CHARACTERS='',.''') || ' %';
    END;

    -- Un correo por cliente; si falla el de uno, se registra y se sigue con los demas
    PROCEDURE avisar_clientes_limite IS
        v_pct       NUMBER := SGS_PKG_PARAMETROS.obtener_numero('PCT_AVISO_CLIENTE');
        v_fallidos  PLS_INTEGER := 0;
    BEGIN
        FOR r IN (SELECT TRIM(c.CLI_NOMBRE || ' ' || p.CLP_APELLIDO1) AS NOMBRE,
                         c.CLI_EMAIL,
                         x.CXC_LIMITE_CREDITO AS LIMITE,
                         x.CXC_SALDO AS SALDO
                    FROM SGS_CUENTA_COBRAR x
                    JOIN SGS_CLIENTE c ON c.CLI_ID = x.CXC_ID_CLIENTE
                    LEFT JOIN SGS_CLIENTE_PERSONA p ON p.CLP_ID_CLIENTE = c.CLI_ID
                   WHERE c.CLI_ESTADO = 'A'
                     AND c.CLI_EMAIL IS NOT NULL
                     AND x.CXC_LIMITE_CREDITO > 0
                     AND x.CXC_SALDO >= x.CXC_LIMITE_CREDITO * v_pct
                   ORDER BY x.CXC_SALDO / x.CXC_LIMITE_CREDITO DESC) LOOP
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

END;
/

-- 3. Jobs
-- La fecha de inicio va en hora de Costa Rica: el scheduler calcula BYHOUR en esa zona aunque el servidor este en otra.
-- Cada bloque borra el job si ya existe (ORA-27475 = no existe) para poder volver a ejecutar el script.
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('SGS_JOB_AVISO_CLIENTES', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -27475 THEN
                RAISE;
            END IF;
    END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'SGS_JOB_AVISO_CLIENTES',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'SGS_PKG_PROCESOS.avisar_clientes_limite',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
        repeat_interval => 'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Aviso diario a los clientes con 85 % o mas de su limite de credito');
END;
/
