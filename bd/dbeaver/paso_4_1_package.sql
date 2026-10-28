CREATE OR REPLACE PACKAGE SGS_PKG_BITACORA AS
    PROCEDURE iniciar;
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN VARCHAR2, p_nuevo IN VARCHAR2, p_es_critica IN VARCHAR2 DEFAULT 'N');
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN NUMBER,   p_nuevo IN NUMBER,   p_es_critica IN VARCHAR2 DEFAULT 'N');
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN DATE,     p_nuevo IN DATE,     p_es_critica IN VARCHAR2 DEFAULT 'N');
    FUNCTION desde (p_programa IN VARCHAR2) RETURN BOOLEAN;
    PROCEDURE guardar (p_area        IN VARCHAR2,
                       p_tabla       IN VARCHAR2,
                       p_operacion   IN VARCHAR2,
                       p_registro_id IN NUMBER,
                       p_es_critica  IN VARCHAR2 DEFAULT 'N');
END;

CREATE OR REPLACE PACKAGE BODY SGS_PKG_BITACORA AS
    TYPE t_columna IS RECORD (columna VARCHAR2(128), anterior VARCHAR2(250), nuevo VARCHAR2(250));
    TYPE t_columnas IS TABLE OF t_columna INDEX BY PLS_INTEGER;
    g_columnas t_columnas;
    g_critica  BOOLEAN := FALSE;
    PROCEDURE iniciar IS
    BEGIN
        g_columnas.DELETE;
        g_critica := FALSE;
    END;
    PROCEDURE agregar (p_columna IN VARCHAR2, p_anterior IN VARCHAR2, p_nuevo IN VARCHAR2, p_es_critica IN VARCHAR2) IS
        v_i PLS_INTEGER;
    BEGIN
        IF p_anterior = p_nuevo OR (p_anterior IS NULL AND p_nuevo IS NULL) THEN
            RETURN;
        END IF;
        v_i := g_columnas.COUNT + 1;
        g_columnas(v_i).columna  := p_columna;
        g_columnas(v_i).anterior := SUBSTR(p_anterior, 1, 250);
        g_columnas(v_i).nuevo    := SUBSTR(p_nuevo, 1, 250);
        IF p_es_critica = 'S' THEN
            g_critica := TRUE;
        END IF;
    END;
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN VARCHAR2, p_nuevo IN VARCHAR2, p_es_critica IN VARCHAR2 DEFAULT 'N') IS
    BEGIN
        agregar(p_columna, p_anterior, p_nuevo, p_es_critica);
    END;
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN NUMBER, p_nuevo IN NUMBER, p_es_critica IN VARCHAR2 DEFAULT 'N') IS
    BEGIN
        agregar(p_columna,
                TO_CHAR(p_anterior, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,'''),
                TO_CHAR(p_nuevo, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,'''),
                p_es_critica);
    END;
    PROCEDURE columna (p_columna IN VARCHAR2, p_anterior IN DATE, p_nuevo IN DATE, p_es_critica IN VARCHAR2 DEFAULT 'N') IS
    BEGIN
        agregar(p_columna,
                TO_CHAR(p_anterior, 'YYYY-MM-DD HH24:MI:SS'),
                TO_CHAR(p_nuevo, 'YYYY-MM-DD HH24:MI:SS'),
                p_es_critica);
    END;
    FUNCTION desde (p_programa IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN INSTR(UPPER(DBMS_UTILITY.FORMAT_CALL_STACK), UPPER(p_programa)) > 0;
    END;
    PROCEDURE guardar (p_area        IN VARCHAR2,
                       p_tabla       IN VARCHAR2,
                       p_operacion   IN VARCHAR2,
                       p_registro_id IN NUMBER,
                       p_es_critica  IN VARCHAR2 DEFAULT 'N') IS
        v_id      SGS_BITACORA.BIT_ID%TYPE;
        v_critica SGS_BITACORA.BIT_ES_CRITICA%TYPE := 'N';
    BEGIN
        IF p_operacion = 'U' AND g_columnas.COUNT = 0 THEN
            iniciar;
            RETURN;
        END IF;
        IF p_es_critica = 'S' OR p_operacion = 'D' OR (p_operacion = 'U' AND g_critica) THEN
            v_critica := 'S';
        END IF;
        INSERT INTO SGS_BITACORA (BIT_ID, BIT_AREA, BIT_TABLA, BIT_OPERACION, BIT_REGISTRO_ID, BIT_ES_CRITICA)
        VALUES (SEQ_BITACORA.NEXTVAL, p_area, p_tabla, p_operacion, p_registro_id, v_critica)
        RETURNING BIT_ID INTO v_id;
        FOR v_i IN 1 .. g_columnas.COUNT LOOP
            INSERT INTO SGS_BITACORA_DETALLE (BID_ID, BID_ID_BITACORA, BID_COLUMNA, BID_VALOR_ANTERIOR, BID_VALOR_NUEVO)
            VALUES (SEQ_BITACORA_DETALLE.NEXTVAL, v_id, g_columnas(v_i).columna, g_columnas(v_i).anterior, g_columnas(v_i).nuevo);
        END LOOP;
        iniciar;
    EXCEPTION
        WHEN OTHERS THEN
            iniciar;
            RAISE;
    END;
END;

