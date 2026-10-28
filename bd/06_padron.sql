-- 06_padron.sql: carga del padron nacional del TSE (distritos electorales y personas) desde los archivos oficiales.
-- Seccion 0 como SYS (SYSDBA); el resto como SGS_ADMIN. Ambas en la PDB del ambiente (desarrollo: FREEPDB1, oficial: SGSPDB).
-- Solo se ejecuta en el servidor principal; el standby recibe el directorio y los datos por el redo.
-- La carga inicial (seccion 4) tarda unos minutos: son 3,7 millones de personas.
-- Antes de la seccion 0: copiar PADRON_COMPLETO.txt y distelec.txt a la carpeta del servidor, con dueno oracle,
-- y reemplazar <RUTA_PADRON> por esa carpeta (desarrollo: /opt/oracle/oradata/padron).

-- 0. EJECUTAR COMO SYS (SYSDBA): el directorio se crea en la PDB, no en CDB$ROOT (ahi no existe SGS_ADMIN)
BEGIN
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Cambiar a la PDB antes de seguir: ALTER SESSION SET CONTAINER = <PDB>');
    END IF;
END;
/

-- Lectura de los archivos y escritura de los .log y .bad de cada lectura
CREATE OR REPLACE DIRECTORY SGS_DIR_PADRON AS '<RUTA_PADRON>';
GRANT READ, WRITE ON DIRECTORY SGS_DIR_PADRON TO SGS_ADMIN;

-- 1. A partir de aqui, conectado como SGS_ADMIN: validar que la sesion es del dueno del esquema
DECLARE
    v_usuario VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
BEGIN
    IF v_usuario <> 'SGS_ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Ejecutar conectado como SGS_ADMIN, no como ' || v_usuario);
    END IF;
END;
/

-- 2. Tablas externas: Oracle lee los archivos del TSE como tablas, sin copiarlos antes
-- Los archivos vienen en Latin-1; la base es AL32UTF8 y la Ñ ocupa 2 bytes, por eso las columnas son mas anchas que el campo

-- distelec: la linea completa (un distrito trae una coma en el nombre); se separa en el MERGE
CREATE TABLE SGS_EXT_DISTELEC (
    LINEA  VARCHAR2(400)
)
ORGANIZATION EXTERNAL (
    TYPE ORACLE_LOADER
    DEFAULT DIRECTORY SGS_DIR_PADRON
    ACCESS PARAMETERS (
        RECORDS DELIMITED BY NEWLINE
        CHARACTERSET WE8ISO8859P1
        BADFILE SGS_DIR_PADRON:'distelec.bad'
        LOGFILE SGS_DIR_PADRON:'distelec.log'
        FIELDS TERMINATED BY '|'
        MISSING FIELD VALUES ARE NULL
        (LINEA CHAR(200))
    )
    LOCATION ('distelec.txt')
)
REJECT LIMIT UNLIMITED;

-- Padron: todas las lineas miden 118 caracteres, cada campo esta siempre en la misma posicion (sexo y junta no se leen)
CREATE TABLE SGS_EXT_PADRON (
    CEDULA     VARCHAR2(9),
    CODELEC    VARCHAR2(6),
    CADUCIDAD  VARCHAR2(8),
    NOMBRE     VARCHAR2(60),
    APELLIDO1  VARCHAR2(52),
    APELLIDO2  VARCHAR2(52)
)
ORGANIZATION EXTERNAL (
    TYPE ORACLE_LOADER
    DEFAULT DIRECTORY SGS_DIR_PADRON
    ACCESS PARAMETERS (
        RECORDS DELIMITED BY NEWLINE
        CHARACTERSET WE8ISO8859P1
        BADFILE SGS_DIR_PADRON:'padron.bad'
        LOGFILE SGS_DIR_PADRON:'padron.log'
        FIELDS (
            CEDULA     POSITION(1:9)    CHAR(9),
            CODELEC    POSITION(11:16)  CHAR(6),
            CADUCIDAD  POSITION(20:27)  CHAR(8),
            NOMBRE     POSITION(35:64)  CHAR(30),
            APELLIDO1  POSITION(66:91)  CHAR(26),
            APELLIDO2  POSITION(93:118) CHAR(26)
        )
    )
    LOCATION ('PADRON_COMPLETO.txt')
)
REJECT LIMIT UNLIMITED;

-- 3. Carga del padron
-- MERGE de distritos por codelec y de personas por cedula: inserta las nuevas y actualiza solo las que cambiaron.
-- Nunca borra (los clientes enlazados al padron no pierden su referencia). Sin NOLOGGING: la standby recibe la carga.
CREATE OR REPLACE PACKAGE SGS_PKG_PADRON AS
    -- p_distritos y p_personas: filas insertadas o actualizadas; p_rechazadas: lineas del padron que no se cargaron
    PROCEDURE cargar (p_distritos OUT NUMBER, p_personas OUT NUMBER, p_rechazadas OUT NUMBER);
END;
/

CREATE OR REPLACE PACKAGE BODY SGS_PKG_PADRON AS

    PROCEDURE cargar (p_distritos OUT NUMBER, p_personas OUT NUMBER, p_rechazadas OUT NUMBER) IS
    BEGIN
        SAVEPOINT sp_cargar;

        -- Codelec, provincia y canton son los tres primeros campos; el distrito es el resto de la linea
        MERGE INTO SGS_DISTRITO_ELECTORAL d
        USING (SELECT TRIM(REGEXP_SUBSTR(x.LINEA, '[^,]+', 1, 1)) AS CODELEC,
                      TRIM(REGEXP_SUBSTR(x.LINEA, '[^,]+', 1, 2)) AS PROVINCIA,
                      TRIM(REGEXP_SUBSTR(x.LINEA, '[^,]+', 1, 3)) AS CANTON,
                      TRIM(SUBSTR(x.LINEA, INSTR(x.LINEA, ',', 1, 3) + 1)) AS DISTRITO
                 FROM (SELECT RTRIM(REPLACE(LINEA, CHR(13))) AS LINEA FROM SGS_EXT_DISTELEC) x
                WHERE REGEXP_COUNT(x.LINEA, ',') >= 3) s
           ON (d.DIS_CODELEC = s.CODELEC)
         WHEN MATCHED THEN
              UPDATE SET d.DIS_PROVINCIA = s.PROVINCIA, d.DIS_CANTON = s.CANTON, d.DIS_DISTRITO = s.DISTRITO
               WHERE d.DIS_PROVINCIA <> s.PROVINCIA OR d.DIS_CANTON <> s.CANTON OR d.DIS_DISTRITO <> s.DISTRITO
         WHEN NOT MATCHED THEN
              INSERT (DIS_ID, DIS_CODELEC, DIS_PROVINCIA, DIS_CANTON, DIS_DISTRITO)
              VALUES (SEQ_DISTRITO_ELECTORAL.NEXTVAL, s.CODELEC, s.PROVINCIA, s.CANTON, s.DISTRITO);
        p_distritos := SQL%ROWCOUNT;

        -- Solo personas con cedula valida y distrito conocido; DECODE compara tambien los nulos
        MERGE INTO SGS_PADRON p
        USING (SELECT e.CEDULA,
                      TRIM(e.NOMBRE) AS NOMBRE,
                      TRIM(e.APELLIDO1) AS APELLIDO1,
                      TRIM(e.APELLIDO2) AS APELLIDO2,
                      TO_DATE(e.CADUCIDAD DEFAULT NULL ON CONVERSION ERROR, 'YYYYMMDD') AS CADUCIDAD,
                      d.DIS_ID
                 FROM SGS_EXT_PADRON e
                 JOIN SGS_DISTRITO_ELECTORAL d ON d.DIS_CODELEC = e.CODELEC
                WHERE REGEXP_LIKE(e.CEDULA, '^[0-9]{9}$')
                  AND TRIM(e.NOMBRE) IS NOT NULL) s
           ON (p.PAD_CEDULA = s.CEDULA)
         WHEN MATCHED THEN
              UPDATE SET p.PAD_NOMBRE = s.NOMBRE, p.PAD_APELLIDO1 = s.APELLIDO1, p.PAD_APELLIDO2 = s.APELLIDO2,
                         p.PAD_FECHA_CADUCIDAD = s.CADUCIDAD, p.PAD_ID_DISTRITO = s.DIS_ID
               WHERE DECODE(p.PAD_NOMBRE, s.NOMBRE, 0, 1) + DECODE(p.PAD_APELLIDO1, s.APELLIDO1, 0, 1)
                     + DECODE(p.PAD_APELLIDO2, s.APELLIDO2, 0, 1) + DECODE(p.PAD_FECHA_CADUCIDAD, s.CADUCIDAD, 0, 1)
                     + DECODE(p.PAD_ID_DISTRITO, s.DIS_ID, 0, 1) > 0
         WHEN NOT MATCHED THEN
              INSERT (PAD_ID, PAD_CEDULA, PAD_NOMBRE, PAD_APELLIDO1, PAD_APELLIDO2, PAD_FECHA_CADUCIDAD, PAD_ID_DISTRITO)
              VALUES (SEQ_PADRON.NEXTVAL, s.CEDULA, s.NOMBRE, s.APELLIDO1, s.APELLIDO2, s.CADUCIDAD, s.DIS_ID);
        p_personas := SQL%ROWCOUNT;

        SELECT COUNT(*)
          INTO p_rechazadas
          FROM SGS_EXT_PADRON e
         WHERE NOT REGEXP_LIKE(e.CEDULA, '^[0-9]{9}$')
            OR TRIM(e.NOMBRE) IS NULL
            OR NOT EXISTS (SELECT 1 FROM SGS_DISTRITO_ELECTORAL d WHERE d.DIS_CODELEC = e.CODELEC);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO sp_cargar;
            SGS_PKG_ERRORES.registrar('SGS_PKG_PADRON.cargar');
            RAISE;
    END;

END;
/

-- 4. Carga inicial del padron (despues, cada vez que el TSE publique uno nuevo, se vuelve a ejecutar este bloque)
DECLARE
    v_distritos  NUMBER;
    v_personas   NUMBER;
    v_rechazadas NUMBER;
BEGIN
    SGS_PKG_PADRON.cargar(v_distritos, v_personas, v_rechazadas);
    DBMS_OUTPUT.PUT_LINE('Distritos: ' || v_distritos || ' | Personas: ' || v_personas || ' | Rechazadas: ' || v_rechazadas);
END;
/
