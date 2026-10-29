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

-- 4. Verificacion: credencial y job de SGS_ADMIN, y la ultima ejecucion del respaldo
SELECT owner, credential_name, username, enabled
  FROM dba_credentials
 WHERE owner = 'SGS_ADMIN';

SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI TZR') AS proxima
  FROM dba_scheduler_jobs
 WHERE owner = 'SGS_ADMIN'
   AND job_name = 'SGS_JOB_RESPALDO_DIARIO';

SELECT status, error#, TO_CHAR(actual_start_date, 'YYYY-MM-DD HH24:MI:SS') AS inicio, run_duration
  FROM dba_scheduler_job_run_details
 WHERE owner = 'SGS_ADMIN'
   AND job_name = 'SGS_JOB_RESPALDO_DIARIO'
 ORDER BY log_id DESC
 FETCH FIRST 1 ROWS ONLY;
