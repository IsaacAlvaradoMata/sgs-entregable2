#!/bin/bash
# ================================================================
# respaldo_rman.sh
# SGS - Entregable #2 - Respaldo de SGSPRI con RMAN y copia a SGSSTB
#
# Uso:  respaldo_rman.sh [0|1]
#   0 = backup full (incremental nivel 0)
#   1 = backup incremental nivel 1
#   Sin argumento: nivel 0 los domingos, nivel 1 los demás días.
#
# Se ejecuta como el usuario oracle en SGSPRI, a demanda o desde
# un job de DBMS_SCHEDULER. Deja un log por ejecución en
# /home/oracle/logs y termina con código 0 si todo salió bien.
# ================================================================

# Variables de Oracle (un job del scheduler no carga .bash_profile)
export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export ORACLE_SID=SGSPRI
export PATH=$ORACLE_HOME/bin:/usr/bin:/bin

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

ORIGEN=/opt/oracle/fast_recovery_area/SGSPRI/
DESTINO=oracle@sgsstb:/opt/oracle/respaldos_sgspri/
LOG_DIR=/home/oracle/logs
LOG=$LOG_DIR/respaldo_$(date +%Y%m%d_%H%M%S)_L$NIVEL.log
mkdir -p "$LOG_DIR"

echo "=== Respaldo nivel $NIVEL - inicio $(date) ===" >> "$LOG"

# 1. Respaldo con RMAN y limpieza de respaldos que ya no hacen falta
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

# 2. Copia al standby (solo respaldos y archivos de redo; se excluyen
#    el control file vivo, los logs de flashback y los redo en línea)
rsync -a --delete-excluded \
      --exclude='control*.ctl' --exclude='flashback/' --exclude='onlinelog/' \
      "$ORIGEN" "$DESTINO" >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "=== ERROR al copiar a SGSSTB - $(date) ===" >> "$LOG"
    exit 3
fi

echo "=== Respaldo nivel $NIVEL - fin OK $(date) ===" >> "$LOG"
exit 0
