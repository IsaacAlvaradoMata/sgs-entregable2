-- 00_reinicio_desarrollo.sql: elimina el esquema y los tablespaces del proyecto para volver a ejecutar todo desde cero.
-- Solo desarrollo (Docker, PDB FREEPDB1) como SYSTEM. NO se ejecuta en SGSPRI.
-- Antes de ejecutar: cerrar las conexiones abiertas como SGS_ADMIN, IALVARADO o los usuarios por rol (SGS_GERENTE, etc.).

-- 1. Validar que la sesion esta en una PDB y no en el CDB raiz
DECLARE
    v_contenedor VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CON_NAME');
BEGIN
    IF v_contenedor = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Conectarse a la PDB, no al CDB raiz');
    END IF;
END;
/

-- 2. Usuarios del proyecto (IALVARADO es el esquema del Entregable #1), usuarios por rol, roles y perfil de la seguridad
DECLARE
    PROCEDURE eliminar (p_sentencia IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sentencia;
    EXCEPTION
        WHEN OTHERS THEN
            -- ORA-01918 usuario, ORA-01919 rol y ORA-02380 perfil que no existen: no son errores en este contexto
            IF SQLCODE NOT IN (-1918, -1919, -2380) THEN
                RAISE;
            END IF;
    END;
BEGIN
    eliminar('DROP USER SGS_ADMIN CASCADE');
    eliminar('DROP USER IALVARADO CASCADE');
    eliminar('DROP USER SGS_GERENTE CASCADE');
    eliminar('DROP USER SGS_JEFE_DEPTO CASCADE');
    eliminar('DROP USER SGS_JEFE_PROVEEDURIA CASCADE');
    eliminar('DROP USER SGS_DIGITADOR CASCADE');
    eliminar('DROP ROLE SGS_ROL_GERENTE');
    eliminar('DROP ROLE SGS_ROL_JEFE_DEPTO');
    eliminar('DROP ROLE SGS_ROL_JEFE_PROVEEDURIA');
    eliminar('DROP ROLE SGS_ROL_DIGITADOR');
    eliminar('DROP PROFILE SGS_PERFIL_USUARIO CASCADE');
END;
/

-- 3. Tablespaces del proyecto, con sus datafiles
DECLARE
    PROCEDURE eliminar_tablespace (p_tablespace IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLESPACE ' || p_tablespace ||
                          ' INCLUDING CONTENTS AND DATAFILES';
    EXCEPTION
        WHEN OTHERS THEN
            -- ORA-00959: el tablespace no existe
            IF SQLCODE != -959 THEN
                RAISE;
            END IF;
    END;
BEGIN
    eliminar_tablespace('SGS_DATA');
    eliminar_tablespace('SGS_IDX');
    eliminar_tablespace('SGS_AUD');
END;
/

-- 4. Verificacion: ambas consultas deben devolver cero filas
SELECT username FROM dba_users WHERE username IN ('SGS_ADMIN', 'IALVARADO', 'SGS_GERENTE', 'SGS_JEFE_DEPTO', 'SGS_JEFE_PROVEEDURIA', 'SGS_DIGITADOR');
SELECT tablespace_name FROM dba_tablespaces WHERE tablespace_name LIKE 'SGS%';
