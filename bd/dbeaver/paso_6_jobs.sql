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
    programar('SGS_JOB_AVISO_MOROSOS', 'SGS_PKG_PROCESOS.avisar_morosos',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Aviso diario al gerente y al coordinador de los clientes morosos');
    programar('SGS_JOB_AVISO_VENCIDOS', 'SGS_PKG_PROCESOS.avisar_vencidos',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Lista diaria al coordinador de los productos vencidos con existencia');
END;

