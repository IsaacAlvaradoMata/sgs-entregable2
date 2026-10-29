#!/bin/bash
# ================================================================
# standby_borrado.sh
# SGS - Entregable #2 - Borrado de archivos de redo ya trasladados
# y aplicados (parámetro STB_DIAS_BORRADO)
#
# Uso:  standby_borrado.sh <dias>
#   <dias> admite decimales para las pruebas (0.02 = unos 30 minutos).
#
# Borra con RMAN los archivos de redo de más de <dias> días en la
# principal y en la standby (en la standby por SSH, porque los jobs
# del scheduler no corren en una base de solo lectura). Las dos bases
# tienen ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY, así que
# RMAN no borra ningún archivo que la standby todavía no haya aplicado.
#
# Lo ejecuta el job SGS_JOB_STB_BORRADO todos los días o a demanda.
# Está instalado igual en SGSPRI y SGSSTB y solo actúa si su base es
# la PRIMARY. Log por ejecución en /home/oracle/logs.
#
# Códigos de salida:
#   0 = OK en los dos servidores
#   1 = error de RMAN en este servidor
#   2 = argumento inválido
#   3 = error de RMAN en el otro servidor
#   4 = la base de este servidor no es PRIMARY (no hace nada)
#   5 = servidor desconocido o base no disponible
# ================================================================

export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export PATH=$ORACLE_HOME/bin:/usr/bin:/bin

case "$(hostname -s)" in
    sgspri) export ORACLE_SID=SGSPRI; OTRO=sgsstb; OTRO_SID=SGSSTB ;;
    sgsstb) export ORACLE_SID=SGSSTB; OTRO=sgspri; OTRO_SID=SGSPRI ;;
    *)      echo "Servidor desconocido: $(hostname -s)"; exit 5 ;;
esac

DIAS=$1
if ! [[ "$DIAS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Uso: standby_borrado.sh <dias> (número, 0 o más; admite decimales)"
    exit 2
fi

LOG_DIR=/home/oracle/logs
LOG=$LOG_DIR/borrado_$(date +%Y%m%d_%H%M%S).log
mkdir -p "$LOG_DIR"

echo "=== Borrado de archivos de más de $DIAS días desde $ORACLE_SID - inicio $(date) ===" >> "$LOG"

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

# Archivos de redo en disco con más de DIAS días. En la principal se cuentan los del destino local
# (dest_id 1); los del destino remoto solo registran el envío a la standby.
contar_local () {
    sqlplus -s / as sysdba <<SQL | tr -d '[:space:]'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM v\$archived_log WHERE deleted = 'NO' AND name IS NOT NULL AND dest_id = 1 AND completion_time < SYSDATE - $DIAS;
EXIT;
SQL
}
contar_otro () {
    ssh -o BatchMode=yes -o ConnectTimeout=10 oracle@$OTRO \
        "ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$OTRO_SID $ORACLE_HOME/bin/sqlplus -s / as sysdba" <<SQL | tr -d '[:space:]'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM v\$archived_log WHERE deleted = 'NO' AND name IS NOT NULL AND completion_time < SYSDATE - $DIAS;
EXIT;
SQL
}

BORRAR="DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-$DIAS';
EXIT;"

# RMAN termina con error si no hay nada que borrar; eso no es un error del proceso
rman_ok () {
    [ "$1" -eq 0 ] || echo "$2" | grep -q "does not match any archived log"
}

# 2. Este servidor (principal)
ANTES=$(contar_local)
SALIDA=$(echo "$BORRAR" | rman target / 2>&1)
RESULTADO=$?
echo "$SALIDA" >> "$LOG"
DESPUES=$(contar_local)
echo "$ORACLE_SID: archivos de más de $DIAS días antes=$ANTES después=$DESPUES" >> "$LOG"
if ! rman_ok $RESULTADO "$SALIDA"; then
    echo "=== ERROR de RMAN en $ORACLE_SID - $(date) ===" >> "$LOG"
    exit 1
fi

# 3. El otro servidor (standby), por SSH
ANTES=$(contar_otro)
SALIDA=$(echo "$BORRAR" | ssh -o BatchMode=yes -o ConnectTimeout=10 oracle@$OTRO \
    "ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$OTRO_SID $ORACLE_HOME/bin/rman target /" 2>&1)
RESULTADO=$?
echo "$SALIDA" >> "$LOG"
DESPUES=$(contar_otro)
echo "$OTRO_SID: archivos de más de $DIAS días antes=$ANTES después=$DESPUES" >> "$LOG"
if ! rman_ok $RESULTADO "$SALIDA"; then
    echo "=== ERROR de RMAN en $OTRO_SID - $(date) ===" >> "$LOG"
    exit 3
fi

echo "=== Borrado de archivos de más de $DIAS días desde $ORACLE_SID - fin OK $(date) ===" >> "$LOG"
exit 0
