-- extraer_diccionario.sql: saca del catalogo de Oracle los datos del diccionario (se ejecuta como SGS_ADMIN con SQL*Plus).
-- Deja meta.txt, cols.txt y otros.txt en /tmp; despues: generar_diccionario.js (ver su encabezado).
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON LONG 4000 VERIFY OFF
SPOOL /tmp/meta.txt
SELECT 'T|' || t.table_name || '|' || t.tablespace_name || '|' || REPLACE(c.comments, '|', '/')
  FROM user_tables t LEFT JOIN user_tab_comments c ON c.table_name = t.table_name
 WHERE t.external = 'NO' AND NOT EXISTS (SELECT 1 FROM user_mviews m WHERE m.mview_name = t.table_name)
 ORDER BY t.table_name;
SELECT 'K|' || k.table_name || '|' || k.constraint_name || '|' || k.constraint_type || '|' ||
       (SELECT LISTAGG(cc.column_name, ', ') WITHIN GROUP (ORDER BY cc.position) FROM user_cons_columns cc WHERE cc.constraint_name = k.constraint_name) || '|' ||
       CASE WHEN k.constraint_type = 'R' THEN (SELECT r.table_name || ' (' || (SELECT LISTAGG(rc.column_name, ', ') WITHIN GROUP (ORDER BY rc.position) FROM user_cons_columns rc WHERE rc.constraint_name = r.constraint_name) || ')' FROM user_constraints r WHERE r.constraint_name = k.r_constraint_name)
            WHEN k.constraint_type = 'C' THEN REPLACE(REPLACE(k.search_condition_vc, CHR(10), ' '), '|', '/') END
  FROM user_constraints k
  JOIN user_tables t ON t.table_name = k.table_name AND t.external = 'NO'
 WHERE k.constraint_type IN ('P','U','R','C') AND k.constraint_name NOT LIKE 'SYS_C%'
   AND NOT EXISTS (SELECT 1 FROM user_mviews v WHERE v.mview_name = k.table_name)
 ORDER BY k.table_name, DECODE(k.constraint_type,'P',1,'U',2,'R',3,'C',4), k.constraint_name;
SELECT 'I|' || i.table_name || '|' || i.index_name || '|' || i.uniqueness || '|' || i.tablespace_name || '|' ||
       (SELECT LISTAGG(ic.column_name, ', ') WITHIN GROUP (ORDER BY ic.column_position) FROM user_ind_columns ic WHERE ic.index_name = i.index_name)
  FROM user_indexes i JOIN user_tables t ON t.table_name = i.table_name AND t.external = 'NO'
 WHERE NOT EXISTS (SELECT 1 FROM user_mviews v WHERE v.mview_name = i.table_name) AND i.index_type <> 'LOB'
 ORDER BY i.table_name, i.index_name;
SELECT 'N|' || COUNT(*) FROM user_constraints WHERE constraint_name LIKE 'SYS_C%' AND constraint_type = 'C';
SPOOL OFF

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SPOOL /tmp/cols.txt
DECLARE
    v_def VARCHAR2(4000);
BEGIN
    FOR c IN (SELECT c.table_name, c.column_id, c.column_name, c.data_type, c.char_length, c.data_precision, c.data_scale,
                     c.nullable, c.data_default, m.comments
                FROM user_tab_columns c
                JOIN user_tables t ON t.table_name = c.table_name AND t.external = 'NO'
                LEFT JOIN user_col_comments m ON m.table_name = c.table_name AND m.column_name = c.column_name
               WHERE NOT EXISTS (SELECT 1 FROM user_mviews v WHERE v.mview_name = c.table_name)
               ORDER BY c.table_name, c.column_id) LOOP
        v_def := REPLACE(REPLACE(TRIM(c.data_default), CHR(10), ' '), CHR(13), '');
        DBMS_OUTPUT.PUT_LINE('C|' || c.table_name || '|' || c.column_id || '|' || c.column_name || '|' || c.data_type ||
            CASE WHEN c.data_type IN ('VARCHAR2', 'CHAR') THEN '(' || c.char_length || ')'
                 WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL
                      THEN '(' || c.data_precision || CASE WHEN c.data_scale > 0 THEN ',' || c.data_scale END || ')' END
            || '|' || c.nullable || '|' || REPLACE(v_def, '|', '/') || '|' || REPLACE(c.comments, '|', '/'));
    END LOOP;
END;
/
SPOOL OFF

SET SERVEROUTPUT OFF
SPOOL /tmp/otros.txt
SELECT 'V|' || v.view_name || '|' || REPLACE(c.comments, '|', '/') FROM user_views v LEFT JOIN user_tab_comments c ON c.table_name = v.view_name ORDER BY 1;
SELECT 'M|' || m.mview_name || '|' || m.refresh_method || ' ' || m.refresh_mode || '|' || REPLACE(c.comments, '|', '/') FROM user_mviews m LEFT JOIN user_mview_comments c ON c.mview_name = m.mview_name ORDER BY 1;
SELECT 'X|' || t.table_name || '|' || t.default_directory_name || '|' || REPLACE(c.comments, '|', '/') FROM user_external_tables t LEFT JOIN user_tab_comments c ON c.table_name = t.table_name ORDER BY 1;
SELECT 'Q|' || sequence_name FROM user_sequences ORDER BY 1;
SPOOL OFF
EXIT
