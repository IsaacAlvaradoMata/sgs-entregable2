CREATE OR REPLACE PACKAGE SGS_PKG_PROCESOS AS
    PROCEDURE avisar_clientes_limite;
    PROCEDURE avisar_coordinador_limite;
    PROCEDURE avisar_gerente_proveedores;
END;

CREATE OR REPLACE PACKAGE BODY SGS_PKG_PROCESOS AS
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
    FUNCTION monto (p_valor IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '₡' || TO_CHAR(p_valor, 'FM999G999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''');
    END;
    FUNCTION porcentaje (p_fraccion IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND(p_fraccion * 100, 1), 'FM990D0', 'NLS_NUMERIC_CHARACTERS='',.''') || ' %';
    END;
    FUNCTION hoy RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica', 'DD/MM/YYYY');
    END;
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

