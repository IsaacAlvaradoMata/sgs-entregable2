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
    programar('SGS_JOB_REPORTE_INVENTARIO', 'SGS_PKG_PROCESOS.reportar_inventario',
              'FREQ=WEEKLY;BYDAY=MON;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
              'Reporte semanal al coordinador de productos por vencer y con mas de 6 meses en inventario');
    programar('SGS_JOB_DESCUENTOS', 'SGS_PKG_PROCESOS.incluir_descuentos',
              'FREQ=WEEKLY;BYDAY=MON;BYHOUR=6;BYMINUTE=0;BYSECOND=0',
              'Inclusion semanal de productos en los descuentos por antiguedad o por vencimiento');
    programar('SGS_JOB_PREMIACION', 'SGS_PKG_PROCESOS.premiar_clientes',
              'FREQ=MONTHLY;INTERVAL=' || SGS_PKG_PARAMETROS.obtener_numero('PREMIO_FRECUENCIA_MESES')
              || ';BYMONTHDAY=1;BYHOUR=8;BYMINUTE=0;BYSECOND=0',
              'Premiacion de los mejores clientes cada PREMIO_FRECUENCIA_MESES meses');
    programar('SGS_JOB_CIERRE_DIARIO', 'SGS_PKG_PROCESOS.cerrar_dia',
              'FREQ=DAILY;BYHOUR=0;BYMINUTE=5;BYSECOND=0',
              'Cierre diario del dia anterior con detalle por cajero');
END;

