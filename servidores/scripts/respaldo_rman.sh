#!/bin/bash
# ================================================================
# respaldo_rman.sh
# SGS - Entregable #2 - Respaldo de la base principal con RMAN y
# copia al otro servidor
#
# Uso:  respaldo_rman.sh [0|1]
#   0 = backup full (incremental nivel 0)
#   1 = backup incremental nivel 1
#   Sin argumento: nivel 0 los domingos, nivel 1 los demás días.
#
# Se ejecuta como el usuario oracle, a demanda o desde el job
# SGS_JOB_RESPALDO_DIARIO. Está instalado igual en SGSPRI y SGSSTB:
# detecta en qué servidor corre y solo respalda si esa base es la
# PRIMARY (después de un switchover respalda la nueva principal).
# Deja un log por ejecución en /home/oracle/logs.
#
# Códigos de salida:
#   0 = respaldo y copia OK
#   1 = error de RMAN
#   2 = nivel inválido
#   3 = error al copiar al otro servidor
#   4 = la base de este servidor no es PRIMARY (no se respalda)
#   5 = servidor desconocido o base no disponible
# ================================================================

# Variables de Oracle (un job del scheduler no carga .bash_profile)
export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export PATH=$ORACLE_HOME/bin:/usr/bin:/bin

# Servidor actual y el otro servidor (destino de la copia)
case "$(hostname -s)" in
    sgspri) export ORACLE_SID=SGSPRI; OTRO=sgsstb ;;
    sgsstb) export ORACLE_SID=SGSSTB; OTRO=sgspri ;;
    *)      echo "Servidor desconocido: $(hostname -s)"; exit 5 ;;
esac

# Nivel del respaldo
if [ -n "$1" ]; then
    NIVEL=$1
elif [ "$(date +%u)" = "7" ]; then
    NIVEL=0
else
    NIVEL=1
fi
if [ "$NIVEL" != "0" ] && [ "$NIVEL" != "1" ]; then
    echo "Nivel inválido: $NIVEL (usar 0 o 1)"
    exit 2
fi

LOG_DIR=/home/oracle/logs
LOG=$LOG_DIR/respaldo_$(date +%Y%m%d_%H%M%S)_L$NIVEL.log
mkdir -p "$LOG_DIR"

echo "=== Respaldo nivel $NIVEL en $ORACLE_SID - inicio $(date) ===" >> "$LOG"

# 1. Solo se respalda la base principal
ROL=$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT database_role FROM v\$database;
EXIT;
SQL
)
ROL=$(echo "$ROL" | tr -d '[:space:]')
echo "Rol de $ORACLE_SID: $ROL" >> "$LOG"
if [ "$ROL" != "PRIMARY" ]; then
    case "$ROL" in
        PHYSICALSTANDBY)
            echo "=== $ORACLE_SID es standby: no se respalda - $(date) ===" >> "$LOG"
            echo "$ORACLE_SID no es la base principal: no se respalda (ver $LOG)"
            exit 4 ;;
        *)
            echo "=== No se pudo leer el rol de $ORACLE_SID - $(date) ===" >> "$LOG"
            echo "No se pudo leer el rol de $ORACLE_SID (ver $LOG)"
            exit 5 ;;
    esac
fi

ORIGEN=/opt/oracle/fast_recovery_area/$ORACLE_SID/
DESTINO=oracle@$OTRO:/opt/oracle/respaldos_$(echo "$ORACLE_SID" | tr 'A-Z' 'a-z')/

# 2. Respaldo con RMAN y limpieza de respaldos que ya no hacen falta
#    según la política de retención (REDUNDANCY 1)
rman target / >> "$LOG" 2>&1 <<RMAN
BACKUP INCREMENTAL LEVEL $NIVEL DATABASE TAG 'SGS_DIARIO_L$NIVEL' PLUS ARCHIVELOG;
CROSSCHECK BACKUP;
DELETE NOPROMPT OBSOLETE;
EXIT;
RMAN
if [ $? -ne 0 ]; then
    echo "=== ERROR en RMAN - $(date) ===" >> "$LOG"
    exit 1
fi

# 3. Copia al otro servidor (solo respaldos y archivos de redo; se
#    excluyen el control file vivo, los logs de flashback y los redo
#    en línea)
rsync -a --delete-excluded \
      --exclude='control*.ctl' --exclude='flashback/' --exclude='onlinelog/' \
      "$ORIGEN" "$DESTINO" >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "=== ERROR al copiar a $OTRO - $(date) ===" >> "$LOG"
    exit 3
fi

echo "=== Respaldo nivel $NIVEL en $ORACLE_SID - fin OK $(date) ===" >> "$LOG"
exit 0
