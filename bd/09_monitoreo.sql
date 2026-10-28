-- 09_monitoreo.sql: monitoreo de la base (tablespaces, objetos invalidos, indices, sesiones, crecimiento y errores),
-- vistas materializadas de ventas mensuales e inventario consolidado, y analisis de planes de ejecucion.
-- Seccion 0 como SYS (SYSDBA); el resto como SGS_ADMIN. Ambas en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB).
-- Requiere haber ejecutado 08_seguridad.sql (los permisos de las vistas materializadas se dan a los roles).
-- Las revisiones cubren lo del proyecto: el esquema SGS_ADMIN y los tablespaces SGS_DATA, SGS_IDX y SGS_AUD.

-- 0. EJECUTAR COMO SYS (SYSDBA), en la PDB: vistas del diccionario que lee el monitoreo (derechos del dueno: grants directos)
BEGIN
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Cambiar a la PDB antes de seguir: ALTER SESSION SET CONTAINER = <PDB>');
    END IF;
END;
/

GRANT SELECT ON SYS.DBA_TABLESPACE_USAGE_METRICS TO SGS_ADMIN;
GRANT SELECT ON SYS.DBA_TABLESPACES TO SGS_ADMIN;
GRANT SELECT ON SYS.DBA_SEGMENTS TO SGS_ADMIN;
GRANT SELECT ON SYS.V_$SESSION TO SGS_ADMIN;

-- 1. A partir de aqui, conectado como SGS_ADMIN: validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- Minutos que una sesion puede estar bloqueada por otra antes de avisar al DBA
INSERT INTO SGS_PARAMETRO (PAR_ID, PAR_CODIGO, PAR_VALOR, PAR_DESCRIPCION, PAR_ES_CIFRADO)
SELECT SEQ_PARAMETRO.NEXTVAL, 'MINUTOS_SESION_BLOQUEADA', '5', 'Minutos de espera de una sesion bloqueada antes de avisar al DBA', 'N'
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM SGS_PARAMETRO WHERE PAR_CODIGO = 'MINUTOS_SESION_BLOQUEADA');
COMMIT;

-- 2. Monitoreo
-- Cada revision avisa al DBA solo si encuentra un problema; el registro diario guarda las mediciones para ver el crecimiento.
CREATE OR REPLACE PACKAGE SGS_PKG_MONITOREO AS
    -- Diario: tablespaces del proyecto que superan PCT_MAX_TABLESPACE de su tamano maximo
    PROCEDURE verificar_tablespaces;
    -- Diario: objetos invalidos del esquema
    PROCEDURE verificar_objetos;
    -- Diario: indices inutilizables del esquema
    PROCEDURE verificar_indices;
    -- Cada 15 minutos: sesiones bloqueadas por otra por mas de MINUTOS_SESION_BLOQUEADA
    PROCEDURE verificar_bloqueos;
    -- Diario: guarda tamano de la base, sesiones, invalidos, indices, errores y uso de cada tablespace; reporte al DBA
    PROCEDURE registrar_estado;
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_MONITOREO AS

    -- Uso de los tablespaces del proyecto en MB; el maximo considera el crecimiento automatico hasta MAXSIZE
    CURSOR c_tablespaces IS
        SELECT m.TABLESPACE_NAME AS NOMBRE,
               ROUND(m.USED_SPACE * t.BLOCK_SIZE / 1048576, 2) AS USADO_MB,
               ROUND(m.TABLESPACE_SIZE * t.BLOCK_SIZE / 1048576, 2) AS MAXIMO_MB,
               m.USED_PERCENT / 100 AS USO
          FROM SYS.DBA_TABLESPACE_USAGE_METRICS m
          JOIN SYS.DBA_TABLESPACES t ON t.TABLESPACE_NAME = m.TABLESPACE_NAME
         WHERE m.TABLESPACE_NAME IN ('SGS_DATA', 'SGS_IDX', 'SGS_AUD')
         ORDER BY m.TABLESPACE_NAME;

    FUNCTION mb (p_valor IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p_valor, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''') || ' MB';
    END;

    FUNCTION porcentaje (p_fraccion IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND(p_fraccion * 100, 2), 'FM990D00', 'NLS_NUMERIC_CHARACTERS='',.''') || ' %';
    END;

    FUNCTION ahora RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica', 'DD/MM/YYYY HH24:MI');
    END;

    FUNCTION pie RETURN VARCHAR2 IS
    BEGIN
        RETURN CHR(10) || 'Mensaje automático del monitoreo del Sistema de Gestión de Supermercados.';
    END;

    PROCEDURE verificar_tablespaces IS
        v_pct    NUMBER := SGS_PKG_PARAMETROS.obtener_numero('PCT_MAX_TABLESPACE');
        v_lista  VARCHAR2(32000);
    BEGIN
        FOR r IN c_tablespaces LOOP
            IF r.USO > v_pct THEN
                v_lista := v_lista || '- ' || r.NOMBRE || ': ' || porcentaje(r.USO) || ' usado (' || mb(r.USADO_MB)
                           || ' de ' || mb(r.MAXIMO_MB) || ')' || CHR(10);
            END IF;
        END LOOP;

        IF v_lista IS NOT NULL THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'DBA',
                'Tablespaces sobre el ' || porcentaje(v_pct) || ' (' || ahora || ')',
                'Tablespaces que superan el ' || porcentaje(v_pct) || ' de su tamaño máximo:' || CHR(10) || CHR(10)
                || v_lista || CHR(10)
                || 'Acción sugerida: ampliar el MAXSIZE o agregar un datafile al tablespace.' || CHR(10) || pie);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_MONITOREO.verificar_tablespaces');
            RAISE;
    END;

    PROCEDURE verificar_objetos IS
        v_lista   VARCHAR2(32000);
        v_cuenta  PLS_INTEGER := 0;
    BEGIN
        -- Una vista materializada queda INVALID solo por estar desactualizada (la refresca su job): se revisa si no compila
        FOR r IN (SELECT OBJECT_TYPE, OBJECT_NAME, LAST_DDL_TIME
                    FROM USER_OBJECTS
                   WHERE STATUS = 'INVALID'
                     AND OBJECT_TYPE <> 'MATERIALIZED VIEW'
                  UNION ALL
                  SELECT 'MATERIALIZED VIEW', m.MVIEW_NAME, o.LAST_DDL_TIME
                    FROM USER_MVIEWS m
                    JOIN USER_OBJECTS o ON o.OBJECT_NAME = m.MVIEW_NAME AND o.OBJECT_TYPE = 'MATERIALIZED VIEW'
                   WHERE m.COMPILE_STATE = 'COMPILATION_ERROR'
                   ORDER BY 1, 2) LOOP
            v_cuenta := v_cuenta + 1;
            v_lista  := v_lista || v_cuenta || '. ' || r.OBJECT_TYPE || ' ' || r.OBJECT_NAME
                        || ' (último cambio: ' || TO_CHAR(r.LAST_DDL_TIME, 'DD/MM/YYYY HH24:MI') || ')' || CHR(10);
        END LOOP;

        IF v_cuenta > 0 THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'DBA',
                v_cuenta || ' objeto(s) inválido(s) en SGS_ADMIN (' || ahora || ')',
                'Objetos inválidos del esquema SGS_ADMIN:' || CHR(10) || CHR(10) || v_lista || CHR(10)
                || 'Acción sugerida: revisar USER_ERRORS y recompilar (ALTER ... COMPILE o DBMS_UTILITY.COMPILE_SCHEMA).'
                || CHR(10) || pie);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_MONITOREO.verificar_objetos');
            RAISE;
    END;

    PROCEDURE verificar_indices IS
        v_lista   VARCHAR2(32000);
        v_cuenta  PLS_INTEGER := 0;
    BEGIN
        FOR r IN (SELECT i.INDEX_NAME, i.TABLE_NAME, NULL AS PARTICION
                    FROM USER_INDEXES i
                   WHERE i.STATUS = 'UNUSABLE'
                  UNION ALL
                  SELECT p.INDEX_NAME, i.TABLE_NAME, p.PARTITION_NAME
                    FROM USER_IND_PARTITIONS p
                    JOIN USER_INDEXES i ON i.INDEX_NAME = p.INDEX_NAME
                   WHERE p.STATUS = 'UNUSABLE'
                   ORDER BY 1) LOOP
            v_cuenta := v_cuenta + 1;
            v_lista  := v_lista || v_cuenta || '. ' || r.INDEX_NAME || ' sobre ' || r.TABLE_NAME
                        || CASE WHEN r.PARTICION IS NOT NULL THEN ' (partición ' || r.PARTICION || ')' END || CHR(10)
                        || '   ALTER INDEX ' || r.INDEX_NAME
                        || CASE WHEN r.PARTICION IS NOT NULL THEN ' REBUILD PARTITION ' || r.PARTICION ELSE ' REBUILD' END
                        || ';' || CHR(10);
        END LOOP;

        IF v_cuenta > 0 THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'DBA',
                v_cuenta || ' índice(s) dañado(s) en SGS_ADMIN (' || ahora || ')',
                'Índices inutilizables (UNUSABLE) del esquema SGS_ADMIN y la sentencia para reconstruirlos:'
                || CHR(10) || CHR(10) || v_lista || pie);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_MONITOREO.verificar_indices');
            RAISE;
    END;

    PROCEDURE verificar_bloqueos IS
        v_minutos  NUMBER := SGS_PKG_PARAMETROS.obtener_numero('MINUTOS_SESION_BLOQUEADA');
        v_lista    VARCHAR2(32000);
        v_cuenta   PLS_INTEGER := 0;
    BEGIN
        FOR r IN (SELECT b.SID, b.USERNAME, b.MACHINE, b.EVENT, b.SECONDS_IN_WAIT,
                         b.BLOCKING_SESSION, x.USERNAME AS USUARIO_BLOQUEA, x.MACHINE AS EQUIPO_BLOQUEA
                    FROM SYS.V_$SESSION b
                    LEFT JOIN SYS.V_$SESSION x ON x.SID = b.BLOCKING_SESSION
                   WHERE b.BLOCKING_SESSION IS NOT NULL
                     AND b.SECONDS_IN_WAIT >= v_minutos * 60
                   ORDER BY b.SECONDS_IN_WAIT DESC) LOOP
            v_cuenta := v_cuenta + 1;
            v_lista  := v_lista || v_cuenta || '. Sesión ' || r.SID || ' (' || r.USERNAME || ' desde ' || r.MACHINE || ')'
                        || ' lleva ' || TO_CHAR(r.SECONDS_IN_WAIT / 60, 'FM9990D0', 'NLS_NUMERIC_CHARACTERS='',.''') || ' min esperando (' || r.EVENT || ')' || CHR(10)
                        || '   Bloqueada por la sesión ' || r.BLOCKING_SESSION || ' (' || r.USUARIO_BLOQUEA
                        || ' desde ' || r.EQUIPO_BLOQUEA || ')' || CHR(10);
        END LOOP;

        IF v_cuenta > 0 THEN
            SGS_PKG_CORREO.enviar_a_tipo(
                'DBA',
                v_cuenta || ' sesión(es) bloqueada(s) (' || ahora || ')',
                'Sesiones que llevan ' || v_minutos || ' minutos o más esperando a que otra libere un registro:'
                || CHR(10) || CHR(10) || v_lista || CHR(10)
                || 'Acción sugerida: contactar al usuario de la sesión que bloquea para que confirme o deshaga su transacción.'
                || CHR(10) || pie);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_MONITOREO.verificar_bloqueos');
            RAISE;
    END;

    -- El crecimiento se calcula contra la medicion anterior; los errores son los de las ultimas 24 horas
    PROCEDURE registrar_estado IS
        v_id          SGS_MONITOREO.MON_ID%TYPE;
        v_tamano      NUMBER;
        v_anterior    NUMBER;
        v_totales     NUMBER;
        v_activas     NUMBER;
        v_invalidos   NUMBER;
        v_indices     NUMBER;
        v_errores     NUMBER;
        v_detalle     VARCHAR2(32000);
        v_programas   VARCHAR2(32000);
    BEGIN
        SAVEPOINT sp_registrar_estado;

        SELECT ROUND(SUM(BYTES) / 1048576, 2) INTO v_tamano FROM SYS.DBA_SEGMENTS;
        SELECT COUNT(*), COUNT(CASE WHEN STATUS = 'ACTIVE' THEN 1 END)
          INTO v_totales, v_activas
          FROM SYS.V_$SESSION
         WHERE TYPE = 'USER';
        SELECT (SELECT COUNT(*) FROM USER_OBJECTS WHERE STATUS = 'INVALID' AND OBJECT_TYPE <> 'MATERIALIZED VIEW')
               + (SELECT COUNT(*) FROM USER_MVIEWS WHERE COMPILE_STATE = 'COMPILATION_ERROR')
          INTO v_invalidos
          FROM DUAL;
        SELECT (SELECT COUNT(*) FROM USER_INDEXES WHERE STATUS = 'UNUSABLE')
               + (SELECT COUNT(*) FROM USER_IND_PARTITIONS WHERE STATUS = 'UNUSABLE')
          INTO v_indices
          FROM DUAL;
        SELECT COUNT(*) INTO v_errores FROM SGS_BITACORA_ERROR WHERE BER_FECHA >= SYSTIMESTAMP - INTERVAL '1' DAY;

        SELECT MAX(MON_TAMANO_BD_MB) KEEP (DENSE_RANK LAST ORDER BY MON_FECHA)
          INTO v_anterior
          FROM SGS_MONITOREO;

        INSERT INTO SGS_MONITOREO (MON_ID, MON_TAMANO_BD_MB, MON_SESIONES_TOTALES, MON_SESIONES_ACTIVAS,
                                   MON_OBJETOS_INVALIDOS, MON_INDICES_DANADOS, MON_ERRORES)
        VALUES (SEQ_MONITOREO.NEXTVAL, v_tamano, v_totales, v_activas, v_invalidos, v_indices, v_errores)
        RETURNING MON_ID INTO v_id;

        FOR r IN c_tablespaces LOOP
            INSERT INTO SGS_MONITOREO_TABLESPACE (MOT_ID, MOT_ID_MONITOREO, MOT_TABLESPACE, MOT_USADO_MB, MOT_MAXIMO_MB)
            VALUES (SEQ_MONITOREO_TABLESPACE.NEXTVAL, v_id, r.NOMBRE, r.USADO_MB, r.MAXIMO_MB);
            v_detalle := v_detalle || '- ' || r.NOMBRE || ': ' || mb(r.USADO_MB) || ' de ' || mb(r.MAXIMO_MB)
                         || ' (' || porcentaje(r.USO) || ')' || CHR(10);
        END LOOP;

        COMMIT;

        FOR r IN (SELECT BER_PROGRAMA, COUNT(*) AS VECES
                    FROM SGS_BITACORA_ERROR
                   WHERE BER_FECHA >= SYSTIMESTAMP - INTERVAL '1' DAY
                   GROUP BY BER_PROGRAMA
                   ORDER BY VECES DESC, BER_PROGRAMA
                   FETCH FIRST 5 ROWS ONLY) LOOP
            v_programas := v_programas || '- ' || r.BER_PROGRAMA || ': ' || r.VECES || CHR(10);
        END LOOP;

        SGS_PKG_CORREO.enviar_a_tipo(
            'DBA',
            'Reporte diario de monitoreo (' || ahora || ')',
            'Tamaño de la base: ' || mb(v_tamano)
            || CASE WHEN v_anterior IS NOT NULL
                    THEN ' (crecimiento desde la revisión anterior: ' || mb(v_tamano - v_anterior) || ')' END || CHR(10)
            || 'Sesiones de usuario: ' || v_totales || ' abiertas, ' || v_activas || ' activas' || CHR(10)
            || 'Objetos inválidos: ' || v_invalidos || CHR(10)
            || 'Índices dañados: ' || v_indices || CHR(10)
            || 'Errores en las últimas 24 horas: ' || v_errores || CHR(10) || CHR(10)
            || 'Uso de los tablespaces:' || CHR(10) || v_detalle || CHR(10)
            || CASE WHEN v_programas IS NOT NULL
                    THEN 'Programas con más errores en las últimas 24 horas:' || CHR(10) || v_programas END
            || pie);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_registrar_estado;
            SGS_PKG_ERRORES.registrar('SGS_PKG_MONITOREO.registrar_estado');
            RAISE;
    END;

END;
/

-- Crecimiento de la base entre revisiones (para consultas y reportes)
CREATE OR REPLACE VIEW SGS_VW_CRECIMIENTO AS
SELECT MON_ID, MON_FECHA, MON_TAMANO_BD_MB,
       MON_TAMANO_BD_MB - LAG(MON_TAMANO_BD_MB) OVER (ORDER BY MON_FECHA) AS CRECIMIENTO_MB,
       MON_SESIONES_TOTALES, MON_SESIONES_ACTIVAS, MON_OBJETOS_INVALIDOS, MON_INDICES_DANADOS, MON_ERRORES
  FROM SGS_MONITOREO;

-- 3. Vistas materializadas: refresco completo bajo demanda, lo hace un job cada dia despues del cierre diario
-- Ventas por mes y sucursal; las devoluciones se cuentan en el mes de la factura que devuelven
CREATE MATERIALIZED VIEW SGS_MV_VENTAS_MENSUALES
    TABLESPACE SGS_DATA
    BUILD IMMEDIATE
    REFRESH COMPLETE ON DEMAND
AS
SELECT TRUNC(f.FV_FECHA, 'MM') AS MES,
       s.SUC_NOMBRE AS SUCURSAL,
       COUNT(*) AS FACTURAS,
       SUM(f.FV_TOTAL) AS VENDIDO,
       NVL(SUM(n.DEVUELTO), 0) AS DEVUELTO,
       SUM(f.FV_TOTAL) - NVL(SUM(n.DEVUELTO), 0) AS NETO
  FROM SGS_FACTURA_VENTA f
  JOIN SGS_SUCURSAL s ON s.SUC_ID = f.FV_ID_SUCURSAL
  LEFT JOIN (SELECT NCV_ID_FACTURA, SUM(NCV_MONTO) AS DEVUELTO
               FROM SGS_NOTA_CREDITO_VENTA
              GROUP BY NCV_ID_FACTURA) n ON n.NCV_ID_FACTURA = f.FV_ID
 WHERE f.FV_ESTADO <> 'N'
 GROUP BY TRUNC(f.FV_FECHA, 'MM'), s.SUC_NOMBRE;

-- Existencia por producto y sucursal, con su valor al costo de compra de cada lote
CREATE MATERIALIZED VIEW SGS_MV_INVENTARIO_CONSOLIDADO
    TABLESPACE SGS_DATA
    BUILD IMMEDIATE
    REFRESH COMPLETE ON DEMAND
AS
SELECT s.SUC_NOMBRE AS SUCURSAL,
       pr.PRO_CODIGO AS CODIGO,
       a.ART_NOMBRE AS PRODUCTO,
       fa.FAM_NOMBRE AS FAMILIA,
       SUM(e.EXI_CANTIDAD) AS EXISTENCIA,
       SUM(e.EXI_CANTIDAD * d.DFP_PRECIO_UNITARIO) AS VALOR_COSTO,
       COUNT(*) AS LOTES,
       MIN(l.LOT_FECHA_VENCIMIENTO) AS PRIMER_VENCIMIENTO
  FROM SGS_EXISTENCIA e
  JOIN SGS_LOTE l ON l.LOT_ID = e.EXI_ID_LOTE
  JOIN SGS_DETALLE_FACTURA_PROVEEDOR d ON d.DFP_ID = l.LOT_ID_DETALLE_COMPRA
  JOIN SGS_PRODUCTO pr ON pr.PRO_ID = d.DFP_ID_PRODUCTO
  JOIN SGS_ARTICULO_FACTURABLE a ON a.ART_ID = pr.PRO_ID_ARTICULO
  JOIN SGS_FAMILIA_PRODUCTO fa ON fa.FAM_ID = pr.PRO_ID_FAMILIA
  JOIN SGS_SUCURSAL s ON s.SUC_ID = e.EXI_ID_SUCURSAL
 WHERE e.EXI_CANTIDAD > 0
 GROUP BY s.SUC_NOMBRE, pr.PRO_CODIGO, a.ART_NOMBRE, fa.FAM_NOMBRE;

GRANT SELECT ON SGS_MV_VENTAS_MENSUALES TO SGS_ROL_GERENTE;
GRANT SELECT ON SGS_MV_INVENTARIO_CONSOLIDADO TO SGS_ROL_GERENTE;
GRANT SELECT ON SGS_MV_INVENTARIO_CONSOLIDADO TO SGS_ROL_JEFE_PROVEEDURIA;
GRANT SELECT ON SGS_VW_CRECIMIENTO TO SGS_ROL_GERENTE;

-- 4. Jobs (misma forma que en 07_procesos.sql)
DECLARE
    PROCEDURE programar (p_job IN VARCHAR2, p_tipo IN VARCHAR2, p_accion IN VARCHAR2, p_intervalo IN VARCHAR2,
                         p_comentario IN VARCHAR2) IS
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
            job_type        => p_tipo,
            job_action      => p_accion,
            start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
            repeat_interval => p_intervalo,
            enabled         => TRUE,
            comments        => p_comentario);
    END;
BEGIN
    programar('SGS_JOB_REVISION_TABLESPACES', 'STORED_PROCEDURE', 'SGS_PKG_MONITOREO.verificar_tablespaces',
              'FREQ=DAILY;BYHOUR=6;BYMINUTE=0;BYSECOND=0', 'Revision diaria del uso de los tablespaces del proyecto');
    programar('SGS_JOB_REVISION_OBJETOS', 'STORED_PROCEDURE', 'SGS_PKG_MONITOREO.verificar_objetos',
              'FREQ=DAILY;BYHOUR=6;BYMINUTE=5;BYSECOND=0', 'Revision diaria de objetos invalidos');
    programar('SGS_JOB_REVISION_INDICES', 'STORED_PROCEDURE', 'SGS_PKG_MONITOREO.verificar_indices',
              'FREQ=DAILY;BYHOUR=6;BYMINUTE=10;BYSECOND=0', 'Revision diaria de indices danados');
    programar('SGS_JOB_REVISION_BLOQUEOS', 'STORED_PROCEDURE', 'SGS_PKG_MONITOREO.verificar_bloqueos',
              'FREQ=MINUTELY;INTERVAL=15', 'Revision cada 15 minutos de sesiones bloqueadas');
    programar('SGS_JOB_REGISTRO_MONITOREO', 'STORED_PROCEDURE', 'SGS_PKG_MONITOREO.registrar_estado',
              'FREQ=DAILY;BYHOUR=23;BYMINUTE=55;BYSECOND=0', 'Registro diario del estado de la base y reporte al DBA');
    programar('SGS_JOB_REFRESCO_VISTAS', 'PLSQL_BLOCK',
              'BEGIN DBMS_MVIEW.REFRESH(''SGS_MV_VENTAS_MENSUALES,SGS_MV_INVENTARIO_CONSOLIDADO'', ''CC''); END;',
              'FREQ=DAILY;BYHOUR=0;BYMINUTE=30;BYSECOND=0', 'Refresco diario de las vistas materializadas');
END;
/

-- 5. Estadisticas al dia para que el optimizador estime bien los costos (el padron tiene 3,7 millones de filas)
BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS(ownname => 'SGS_ADMIN', cascade => TRUE);
END;
/

-- 6. Optimizacion: planes de ejecucion de las consultas de los requerimientos funcionales
-- PLAN_TABLE es temporal por sesion: los planes se consultan en la misma sesion (resumen y DBMS_XPLAN al final)
DELETE FROM PLAN_TABLE WHERE STATEMENT_ID LIKE 'SGS\_%' ESCAPE '\';

-- Q1. Precio de venta de un producto en una sucursal (precio calculado con costo, utilidad, descuento e impuesto)
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q1_PRECIO' FOR
SELECT PRECIO_VENTA
  FROM SGS_VW_PRECIO_VENTA
 WHERE PRO_CODIGO = 'ABA-001' AND SUC_NOMBRE = 'Sucursal San Isidro';

-- Q2. Persona del padron por cedula (asi la busca el registro de clientes) y, para comparar, por nombre y apellidos
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q2_PADRON_CEDULA' FOR
SELECT PAD_NOMBRE, PAD_APELLIDO1, PAD_APELLIDO2 FROM SGS_PADRON WHERE PAD_CEDULA = '199990001';

EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q2_PADRON_NOMBRE' FOR
SELECT PAD_CEDULA FROM SGS_PADRON WHERE PAD_NOMBRE = 'MARIA FERNANDA' AND PAD_APELLIDO1 = 'ROJAS';

-- Q3. Lotes con existencia por vencer en la semana o con mas de 6 meses
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q3_LOTES' FOR
SELECT l.LOT_ID, e.EXI_ID_SUCURSAL, e.EXI_CANTIDAD
  FROM SGS_LOTE l
  JOIN SGS_EXISTENCIA e ON e.EXI_ID_LOTE = l.LOT_ID
 WHERE e.EXI_CANTIDAD > 0
   AND (l.LOT_FECHA_VENCIMIENTO BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + 7
        OR l.LOT_FECHA_INGRESO <= ADD_MONTHS(TRUNC(SYSDATE), -6));

-- Q4. Clientes morosos: saldo pendiente y ultimo abono a una factura a credito con mas de 30 dias
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q4_MOROSOS' FOR
SELECT x.CXC_ID_CLIENTE, x.CXC_SALDO
  FROM SGS_CUENTA_COBRAR x
 WHERE x.CXC_SALDO > 0
   AND TRUNC(SYSDATE) - NVL((SELECT MAX(pf.PFV_FECHA)
                               FROM SGS_PAGO_FACTURA_VENTA pf
                               JOIN SGS_FACTURA_VENTA f ON f.FV_ID = pf.PFV_ID_FACTURA
                              WHERE f.FV_ID_CLIENTE = x.CXC_ID_CLIENTE AND f.FV_ES_CREDITO = 'S'),
                            (SELECT MIN(f.FV_FECHA)
                               FROM SGS_FACTURA_VENTA f
                              WHERE f.FV_ID_CLIENTE = x.CXC_ID_CLIENTE AND f.FV_ES_CREDITO = 'S' AND f.FV_ESTADO = 'P')) > 30;

-- Q5. Ventas de un dia por cajero para el cierre diario
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q5_CIERRE' FOR
SELECT FV_ID_USUARIO, COUNT(*), SUM(FV_TOTAL)
  FROM SGS_FACTURA_VENTA
 WHERE FV_FECHA >= TRUNC(SYSDATE) - 1 AND FV_FECHA < TRUNC(SYSDATE)
   AND FV_ESTADO <> 'N'
 GROUP BY FV_ID_USUARIO;

-- Q6. Los 10 clientes con mas compras en los ultimos 6 meses
EXPLAIN PLAN SET STATEMENT_ID = 'SGS_Q6_PREMIACION' FOR
SELECT c.CLI_ID, SUM(f.FV_TOTAL) AS COMPRADO
  FROM SGS_FACTURA_VENTA f
  JOIN SGS_CLIENTE c ON c.CLI_ID = f.FV_ID_CLIENTE
 WHERE c.CLI_ES_DEFECTO = 'N'
   AND f.FV_ESTADO <> 'N'
   AND f.FV_FECHA >= ADD_MONTHS(TRUNC(SYSDATE), -6)
 GROUP BY c.CLI_ID
 ORDER BY COMPRADO DESC
 FETCH FIRST 10 ROWS ONLY;

-- Resumen: costo, indices usados y tablas recorridas completas de cada consulta
SELECT STATEMENT_ID AS CONSULTA,
       MAX(CASE WHEN ID = 0 THEN COST END) AS COSTO,
       MAX(CASE WHEN ID = 0 THEN CARDINALITY END) AS FILAS_ESTIMADAS,
       LISTAGG(DISTINCT CASE WHEN OPERATION = 'INDEX' THEN OBJECT_NAME || ' (' || OPTIONS || ')' END, ', ')
           WITHIN GROUP (ORDER BY CASE WHEN OPERATION = 'INDEX' THEN OBJECT_NAME || ' (' || OPTIONS || ')' END) AS INDICES_USADOS,
       LISTAGG(DISTINCT CASE WHEN OPERATION IN ('TABLE ACCESS', 'MAT_VIEW ACCESS') AND OPTIONS LIKE 'FULL%' THEN OBJECT_NAME END, ', ')
           WITHIN GROUP (ORDER BY CASE WHEN OPERATION IN ('TABLE ACCESS', 'MAT_VIEW ACCESS') AND OPTIONS LIKE 'FULL%' THEN OBJECT_NAME END)
           AS RECORRIDOS_COMPLETOS
  FROM PLAN_TABLE
 WHERE STATEMENT_ID LIKE 'SGS\_Q%' ESCAPE '\'
 GROUP BY STATEMENT_ID
 ORDER BY STATEMENT_ID;

-- Plan completo de la busqueda en el padron por cedula y por nombre
SELECT PLAN_TABLE_OUTPUT FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'SGS_Q2_PADRON_CEDULA', 'TYPICAL'));
SELECT PLAN_TABLE_OUTPUT FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'SGS_Q2_PADRON_NOMBRE', 'TYPICAL'));
