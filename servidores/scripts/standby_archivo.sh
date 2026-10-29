#!/bin/bash
# ================================================================
# standby_archivo.sh
# SGS - Entregable #2 - Archivo de actualización cada N minutos o
# cada N MB (parámetros STB_MINUTOS_ARCHIVO y STB_MB_ARCHIVO)
#
# Uso:  standby_archivo.sh <minutos> <mb>
#
# - Minutos: se aplican con la propiedad ArchiveLagTarget del broker
#   (en segundos) en las dos bases, para que valga también después
#   de un switchover. Cada servidor cambia su propia base con
#   "dgmgrl /" (la del otro servidor se cambia por SSH), así que no
#   hace falta guardar la clave de SYS. Solo se cambia si es distinto.
# - MB: un archivo se genera cada vez que se llena un redo log. Si el
#   tamaño de los redo logs no coincide con el parámetro, se avisa al
#   DBA por correo (rehacer los redo logs con Data Guard se hace a mano).
#
# Se ejecuta como oracle desde el job SGS_JOB_STB_ARCHIVO o a demanda.
# Está instalado igual en SGSPRI y SGSSTB y solo actúa si su base es
# la PRIMARY. Log por ejecución en /home/oracle/logs.
#
# Códigos de salida:
#   0 = OK (minutos aplicados; si los MB no coinciden, se avisó al DBA)
#   2 = argumentos inválidos
#   4 = la base de este servidor no es PRIMARY (no hace nada)
#   5 = servidor desconocido o base no disponible
#   6 = error al aplicar ArchiveLagTarget
# ================================================================

export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export PATH=$ORACLE_HOME/bin:/usr/bin:/bin
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

case "$(hostname -s)" in
    sgspri) export ORACLE_SID=SGSPRI; OTRO=sgsstb; OTRO_SID=SGSSTB ;;
    sgsstb) export ORACLE_SID=SGSSTB; OTRO=sgspri; OTRO_SID=SGSPRI ;;
    *)      echo "Servidor desconocido: $(hostname -s)"; exit 5 ;;
esac

MINUTOS=$1
MB=$2
if ! [[ "$MINUTOS" =~ ^[0-9]+$ ]] || ! [[ "$MB" =~ ^[0-9]+$ ]] || [ "$MINUTOS" -lt 1 ] || [ "$MB" -lt 1 ]; then
    echo "Uso: standby_archivo.sh <minutos> <mb> (enteros mayores que 0)"
    exit 2
fi
SEGUNDOS=$((MINUTOS * 60))

LOG_DIR=/home/oracle/logs
LOG=$LOG_DIR/archivo_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$LOG_DIR"

echo "=== Archivo cada $MINUTOS min / $MB MB en $ORACLE_SID - inicio $(date) ===" >> "$LOG"

# 1. Solo actúa la base principal
ROL=$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT database_role FROM v\$database;
EXIT;
SQL
)
ROL=$(echo "$ROL" | tr -d '[:space:]')
echo "Rol de $ORACLE_SID: $ROL" >> "$LOG"
case "$ROL" in
    PRIMARY) ;;
    PHYSICALSTANDBY)
        echo "=== $ORACLE_SID es standby: no hace nada - $(date) ===" >> "$LOG"
        echo "$ORACLE_SID no es la base principal: no hace nada (ver $LOG)"
        exit 4 ;;
    *)
        echo "=== No se pudo leer el rol de $ORACLE_SID - $(date) ===" >> "$LOG"
        echo "No se pudo leer el rol de $ORACLE_SID (ver $LOG)"
        exit 5 ;;
esac

# 2. Minutos: ArchiveLagTarget en esta base y en la otra
ERROR=0
ACTUAL=$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT value FROM v\$parameter WHERE name = 'archive_lag_target';
EXIT;
SQL
)
ACTUAL=$(echo "$ACTUAL" | tr -d '[:space:]')
echo "archive_lag_target en $ORACLE_SID: $ACTUAL (se pide $SEGUNDOS)" >> "$LOG"
if [ "$ACTUAL" != "$SEGUNDOS" ]; then
    SALIDA=$(dgmgrl -silent / "EDIT DATABASE '$ORACLE_SID' SET PROPERTY ArchiveLagTarget=$SEGUNDOS;" 2>&1)
    echo "$ORACLE_SID: $SALIDA" >> "$LOG"
    echo "$SALIDA" | grep -q "updated" || ERROR=1
fi

CMD="EDIT DATABASE '$OTRO_SID' SET PROPERTY ArchiveLagTarget=$SEGUNDOS;"
SALIDA=$(ssh -o BatchMode=yes -o ConnectTimeout=10 oracle@$OTRO \
    "ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$OTRO_SID $ORACLE_HOME/bin/dgmgrl -silent / \"$CMD\"" 2>&1)
echo "$OTRO_SID: $SALIDA" >> "$LOG"
echo "$SALIDA" | grep -q "updated" || ERROR=1

if [ $ERROR -ne 0 ]; then
    echo "=== ERROR al aplicar ArchiveLagTarget - $(date) ===" >> "$LOG"
    exit 6
fi

# 3. MB: tamaño de los redo logs contra el parámetro
MB_REDO=$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT MAX(bytes)/1024/1024 FROM v\$log;
EXIT;
SQL
)
MB_REDO=$(echo "$MB_REDO" | tr -d '[:space:]')
echo "Redo logs de $MB_REDO MB (parámetro: $MB MB)" >> "$LOG"
if [ "$MB_REDO" != "$MB" ]; then
    sqlplus -s / as sysdba >> "$LOG" 2>&1 <<SQL
ALTER SESSION SET CONTAINER = SGSPDB;
EXEC SGS_ADMIN.SGS_PKG_CORREO.enviar_a_tipo('DBA', 'SGS: tamaño de los redo logs distinto de STB_MB_ARCHIVO', 'En $ORACLE_SID los redo logs miden $MB_REDO MB y el parámetro STB_MB_ARCHIVO pide $MB MB. Hay que rehacer los grupos de redo y de standby redo con el tamaño nuevo, o corregir el parámetro.');
EXIT;
SQL
    echo "AVISO: redo de $MB_REDO MB y parámetro de $MB MB; correo enviado al DBA" >> "$LOG"
fi

echo "=== Archivo cada $MINUTOS min / $MB MB en $ORACLE_SID - fin OK $(date) ===" >> "$LOG"
exit 0
