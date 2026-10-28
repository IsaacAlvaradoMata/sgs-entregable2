-- 01_infraestructura.sql: crea los tablespaces del proyecto y el usuario propietario SGS_ADMIN.
-- Se ejecuta como SYSTEM en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB en SGSPRI).
-- Antes de ejecutar: reemplazar <CLAVE_SGS_ADMIN> por la clave real.

-- 1. Validar que la sesion esta en una PDB y no en el CDB raiz
DECLARE
    v_contenedor VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CON_NAME');
BEGIN
    IF v_contenedor = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Conectarse a la PDB, no al CDB raiz');
    END IF;
END;
/

-- 2. Tablespaces: la ruta se toma del datafile SYSTEM de la PDB actual para que funcione en cualquier servidor
-- MAXSIZE finito para que el monitoreo de uso tenga un limite real contra el cual medir
DECLARE
    v_datafile  VARCHAR2(500);
    v_directorio VARCHAR2(500);
BEGIN
    SELECT file_name
      INTO v_datafile
      FROM dba_data_files
     WHERE tablespace_name = 'SYSTEM'
       AND ROWNUM = 1;

    v_directorio := SUBSTR(v_datafile, 1, INSTR(v_datafile, '/', -1));

    -- Tablas del sistema
    EXECUTE IMMEDIATE 'CREATE TABLESPACE SGS_DATA DATAFILE ''' || v_directorio ||
        'sgs_data01.dbf'' SIZE 200M AUTOEXTEND ON NEXT 50M MAXSIZE 4G';

    -- Indices
    EXECUTE IMMEDIATE 'CREATE TABLESPACE SGS_IDX DATAFILE ''' || v_directorio ||
        'sgs_idx01.dbf'' SIZE 100M AUTOEXTEND ON NEXT 20M MAXSIZE 2G';

    -- Auditoria y bitacoras
    EXECUTE IMMEDIATE 'CREATE TABLESPACE SGS_AUD DATAFILE ''' || v_directorio ||
        'sgs_aud01.dbf'' SIZE 50M AUTOEXTEND ON NEXT 10M MAXSIZE 1G';
END;
/

-- 3. Usuario propietario del esquema
CREATE USER SGS_ADMIN
    IDENTIFIED BY "<CLAVE_SGS_ADMIN>"
    DEFAULT TABLESPACE SGS_DATA
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON SGS_DATA
    QUOTA UNLIMITED ON SGS_IDX
    QUOTA UNLIMITED ON SGS_AUD;

-- 4. Privilegios de sistema: solo los necesarios, sin CONNECT, RESOURCE ni DBA
-- Los privilegios sobre paquetes del sistema (cifrado, correo, archivos) se otorgan en la etapa que los usa
GRANT CREATE SESSION           TO SGS_ADMIN;
GRANT CREATE TABLE             TO SGS_ADMIN;
GRANT CREATE SEQUENCE          TO SGS_ADMIN;
GRANT CREATE VIEW              TO SGS_ADMIN;
GRANT CREATE MATERIALIZED VIEW TO SGS_ADMIN;
GRANT CREATE PROCEDURE         TO SGS_ADMIN;
GRANT CREATE TRIGGER           TO SGS_ADMIN;
GRANT CREATE JOB               TO SGS_ADMIN;

-- 5. Verificacion
-- Tablespaces en linea con su tamano inicial y su MAXSIZE
SELECT t.tablespace_name,
       t.status,
       d.bytes / 1024 / 1024    AS tamano_mb,
       d.autoextensible,
       d.maxbytes / 1024 / 1024 AS maxsize_mb
  FROM dba_tablespaces t
  JOIN dba_data_files d ON d.tablespace_name = t.tablespace_name
 WHERE t.tablespace_name LIKE 'SGS%'
 ORDER BY t.tablespace_name;

-- Usuario abierto, tablespaces por defecto y cuotas (-1 = ilimitada)
SELECT u.username,
       u.account_status,
       u.default_tablespace,
       u.temporary_tablespace,
       q.tablespace_name AS tablespace_cuota,
       DECODE(q.max_bytes, -1, 'ILIMITADA', TO_CHAR(q.max_bytes / 1024 / 1024) || ' MB') AS cuota
  FROM dba_users u
  JOIN dba_ts_quotas q ON q.username = u.username
 WHERE u.username = 'SGS_ADMIN'
 ORDER BY q.tablespace_name;

SELECT privilege
  FROM dba_sys_privs
 WHERE grantee = 'SGS_ADMIN'
 ORDER BY privilege;

-- Debe devolver cero filas (sin CONNECT, RESOURCE ni DBA)
SELECT granted_role
  FROM dba_role_privs
 WHERE grantee = 'SGS_ADMIN';
