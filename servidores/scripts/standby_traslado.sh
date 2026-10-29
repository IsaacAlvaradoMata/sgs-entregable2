#!/bin/bash
# ================================================================
# standby_traslado.sh
# SGS - Entregable #2 - Traslado de la información al standby
#
# Uso:  standby_traslado.sh
#
# Cierra el archivo de redo actual (ALTER SYSTEM ARCHIVE LOG CURRENT):
# Oracle lo archiva y lo envía completo a la standby, que lo aplica.
# Lo ejecuta el job SGS_JOB_STB_TRASLADO cada STB_MINUTOS_TRASLADO
# minutos y también se puede correr a demanda en la revisión.
#
# Está instalado igual en SGSPRI y SGSSTB y solo actúa si su base es
# la PRIMARY. Log por ejecución en /home/oracle/logs.
#
# Códigos de salida:
#   0 = archivo cerrado y enviado
#   1 = error al cerrar el archivo
#   4 = la base de este servidor no es PRIMARY (no hace nada)
#   5 = servidor desconocido o base no disponible
# ================================================================

export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export PATH=$ORACLE_HOME/bin:/usr/bin:/bin

case "$(hostname -s)" in
    sgspri) export ORACLE_SID=SGSPRI ;;
    sgsstb) export ORACLE_SID=SGSSTB ;;
    *)      echo "Servidor desconocido: $(hostname -s)"; exit 5 ;;
esac

LOG_DIR=/home/oracle/logs
LOG=$LOG_DIR/traslado_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$LOG_DIR"

echo "=== Traslado al standby desde $ORACLE_SID - inicio $(date) ===" >> "$LOG"

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

# 2. Cerrar el archivo actual y anotar la secuencia que se envió
SALIDA=$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
WHENEVER SQLERROR EXIT 1
ALTER SYSTEM ARCHIVE LOG CURRENT;
SELECT 'Secuencia enviada: ' || MAX(sequence#) FROM v\$archived_log WHERE dest_id = 1;
EXIT;
SQL
)
RESULTADO=$?
echo "$SALIDA" >> "$LOG"
if [ $RESULTADO -ne 0 ]; then
    echo "=== ERROR al cerrar el archivo de redo - $(date) ===" >> "$LOG"
    exit 1
fi

echo "=== Traslado al standby desde $ORACLE_SID - fin OK $(date) ===" >> "$LOG"
exit 0
