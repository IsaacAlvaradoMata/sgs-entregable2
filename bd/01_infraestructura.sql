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
SELECT tablespace_name, status, contents
  FROM dba_tablespaces
 WHERE tablespace_name LIKE 'SGS%'
 ORDER BY tablespace_name;

SELECT username, account_status, default_tablespace, temporary_tablespace
  FROM dba_users
 WHERE username = 'SGS_ADMIN';

SELECT privilege
  FROM dba_sys_privs
 WHERE grantee = 'SGS_ADMIN'
 ORDER BY privilege;

-- Debe devolver cero filas (sin CONNECT, RESOURCE ni DBA)
SELECT granted_role
  FROM dba_role_privs
 WHERE grantee = 'SGS_ADMIN';
