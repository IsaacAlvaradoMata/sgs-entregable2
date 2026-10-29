-- 11_standby.sql: procesos automaticos del servidor (respaldo diario con RMAN y, despues, administracion del standby).
-- Se ejecuta en la PDB del ambiente oficial (SGSPDB en SGSPRI), conectado como SGS_ADMIN o como SYS (SYSDBA) dentro de la PDB:
-- los objetos van con el esquema SGS_ADMIN en el nombre, asi que quedan de SGS_ADMIN en los dos casos.
-- Requiere 03_base_interna.sql (parametros RESP_HORA_DIARIO y STB_*) y los privilegios CREATE EXTERNAL JOB y CREATE CREDENTIAL (01).
-- Los jobs ejecutan scripts de Linux como el usuario oracle; los scripts estan en servidores/scripts/ del repo y se instalan
-- en /home/oracle/scripts de SGSPRI y SGSSTB. Detectan en que servidor corren y solo actuan si esa base es la PRIMARY.
-- No se ejecuta en Docker: no hay RMAN ni standby.

-- 1. Validar el ambiente
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Cambiar a la PDB antes de seguir: ALTER SESSION SET CONTAINER = SGSPDB');
    END IF;
    IF v_usuario NOT IN ('SGS_ADMIN', 'SYS') THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar como SGS_ADMIN o como SYS, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Credencial del usuario oracle del sistema operativo (la clave se pide al ejecutar y no se muestra)
SET VERIFY OFF
ACCEPT clave_oracle CHAR PROMPT 'Clave de Linux del usuario oracle: ' HIDE

BEGIN
    BEGIN
        DBMS_CREDENTIAL.DROP_CREDENTIAL('SGS_ADMIN.SGS_CRED_ORACLE', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-27475, -27476) THEN
                RAISE;
            END IF;
    END;
    DBMS_CREDENTIAL.CREATE_CREDENTIAL(
        credential_name => 'SGS_ADMIN.SGS_CRED_ORACLE',
        username        => 'oracle',
        password        => '&clave_oracle');
END;
/

UNDEFINE clave_oracle

-- 3. Respaldo diario: incremental nivel 0 los domingos y nivel 1 los demas dias, copiado al otro servidor.
-- La hora sale de RESP_HORA_DIARIO; si cambia, se vuelve a ejecutar este bloque.
-- A demanda: EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO', use_current_session => TRUE);
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -27475 THEN
                RAISE;
            END IF;
    END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'SGS_ADMIN.SGS_JOB_RESPALDO_DIARIO',
        job_type        => 'EXECUTABLE',
        job_action      => '/home/oracle/scripts/respaldo_rman.sh',
        credential_name => 'SGS_ADMIN.SGS_CRED_ORACLE',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
        repeat_interval => 'FREQ=DAILY;BYHOUR=' || SGS_ADMIN.SGS_PKG_PARAMETROS.obtener_numero('RESP_HORA_DIARIO')
                           || ';BYMINUTE=0;BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Respaldo diario con RMAN y copia al standby a la hora de RESP_HORA_DIARIO');
END;
/

-- 4. Administracion del standby: cada proceso lee sus parametros al ejecutarse y se los pasa al script de Linux,
-- asi que cambiar un valor en SGS_PARAMETRO cambia el comportamiento sin tocar codigo.
-- Cada ejecucion crea un job externo de un solo uso con la credencial, lo corre en la misma sesion y lo borra;
-- si el script termina con error, el job externo falla (ORA-27369) y el error queda en SGS_BITACORA_ERROR.
CREATE OR REPLACE PACKAGE SGS_ADMIN.SGS_PKG_STANDBY AS
    -- Archivo de actualizacion cada STB_MINUTOS_ARCHIVO minutos (ArchiveLagTarget en las dos bases)
    -- y aviso al DBA si los redo logs no miden STB_MB_ARCHIVO
    PROCEDURE aplicar_archivo;
    -- Cierra el archivo de redo actual para que viaje completo a la standby; si STB_MINUTOS_TRASLADO cambio,
    -- reprograma su job con el valor nuevo
    PROCEDURE trasladar;
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_ADMIN.SGS_PKG_STANDBY AS

    -- Ejecuta un script de /home/oracle/scripts como oracle con hasta dos argumentos
    PROCEDURE ejecutar_script (p_script IN VARCHAR2, p_arg1 IN VARCHAR2 DEFAULT NULL, p_arg2 IN VARCHAR2 DEFAULT NULL) IS
        v_job VARCHAR2(128) := DBMS_SCHEDULER.GENERATE_JOB_NAME('SGS_STB_');
    BEGIN
        DBMS_SCHEDULER.CREATE_JOB(
            job_name            => v_job,
            job_type            => 'EXECUTABLE',
            job_action          => '/home/oracle/scripts/' || p_script,
            number_of_arguments => CASE WHEN p_arg2 IS NOT NULL THEN 2 WHEN p_arg1 IS NOT NULL THEN 1 ELSE 0 END,
            credential_name     => 'SGS_CRED_ORACLE',
            enabled             => FALSE);
        IF p_arg1 IS NOT NULL THEN
            DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(v_job, 1, p_arg1);
        END IF;
        IF p_arg2 IS NOT NULL THEN
            DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(v_job, 2, p_arg2);
        END IF;
        DBMS_SCHEDULER.RUN_JOB(v_job, use_current_session => TRUE);
        DBMS_SCHEDULER.DROP_JOB(v_job);
    EXCEPTION
        WHEN OTHERS THEN
            SGS_PKG_ERRORES.registrar('SGS_PKG_STANDBY.' || p_script);
            BEGIN
                DBMS_SCHEDULER.DROP_JOB(v_job, force => TRUE);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            RAISE;
    END;

    PROCEDURE aplicar_archivo IS
    BEGIN
        ejecutar_script('standby_archivo.sh',
                        TO_CHAR(SGS_PKG_PARAMETROS.obtener_numero('STB_MINUTOS_ARCHIVO')),
                        TO_CHAR(SGS_PKG_PARAMETROS.obtener_numero('STB_MB_ARCHIVO')));
    END;

    PROCEDURE trasladar IS
        v_intervalo VARCHAR2(100) := 'FREQ=MINUTELY;INTERVAL=' || SGS_PKG_PARAMETROS.obtener_numero('STB_MINUTOS_TRASLADO');
        v_actual    USER_SCHEDULER_JOBS.REPEAT_INTERVAL%TYPE;
    BEGIN
        ejecutar_script('standby_traslado.sh');
        SELECT repeat_interval INTO v_actual
          FROM user_scheduler_jobs
         WHERE job_name = 'SGS_JOB_STB_TRASLADO';
        IF v_actual <> v_intervalo THEN
            DBMS_SCHEDULER.SET_ATTRIBUTE('SGS_JOB_STB_TRASLADO', 'repeat_interval', v_intervalo);
        END IF;
    END;

END;
/

-- Archivo de actualizacion: se revisa todos los dias a las 00:10 y a demanda
-- A demanda: EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_STB_ARCHIVO', use_current_session => TRUE);
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('SGS_ADMIN.SGS_JOB_STB_ARCHIVO', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -27475 THEN
                RAISE;
            END IF;
    END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'SGS_ADMIN.SGS_JOB_STB_ARCHIVO',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'SGS_ADMIN.SGS_PKG_STANDBY.aplicar_archivo',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
        repeat_interval => 'FREQ=DAILY;BYHOUR=0;BYMINUTE=10;BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Archivo de actualizacion cada STB_MINUTOS_ARCHIVO minutos o STB_MB_ARCHIVO MB');
END;
/

-- Traslado al standby cada STB_MINUTOS_TRASLADO minutos
-- A demanda: EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.SGS_JOB_STB_TRASLADO', use_current_session => TRUE);
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('SGS_ADMIN.SGS_JOB_STB_TRASLADO', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -27475 THEN
                RAISE;
            END IF;
    END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'SGS_ADMIN.SGS_JOB_STB_TRASLADO',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'SGS_ADMIN.SGS_PKG_STANDBY.trasladar',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'America/Costa_Rica',
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=' || SGS_ADMIN.SGS_PKG_PARAMETROS.obtener_numero('STB_MINUTOS_TRASLADO'),
        enabled         => TRUE,
        comments        => 'Traslado de la informacion al standby cada STB_MINUTOS_TRASLADO minutos');
END;
/

-- 5. Verificacion (vistas ALL_: SYS ve todo y SGS_ADMIN lo suyo): credencial, jobs y ultimas ejecuciones
SELECT owner, credential_name, username, enabled
  FROM all_credentials
 WHERE owner = 'SGS_ADMIN';

SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI TZR') AS proxima
  FROM all_scheduler_jobs
 WHERE owner = 'SGS_ADMIN'
   AND job_name IN ('SGS_JOB_RESPALDO_DIARIO', 'SGS_JOB_STB_ARCHIVO', 'SGS_JOB_STB_TRASLADO');

SELECT status, error#, TO_CHAR(actual_start_date, 'YYYY-MM-DD HH24:MI:SS') AS inicio, run_duration
  FROM all_scheduler_job_run_details
 WHERE owner = 'SGS_ADMIN'
   AND job_name = 'SGS_JOB_RESPALDO_DIARIO'
 ORDER BY log_id DESC
 FETCH FIRST 1 ROWS ONLY;
