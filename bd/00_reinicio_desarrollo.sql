/* ================================================================
   00_reinicio_desarrollo.sql
   SGS - Entregable #2 - Administracion de Bases de Datos (EIF-402)

   SOLO PARA EL AMBIENTE DE DESARROLLO (Docker). NO se ejecuta en SGSPRI.
   Elimina el esquema del proyecto y sus tablespaces para volver a
   ejecutar todos los scripts desde cero.

   Ejecutar conectado a la PDB de desarrollo (FREEPDB1) como SYSTEM.
   Antes de ejecutar: cerrar cualquier conexion abierta como SGS_ADMIN
   o IALVARADO (si no, Oracle no permite eliminar el usuario).
   ================================================================ */

-- 1. Validar que la sesion esta en una PDB y no en el CDB raiz
DECLARE
    v_contenedor VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CON_NAME');
BEGIN
    IF v_contenedor = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Conectarse a la PDB, no al CDB raiz');
    END IF;
END;
/

-- 2. Usuarios del proyecto (IALVARADO es el esquema del Entregable #1)
DECLARE
    PROCEDURE eliminar_usuario (p_usuario IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP USER ' || p_usuario || ' CASCADE';
    EXCEPTION
        WHEN OTHERS THEN
            -- ORA-01918: el usuario no existe, no es un error en este contexto
            IF SQLCODE != -1918 THEN
                RAISE;
            END IF;
    END;
BEGIN
    eliminar_usuario('SGS_ADMIN');
    eliminar_usuario('IALVARADO');
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
SELECT username FROM dba_users WHERE username IN ('SGS_ADMIN', 'IALVARADO');
SELECT tablespace_name FROM dba_tablespaces WHERE tablespace_name LIKE 'SGS%';
