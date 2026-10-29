---
titulo: Manual de Instalación y Despliegue
---

# Introducción

Este manual describe, paso a paso, cómo se instaló el Sistema de Gestión de Supermercados (SGS) en los dos servidores del proyecto: el servidor principal `SGSPRI` y el servidor standby `SGSSTB`, ambos con Oracle Database 21c Enterprise Edition sobre Oracle Linux 8.10. Cubre la preparación del equipo anfitrión, la instalación de Oracle, la base standby con Data Guard, los respaldos con RMAN, el acceso remoto, la instalación del esquema de la base de datos y las verificaciones del despliegue. Al final se resume qué parte del sistema resuelve cada requerimiento del enunciado.

Todos los pasos de este manual se ejecutaron y se verificaron en los servidores del proyecto. Las claves nunca aparecen escritas: se indican como `<CLAVE_…>` y se reemplazan por las del ambiente que se instala.

## Arquitectura

Los dos servidores son máquinas virtuales de VirtualBox en el mismo equipo anfitrión (una HP con Windows 11). Se comunican por una red interna solo-anfitrión (`192.168.56.0/24`), por donde viajan Data Guard, las copias de los respaldos y las conexiones SSH entre ellos. Cada VM tiene además una tarjeta NAT con salida directa a internet, que es la que usa Oracle para enviar los correos. El equipo cliente (un Mac con DBeaver) llega a las bases por Tailscale, una red privada que solo enruta el tráfico hacia las direcciones `100.x` de sus equipos: el resto del tráfico, incluido el correo, no pasa por ella.

![Arquitectura del despliegue](docs/manuales/imagenes/arquitectura.png)

| Elemento | SGSPRI | SGSSTB |
|---|---|---|
| Rol normal | Principal (`PRIMARY`, lectura y escritura) | Standby física (solo lectura, aplicando cambios) |
| Nombre de host | `sgspri.localdomain` | `sgsstb.localdomain` |
| Red interna | `192.168.56.101` | `192.168.56.102` |
| Tailscale | `100.76.209.30` | `100.69.133.78` |
| `DB_NAME` / `DB_UNIQUE_NAME` / SID | `SGS` / `SGSPRI` / `SGSPRI` | `SGS` / `SGSSTB` / `SGSSTB` |
| PDB del sistema (servicio) | `SGSPDB` (`sgspdb`) | `SGSPDB` (`sgspdb`, solo lectura) |

## Conceptos

- **CDB y PDB.** Oracle 21c organiza la base como un contenedor (CDB `SGS`) con bases conectables (PDB). Todo el sistema vive en la PDB `SGSPDB`, en el esquema `SGS_ADMIN`; la raíz del contenedor (`CDB$ROOT`) solo se usa para la administración del servidor (Data Guard, RMAN, parámetros de la instancia).
- **Redo y archivos archivados.** Cada cambio en la base queda primero en los redo logs. Cuando un redo log se llena (o cuando se fuerza un cambio de archivo), Oracle lo copia como archivo archivado. Esos archivos son los que se envían a la standby y los que RMAN usa para recuperar la base hasta el último momento.
- **Data Guard y standby física.** La standby es una copia exacta de la principal que recibe el redo y lo aplica continuamente. Con Active Data Guard se puede consultar en solo lectura mientras aplica. Si la principal falla, la standby toma su lugar (failover); también se pueden intercambiar los roles de forma planeada (switchover).
- **Broker de Data Guard (dgmgrl).** Administra la configuración `sgs_dg`: el envío del redo, el estado de la sincronización, los cambios de rol y propiedades como `ArchiveLagTarget`.
- **Fast Recovery Area (FRA).** Carpeta administrada por Oracle (`/opt/oracle/fast_recovery_area`, 20 GB) donde quedan los archivos archivados, los respaldos de RMAN y los registros de flashback.
- **Flashback Database.** Permite regresar la base a un momento anterior. Data Guard lo usa para reincorporar como standby un servidor que cayó, sin copiar la base de nuevo.
- **RMAN.** Herramienta de Oracle para respaldar y recuperar la base: respaldo completo (nivel 0), incremental (nivel 1), restauración y recuperación.
- **Wallet y lista de control de red.** Oracle bloquea toda conexión saliente: la lista de control de red (ACL) autoriza a `SGS_ADMIN` a conectarse solo a `smtp.gmail.com`. Gmail exige TLS, y Oracle valida su certificado contra un wallet con los certificados raíz de Google.
- **Tablas externas.** Permiten leer un archivo del servidor como si fuera una tabla. Así se leen los archivos del padrón del TSE antes de cargarlos.
- **DBMS_SCHEDULER.** El programador de Oracle. Todos los procesos automáticos del sistema son jobs del scheduler; corren en la base principal (la standby está en solo lectura) y viajan con la base, así que después de un cambio de roles corren en la nueva principal.
- **Tailscale sin exit node.** Tailscale crea una red privada entre los equipos del proyecto. Sin exit node, solo el tráfico hacia `100.x` pasa por Tailscale; el correo sale de cada VM por su propia conexión a internet, como pide el enunciado.

# Requisitos

## Equipo anfitrión

| Elemento | Valor |
|---|---|
| Equipo | HP ProBook 445 G10 |
| Procesador | AMD Ryzen 5 7530U (6 núcleos, 12 hilos) |
| Memoria | 16 GB (cada VM usa 5 GB) |
| Disco | 475 GB (cada VM usa un disco dinámico de 80 GB) |
| Sistema | Windows 11 Pro |

## Software

| Software | Versión | Dónde se obtiene |
|---|---|---|
| VirtualBox | 7.2 para Windows | https://www.virtualbox.org/wiki/Downloads |
| Oracle Linux | 8.10, ISO completa (`OracleLinux-R8-U10-x86_64-dvd.iso`) | https://yum.oracle.com/oracle-linux-isos.html |
| Oracle Database | 21c Enterprise Edition, RPM (`oracle-database-ee-21c-1.0-1.ol8.x86_64.rpm`) | https://www.oracle.com/database/technologies/oracle21c-linux-downloads.html |
| Tailscale | Versión actual | https://tailscale.com |
| DBeaver | Versión actual | https://dbeaver.io |
| SQL*Plus | El de Oracle 21c (en los servidores) o cualquier cliente Oracle | Incluido en la instalación |

Se usa Oracle Linux 8 porque es el sistema certificado para Oracle 21c, y la edición Enterprise porque Data Guard solo existe en ella.

## Cuentas y archivos

- Una cuenta de Gmail para las notificaciones (`sgs.notificaciones.una@gmail.com`) con una **contraseña de aplicación** (Cuenta de Google → Seguridad → Contraseñas de aplicaciones). Es la que Oracle usa para enviar los correos.
- Los archivos del padrón nacional del TSE: `PADRON_COMPLETO.txt` (personas, unos 431 MB) y `distelec.txt` (distritos electorales).
- El repositorio del proyecto con las carpetas `bd/` (scripts de la base) y `servidores/scripts/` (scripts de los servidores).

## Valores del despliegue

| Valor | Uso |
|---|---|
| `<CLAVE_SYS>` | Usuario `SYS` (igual en las dos bases; lo usan Data Guard, RMAN y la instalación) |
| `<CLAVE_SYSTEM>` | Usuario `SYSTEM` |
| `<CLAVE_ORACLE_LINUX>` | Usuario `oracle` del sistema operativo (la credencial de los jobs que ejecutan scripts) |
| `<CLAVE_SGS_ADMIN>` | Dueño del esquema del sistema |
| `<LLAVE_CIFRADO>` | Llave AES-256 del package de cifrado: 64 caracteres hexadecimales, distinta en cada ambiente |
| `<CLAVE_CORREO>` | Contraseña de aplicación de Gmail |
| `<CLAVE_USUARIO_*>` | Usuarios de Oracle por rol: `GERENTE`, `JEFE_DEPTO`, `JEFE_PROVEEDURIA`, `DIGITADOR` |
| `<CLAVE_ROL_*>` | Clave de cada rol (`SGS_ROL_GERENTE`, etc.); se guarda cifrada en la tabla de parámetros |

# Preparación del equipo anfitrión

## Desactivar el hipervisor de Windows

Windows usa la virtualización para su propia seguridad. Si el hipervisor de Windows queda activo, VirtualBox corre sobre él y las VMs se traban bajo carga (`soft lockup`), cortan el SSH y pueden congelarse durante instalaciones grandes. Por eso se desactiva antes de crear las VMs:

1. Seguridad de Windows → Seguridad del dispositivo → Aislamiento del núcleo → **Integridad de memoria: Desactivado**.
2. Características de Windows → desmarcar **Plataforma de máquina virtual** (Hyper-V, Plataforma del hipervisor y Espacio aislado también desmarcados).
3. En `cmd` como administrador, y reiniciar:

```
bcdedit /set hypervisorlaunchtype off
```

4. Si `msinfo32` todavía indica "Seguridad basada en virtualización: En ejecución", desactivarla desde `cmd` como administrador y reiniciar:

```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LsaCfgFlags /t REG_DWORD /d 0 /f
```

En `msinfo32` debe quedar "Seguridad basada en virtualización: No habilitado".

![Seguridad basada en virtualización deshabilitada](servidores/capturas/s1_sgspri/04b_vbs_deshabilitada_hyperv_si.png)

## VirtualBox y la red interna

1. Instalar VirtualBox 7.2 con las opciones por defecto (el Extension Pack no se necesita) y abrirlo en **Expert Mode**.
2. Archivo → Herramientas → Network Manager → Redes solo-anfitrión: adaptador `VirtualBox Host-Only Ethernet Adapter` configurado a mano con `192.168.56.1` / `255.255.255.0` y el **servidor DHCP deshabilitado**, porque las VMs usan IP fija.

![Red solo-anfitrión sin DHCP](servidores/capturas/s1_sgspri/08_red_solo_anfitrion_dhcp_off.png)

# Servidor principal SGSPRI

## Crear la máquina virtual

| Opción | Valor |
|---|---|
| Nombre | `SGSPRI` |
| Tipo / versión | Linux / Oracle Linux 8.x (64-bit) |
| Instalación desatendida | Desmarcada |
| Memoria / CPU | 5120 MB / 2 |
| EFI | Desmarcado |
| Disco | 80 GB, VDI, dinámico |
| Adaptador 1 | NAT (salida a internet) |
| Adaptador 2 | Adaptador solo-anfitrión (red interna) |
| Audio | Deshabilitado |

![Las dos tarjetas de red de la VM](servidores/capturas/s1_sgspri/14_vm_red_nat_y_solo_anfitrion.png)

## Instalar Oracle Linux 8.10

En el menú de arranque de la ISO: **Install Oracle Linux 8.10.0**, instalador en inglés.

| Sección del instalador | Valor |
|---|---|
| Keyboard | Spanish; Castilian (Latin American) y English (US) |
| Time & Date | Americas / Costa Rica |
| Software Selection | **Server** (sin interfaz gráfica, para ahorrar memoria) |
| Installation Destination | Personalizado: `/boot` 1 GiB, `swap` 5 GiB, `/` 74 GiB (sin `/home`) |
| KDUMP | Deshabilitado |
| Host Name | `sgspri.localdomain` |
| `enp0s3` | NAT, DHCP |
| `enp0s8` | Manual: `192.168.56.101/24`, sin gateway |
| Root Password | Definida |

Al terminar se quita la ISO (Dispositivos → Unidades ópticas) y se reinicia.

## Red, SSH y hora

En el primer inicio, como `root`, se verifica el nombre y la salida a internet, y se deja activa la red interna (el instalador la muestra configurada, pero puede quedar sin activar):

```
hostname                 # sgspri.localdomain
ping -c 3 google.com
nmcli con mod enp0s8 ipv4.method manual ipv4.addresses 192.168.56.101/24 connection.autoconnect yes
nmcli con up enp0s8
ip addr show enp0s8      # inet 192.168.56.101/24
```

Desde aquí todo se hace por SSH desde PowerShell en la HP: `ssh root@192.168.56.101`.

Los jobs del sistema y Data Guard necesitan la hora exacta. La zona `America/Costa_Rica` queda desde la instalación; se activa la sincronización y se configura `chronyd` para que corrija el reloj de golpe cada vez que el desfase pase de 1 segundo (por ejemplo, después de suspender la HP con las VMs encendidas):

```
systemctl enable --now chronyd
sed -i 's/^makestep .*/makestep 1 -1/' /etc/chrony.conf
systemctl restart chronyd
# Time zone: America/Costa_Rica (CST, -0600) y System clock synchronized: yes
timedatectl
# System time: fracciones de segundo
chronyc tracking
```

![Hora sincronizada en SGSPRI](servidores/capturas/operacion/14_sgspri_hora_sincronizada.png)

## Preparar Linux para Oracle

Como `root`:

```
dnf install -y oracle-database-preinstall-21c
dnf install -y unzip wget nano tmux rsync
passwd oracle
```

El paquete `oracle-database-preinstall-21c` crea el usuario `oracle`, sus grupos y los ajustes del kernel que pide Oracle. Si la instalación se interrumpe, `dnf reinstall -y oracle-database-preinstall-21c` vuelve a aplicarlos.

Nombres de los dos servidores (Data Guard se comunica por nombre), SELinux en modo permisivo y el puerto del listener abierto:

```
cat >> /etc/hosts <<EOF
192.168.56.101  sgspri.localdomain  sgspri
192.168.56.102  sgsstb.localdomain  sgsstb
EOF
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0
firewall-cmd --permanent --add-port=1521/tcp
firewall-cmd --reload
```

## Instalar Oracle Database 21c

El RPM se copia desde la HP (PowerShell) y se instala como `root`. Descomprime unos 7 GB y tarda varios minutos:

```
scp "$env:USERPROFILE\Downloads\oracle-database-ee-21c-1.0-1.ol8.x86_64.rpm" root@192.168.56.101:/tmp/
```

```
dnf -y localinstall /tmp/oracle-database-ee-21c-1.0-1.ol8.x86_64.rpm
```

Con el RPM las rutas son fijas: `ORACLE_BASE=/opt/oracle` y `ORACLE_HOME=/opt/oracle/product/21c/dbhome_1`; los archivos de red (`listener.ora` y `tnsnames.ora`) quedan en `/opt/oracle/homes/OraDBHome21cEE/network/admin`. No se usa el script de configuración que sugiere el RPM, porque crea una base con nombres de ejemplo.

![Software de Oracle 21c instalado](servidores/capturas/s2_sgspri/07_rpm_oracle_21c_instalado.png)

Variables del usuario `oracle` (`su - oracle`). `NLS_LANG` en `AL32UTF8` es necesario para que SQL*Plus lea bien los scripts del sistema, que traen tildes y eñes:

```
cat >> ~/.bash_profile <<'EOF'

# Oracle 21c - SGS
export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/21c/dbhome_1
export ORACLE_SID=SGSPRI
export PATH=$ORACLE_HOME/bin:$PATH
export LD_LIBRARY_PATH=$ORACLE_HOME/lib
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
EOF
source ~/.bash_profile
```

Listener en el puerto 1521:

```
netca -silent -responsefile $ORACLE_HOME/assistants/netca/netca.rsp
lsnrctl status           # (HOST=sgspri.localdomain)(PORT=1521)
```

## Crear la base de datos

Data Guard exige el mismo `DB_NAME` en las dos bases y un `DB_UNIQUE_NAME` distinto. La base se crea como `oracle` dentro de `tmux` (si se corta el SSH, `dbca` sigue y se retoma con `tmux attach -t dbca`):

```
tmux new -s dbca
lsnrctl start
mkdir -p /opt/oracle/fast_recovery_area
dbca -silent -createDatabase \
  -templateName General_Purpose.dbc \
  -gdbName SGS -sid SGSPRI \
  -createAsContainerDatabase true -numberOfPDBs 1 -pdbName SGSPDB \
  -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
  -databaseType MULTIPURPOSE -memoryMgmtType AUTO_SGA -totalMemory 2048 \
  -storageType FS -datafileDestination /opt/oracle/oradata \
  -enableArchive true \
  -recoveryAreaDestination /opt/oracle/fast_recovery_area -recoveryAreaSize 20480 \
  -emConfiguration NONE \
  -initParams db_unique_name=SGSPRI
```

`dbca` pide las claves de `SYS`, `SYSTEM` y `PDBADMIN` y tarda unos 6 minutos. El juego de caracteres `AL32UTF8` es necesario porque los nombres del padrón traen tildes y eñes, y el modo `ARCHIVELOG` (`-enableArchive true`) porque Data Guard y RMAN trabajan con los archivos archivados.

![Base creada con dbca](servidores/capturas/s2_sgspri/13_dbca_100_completo.png)

Verificación (`sqlplus / as sysdba`) y apertura automática de la PDB al arrancar:

```
-- SGS  SGSPRI  ARCHIVELOG  READ WRITE
SELECT name, db_unique_name, log_mode, open_mode FROM v$database;
-- SGSPDB  READ WRITE
SHOW PDBS
ALTER PLUGGABLE DATABASE SGSPDB SAVE STATE;
```

La base debe anunciarse en el listener con su dirección directa, para no depender de alias de `tnsnames.ora`:

```
ALTER SYSTEM SET local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=sgspri.localdomain)(PORT=1521))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
```

Después, `lsnrctl status` muestra los servicios `SGSPRI`, `SGSPRIXDB` y `sgspdb` con `status READY`.

# Servidor standby SGSSTB

## Clonar SGSPRI

`SGSSTB` se crea clonando `SGSPRI` cuando esta ya tiene Linux, el software de Oracle y el listener, pero **todavía no tiene base de datos**. Así las dos quedan con las mismas rutas y paquetes. Con `SGSPRI` apagada (`shutdown -h now`), en VirtualBox: clic derecho sobre `SGSPRI` → Clonar.

| Opción | Valor |
|---|---|
| Nombre | `SGSSTB` |
| Tipo de clon | Clonación completa |
| Direcciones MAC | Generar nuevas para todos los adaptadores |

![Clonación de SGSPRI](servidores/capturas/s1_sgsstb/01_clonar_sgspri.png)

## Darle identidad propia

Con `SGSPRI` todavía apagada (al principio las dos tienen la IP `.101`), se enciende solo `SGSSTB`, se entra con `ssh root@192.168.56.101` y se cambia su identidad. El cambio de IP va al final porque corta el SSH:

```
hostnamectl set-hostname sgsstb.localdomain
sed -i 's/ORACLE_SID=SGSPRI/ORACLE_SID=SGSSTB/' /home/oracle/.bash_profile
sed -i 's/sgspri.localdomain/sgsstb.localdomain/' /opt/oracle/homes/OraDBHome21cEE/network/admin/listener.ora
nmcli con mod enp0s8 ipv4.addresses 192.168.56.102/24 && nmcli con up enp0s8
```

Se reconecta con `ssh root@192.168.56.102` (SSH avisa que ya conoce la huella porque es un clon) y se verifica que, con las dos VMs encendidas, cada una llega a la otra por nombre:

```
hostname                     # sgsstb.localdomain
ping -c 3 sgspri             # desde SGSSTB
ping -c 3 sgsstb             # desde SGSPRI
```

![Identidad de SGSSTB](servidores/capturas/s1_sgsstb/04_identidad_sgsstb_verificada.png)

En `SGSSTB` también se activa `chronyd` con `makestep 1 -1`, igual que en `SGSPRI`.

# Data Guard

Todos los comandos de esta sección se ejecutan como `oracle`, en `sqlplus / as sysdba` desde la raíz del contenedor, salvo que se indique otra cosa.

## Preparar la principal

En `SGSPRI`, registro forzado de todo cambio (si una operación no genera redo, la standby queda inconsistente) y flashback para poder reincorporar un servidor después de un failover:

```
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE FLASHBACK ON;
```

Redo logs de 50 MB: el enunciado pide un archivo de actualización cada 5 minutos o cada 50 MB, y cada vez que se llena un redo log se genera un archivo archivado. Se agregan tres grupos de 50 MB y se borran los de 200 MB que creó `dbca` (solo se pueden borrar cuando están `INACTIVE`):

```
ALTER DATABASE ADD LOGFILE GROUP 4 ('/opt/oracle/oradata/SGSPRI/redo04.log') SIZE 50M;
ALTER DATABASE ADD LOGFILE GROUP 5 ('/opt/oracle/oradata/SGSPRI/redo05.log') SIZE 50M;
ALTER DATABASE ADD LOGFILE GROUP 6 ('/opt/oracle/oradata/SGSPRI/redo06.log') SIZE 50M;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
SELECT group#, bytes/1024/1024 AS mb, status FROM v$log ORDER BY group#;
ALTER DATABASE DROP LOGFILE GROUP 1;
ALTER DATABASE DROP LOGFILE GROUP 2;
ALTER DATABASE DROP LOGFILE GROUP 3;
HOST rm /opt/oracle/oradata/SGSPRI/redo01.log /opt/oracle/oradata/SGSPRI/redo02.log /opt/oracle/oradata/SGSPRI/redo03.log
```

Standby redo logs, que la standby usa para recibir los cambios en tiempo real: un grupo más que los redo normales y del mismo tamaño. Se crean también en la principal para cuando cambie de rol:

```
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 11 ('/opt/oracle/oradata/SGSPRI/standby_redo11.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 12 ('/opt/oracle/oradata/SGSPRI/standby_redo12.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 13 ('/opt/oracle/oradata/SGSPRI/standby_redo13.log') SIZE 50M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 14 ('/opt/oracle/oradata/SGSPRI/standby_redo14.log') SIZE 50M;
SELECT force_logging, flashback_on FROM v$database;     -- YES  YES
```

![Redo de 50 MB, registro forzado y flashback](servidores/capturas/s3_dataguard/07_redo_50mb_force_flashback_yes.png)

Parámetros de Data Guard en `SGSPRI`:

```
ALTER SYSTEM SET log_archive_config='DG_CONFIG=(SGSPRI,SGSSTB)' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=SGSPRI' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_2='SERVICE=SGSSTB ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=SGSSTB' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_state_2='DEFER' SCOPE=BOTH;
ALTER SYSTEM SET fal_server='SGSSTB' SCOPE=BOTH;
ALTER SYSTEM SET standby_file_management='AUTO' SCOPE=BOTH;
ALTER SYSTEM SET db_file_name_convert='/opt/oracle/oradata/SGSSTB/','/opt/oracle/oradata/SGSPRI/' SCOPE=SPFILE;
ALTER SYSTEM SET log_file_name_convert='/opt/oracle/oradata/SGSSTB/','/opt/oracle/oradata/SGSPRI/' SCOPE=SPFILE;
```

| Parámetro | Para qué |
|---|---|
| `log_archive_config` | Qué bases forman la configuración |
| `log_archive_dest_1` | Archivado local en la FRA |
| `log_archive_dest_2` | Envío del redo a `SGSSTB` (asíncrono); en pausa hasta que exista la standby |
| `fal_server` | A quién pedir los archivos que falten cuando esta base sea standby |
| `standby_file_management=AUTO` | Los datafiles nuevos (por ejemplo, los tablespaces del sistema) se crean solos en la standby |
| `*_name_convert` | Traducción de rutas para cuando esta base sea standby |

## Red de Oracle en los dos servidores

En `SGSPRI` y en `SGSSTB`, el mismo `tnsnames.ora` en `/opt/oracle/homes/OraDBHome21cEE/network/admin/`. `(UR = A)` permite conectarse a una instancia que todavía no tiene la base montada, como la standby antes de duplicarla:

```
cat > /opt/oracle/homes/OraDBHome21cEE/network/admin/tnsnames.ora <<'EOF'
SGSPRI =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgspri.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = SGSPRI)(UR = A))
  )

SGSSTB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgsstb.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = SGSSTB)(UR = A))
  )

SGSPDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = sgspri.localdomain)(PORT = 1521))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = sgspdb))
  )
EOF
```

Registro estático en `listener.ora`, que permite conectarse a la instancia aunque la base esté apagada; el servicio `*_DGMGRL` lo usa el broker en los cambios de rol. En `SGSPRI` (en `SGSSTB` es igual, cambiando `SGSPRI` por `SGSSTB`):

```
cat >> /opt/oracle/homes/OraDBHome21cEE/network/admin/listener.ora <<'EOF'

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = SGSPRI)
      (ORACLE_HOME = /opt/oracle/product/21c/dbhome_1)
      (SID_NAME = SGSPRI)
    )
    (SID_DESC =
      (GLOBAL_DBNAME = SGSPRI_DGMGRL)
      (ORACLE_HOME = /opt/oracle/product/21c/dbhome_1)
      (SID_NAME = SGSPRI)
    )
  )
EOF
lsnrctl reload           # en SGSSTB: lsnrctl start
```

Verificación: `tnsping SGSSTB` desde `SGSPRI` y `tnsping SGSPRI` desde `SGSSTB` deben decir "Used TNSNAMES adapter" y `OK`.

## Crear la standby

El archivo de contraseñas debe ser el mismo en las dos bases. Desde `SGSPRI`:

```
scp /opt/oracle/dbs/orapwSGSPRI oracle@sgsstb:/opt/oracle/dbs/orapwSGSSTB
```

En `SGSSTB`: carpetas, un archivo de parámetros mínimo y arranque de la instancia sin base:

```
mkdir -p /opt/oracle/oradata/SGSSTB/pdbseed /opt/oracle/oradata/SGSSTB/SGSPDB
mkdir -p /opt/oracle/fast_recovery_area /opt/oracle/admin/SGSSTB/adump
echo "*.db_name='SGS'" > /opt/oracle/dbs/initSGSSTB.ora
sqlplus / as sysdba
STARTUP NOMOUNT PFILE='/opt/oracle/dbs/initSGSSTB.ora';
```

Desde `SGSPRI`, dentro de `tmux`, RMAN copia la base en vivo por la red (pide dos veces la clave de `SYS`):

```
rman target sys@SGSPRI auxiliary sys@SGSSTB
```

```
DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET db_unique_name='SGSSTB'
    SET control_files='/opt/oracle/oradata/SGSSTB/control01.ctl','/opt/oracle/oradata/SGSSTB/control02.ctl'
    SET db_file_name_convert='/opt/oracle/oradata/SGSPRI/','/opt/oracle/oradata/SGSSTB/'
    SET log_file_name_convert='/opt/oracle/oradata/SGSPRI/','/opt/oracle/oradata/SGSSTB/'
    SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=SGSSTB'
    SET log_archive_dest_2='SERVICE=SGSPRI ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=SGSPRI'
    SET log_archive_dest_state_2='ENABLE'
    SET fal_server='SGSPRI'
    SET audit_file_dest='/opt/oracle/admin/SGSSTB/adump'
    SET dispatchers='(PROTOCOL=TCP) (SERVICE=SGSSTBXDB)'
  NOFILENAMECHECK;
```

La duplicación tarda unos 4 minutos y termina con `Finished Duplicate Db`.

![Duplicación de la standby terminada](servidores/capturas/s3_dataguard/17_rman_duplicate_finished.png)

## Arrancar la sincronización

En `SGSSTB`: abrir en solo lectura (Active Data Guard), dirección del listener y aplicación de los cambios:

```
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
ALTER SYSTEM SET local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=sgsstb.localdomain)(PORT=1521))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
```

En `SGSPRI`, activar el envío:

```
ALTER SYSTEM SET log_archive_dest_state_2='ENABLE' SCOPE=BOTH;
ALTER SYSTEM SWITCH LOGFILE;
SELECT dest_id, status, error FROM v$archive_dest WHERE dest_id = 2;   -- 2  VALID
```

Prueba: un dato insertado en `SGSPRI` (dentro de `SGSPDB`) aparece segundos después en `SGSSTB`, y la standby rechaza escribir con `ORA-16000` porque está en solo lectura.

![El dato llega a SGSSTB y la standby no acepta escrituras](servidores/capturas/s3_dataguard/22_prueba_dato_en_sgsstb_y_ora16000.png)

## Broker de Data Guard

El broker se encarga del envío del redo, así que primero se borra el destino configurado a mano. En las dos bases:

```
ALTER SYSTEM SET log_archive_dest_2='' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;
```

En `SGSPRI`, como `oracle`:

```
dgmgrl sys@SGSPRI
CREATE CONFIGURATION sgs_dg AS PRIMARY DATABASE IS SGSPRI CONNECT IDENTIFIER IS SGSPRI;
ADD DATABASE SGSSTB AS CONNECT IDENTIFIER IS SGSSTB MAINTAINED AS PHYSICAL;
ENABLE CONFIGURATION;
SHOW CONFIGURATION;      -- Configuration Status: SUCCESS
SHOW DATABASE SGSSTB;    -- Transport Lag 0 s, Apply Lag 0 s, Real Time Query ON
```

La standby creada con `DUPLICATE` no hereda el flashback. En `SGSSTB` se activó (`ALTER DATABASE FLASHBACK ON;`) la primera vez que quedó como principal, durante la prueba de failover, para poder reincorporarla también a ella si alguna vez cae.

![Configuración del broker en SUCCESS](servidores/capturas/s6_switchover_failover/02_broker_configuracion_success.png)

La configuración queda en modo MaxPerformance (envío asíncrono) y sin Fast-Start Failover: los cambios de rol se hacen a mano, como se describe en el manual de administración del standby.

# Respaldos con RMAN

## Configuración

En `SGSPRI`, como `oracle`, `rman target /`:

```
CONFIGURE RETENTION POLICY TO REDUNDANCY 1;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
```

| Configuración | Por qué |
|---|---|
| `REDUNDANCY 1` | Un respaldo completo vigente; la segunda copia está en el otro servidor |
| `CONTROLFILE AUTOBACKUP ON` | Después de cada respaldo se guardan el control file y el spfile |
| `BACKUP OPTIMIZATION ON` | No repite archivos ya respaldados |
| `COMPRESSED BACKUPSET` | Compresión básica, incluida sin licencia adicional |
| `ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY` | RMAN no borra archivos que la standby todavía no aplicó |

En `SGSSTB` se configura la misma regla de borrado (`CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;`), para que allí solo se borre lo ya aplicado.

## Llaves SSH y carpetas de copia

Los procesos automáticos no pueden escribir contraseñas, así que el usuario `oracle` de cada servidor entra al otro con una llave SSH, en los dos sentidos (para que funcione también después de un cambio de roles):

```
# En SGSPRI (como oracle)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id oracle@sgsstb
ssh oracle@sgsstb hostname         # sgsstb.localdomain, sin pedir clave

# En SGSSTB (como oracle)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
ssh-copy-id oracle@sgspri
ssh oracle@sgspri hostname         # sgspri.localdomain
```

Los respaldos de cada servidor se copian al otro con `rsync` en `/opt/oracle/respaldos_sgspri` (en `SGSSTB`) o `/opt/oracle/respaldos_sgsstb` (en `SGSPRI`).

## Scripts de los servidores

Los cuatro scripts de `servidores/scripts/` se instalan igual en los dos servidores, como `oracle`, en `/home/oracle/scripts`. Cada uno detecta en qué servidor corre y **solo actúa si su base es la principal**; lo que hay que hacer en la otra base lo hace por SSH:

```
mkdir -p ~/scripts ~/logs
for s in respaldo_rman.sh standby_archivo.sh standby_traslado.sh standby_borrado.sh; do
  curl -fsSL -o ~/scripts/$s https://raw.githubusercontent.com/IsaacAlvaradoMata/sgs-entregable2/main/servidores/scripts/$s
  chmod +x ~/scripts/$s
done
```

| Script | Qué hace |
|---|---|
| `respaldo_rman.sh [0\|1]` | Respaldo con RMAN (nivel 0 los domingos, nivel 1 los demás días), limpieza de lo obsoleto y copia al otro servidor |
| `standby_archivo.sh <minutos> <mb>` | Aplica el tiempo máximo entre archivos (`ArchiveLagTarget`) en las dos bases y avisa al DBA si el tamaño de los redo logs no coincide con el parámetro |
| `standby_traslado.sh` | Cierra el archivo de redo actual para que viaje completo a la standby |
| `standby_borrado.sh <días>` | Borra en las dos bases los archivos archivados con más de N días ya trasladados y aplicados |

Prueba a mano del respaldo en la principal (en la standby el mismo comando termina con `Resultado: 4` sin respaldar):

```
~/scripts/respaldo_rman.sh 1; echo "Resultado: $?"      # Resultado: 0
```

![Respaldo a demanda en SGSPRI](servidores/capturas/s5_rman/27_script_en_sgspri_respalda_ok.png)

Los jobs que ejecutan estos scripts se crean con `bd/11_standby.sql`, en la instalación del esquema.

# Acceso remoto

## Tailscale

En cada VM, como `root` (la llave de autorización se genera en la consola de Tailscale, se usa una sola vez y se revoca cuando las dos VMs están unidas):

```
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey <LLAVE_TAILSCALE> --hostname sgspri      # en SGSSTB: --hostname sgsstb
tailscale ip -4
history -c
```

En el Mac se instala la aplicación de Tailscale y se inicia sesión con la misma cuenta. Se verifica que no haya exit node y que el tráfico a internet salga por la tarjeta NAT de la VM, no por Tailscale:

```
tailscale status         # sin "exit node"
ip route get 8.8.8.8     # 8.8.8.8 via 10.0.2.2 dev enp0s3
```

El listener ya escucha en todas las tarjetas de red (`ss -ltn | grep 1521` muestra `*:1521`), así que no hay que cambiar nada en Oracle para recibir conexiones por Tailscale.

## Conexiones de DBeaver

| Conexión | Host | Servicio | Usuario | Rol |
|---|---|---|---|---|
| `SGSPRI - SYS (SGSPDB)` | `100.76.209.30` | `sgspdb` | `SYS` | `SYSDBA` |
| `SGSPRI - SYSTEM (SGSPDB)` | `100.76.209.30` | `sgspdb` | `SYSTEM` | Normal |
| `SGSPRI - SGS_ADMIN (SGSPDB)` | `100.76.209.30` | `sgspdb` | `SGS_ADMIN` | Normal |
| `SGSSTB - SYS (SGSPDB)` | `100.69.133.78` | `sgspdb` | `SYS` | `SYSDBA` |
| `SGSSTB - SGS_ADMIN (SGSPDB)` | `100.69.133.78` | `sgspdb` | `SGS_ADMIN` | Normal |

En todas: puerto `1521`, Database como **Service Name**, autenticación usuario y contraseña. Mientras `SGSSTB` sea la principal (después de un switchover o failover), el trabajo se hace con sus conexiones.

![Conexión a SGSPDB por Tailscale (desde SGSSTB, como lo hace el equipo cliente)](docs/manuales/imagenes/conexion_tailscale.png)

# Preparación para la base de datos del proyecto

Lo que el sistema necesita fuera de la base no viaja por Data Guard, así que se prepara en **las dos** VMs con las mismas rutas. Así, después de un switchover o failover, la nueva principal funciona sin cambiar ningún parámetro. Todo como `oracle`.

## Puerto de Gmail

```
timeout 10 bash -c 'exec 3<>/dev/tcp/smtp.gmail.com/587; head -1 <&3' || echo "SIN RESPUESTA EN 587"
echo QUIT | timeout 15 openssl s_client -connect smtp.gmail.com:465 2>/dev/null | grep -c "BEGIN CERTIFICATE"
```

En las dos VMs el 587 no respondió y el 465 sí, así que el parámetro `CORREO_PUERTO` queda en `465` (TLS desde el inicio). La lista de control de red de la base autoriza los dos puertos; si en otra red solo respondiera el 587, basta cambiar el parámetro.

![Prueba de los puertos de Gmail](servidores/capturas/i1_preparacion/01_sgspri_puertos_gmail.png)

## Wallet del correo

```
WALLET=/opt/oracle/oradata/wallet_sgs
mkdir -p $WALLET/certs && cd $WALLET/certs
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do curl -sfO https://pki.goog/repo/certs/$c.pem && echo "$c OK" || echo "$c FALLO"; done
$ORACLE_HOME/bin/orapki wallet create -wallet $WALLET -auto_login_only
for c in gtsr1 gtsr2 gtsr3 gtsr4 we2 wr2; do $ORACLE_HOME/bin/orapki wallet add -wallet $WALLET -trusted_cert -cert $WALLET/certs/$c.pem -auto_login_only; done
$ORACLE_HOME/bin/orapki wallet display -wallet $WALLET
```

Son las raíces de Google (GTS Root R1 a R4) y sus intermedios (WE2 y WR2), porque Gmail alterna entre dos cadenas de certificados. El wallet es de inicio automático (`cwallet.sso`): solo contiene certificados públicos, así que no lleva contraseña. Su ruta es la del parámetro `CORREO_WALLET` (`file:/opt/oracle/oradata/wallet_sgs`).

![Certificados del wallet](servidores/capturas/i1_preparacion/03_sgspri_wallet_certificados.png)

## Carpeta del padrón

```
mkdir -p /opt/oracle/oradata/padron
```

Los archivos del TSE se suben desde la HP (PowerShell) a las dos VMs:

```
scp "$env:USERPROFILE\Downloads\PADRON_COMPLETO.txt" "$env:USERPROFILE\Downloads\distelec.txt" oracle@192.168.56.101:/opt/oracle/oradata/padron/
scp "$env:USERPROFILE\Downloads\PADRON_COMPLETO.txt" "$env:USERPROFILE\Downloads\distelec.txt" oracle@192.168.56.102:/opt/oracle/oradata/padron/
```

![Archivos del padrón en las dos VMs](servidores/capturas/i1_preparacion/18_padron_en_las_dos_vms.png)

## Revisión de la base

Antes de instalar el esquema se revisan en `SGSPRI` (`sqlplus / as sysdba`) los valores de los que depende el sistema:

| Revisión | Valor esperado |
|---|---|
| `SELECT value FROM nls_database_parameters WHERE parameter = 'NLS_CHARACTERSET';` | `AL32UTF8` |
| `SELECT TO_CHAR(SYSTIMESTAMP, 'TZH:TZM') FROM DUAL;` | `-06:00` |
| `SHOW PARAMETER resource_limit` | `TRUE` (el perfil de contraseñas limita sesiones y tiempo inactivo) |
| `SHOW PARAMETER job_queue_processes` | Mayor que 0 (los jobs pueden correr) |
| `SHOW PARAMETER remote_login_passwordfile` | `EXCLUSIVE` (conexión remota como `SYSDBA`) |
| Espacio libre en la FRA (`v$recovery_file_dest`) | Suficiente para el redo de la carga del padrón (3,7 millones de filas) |

# Instalación del esquema

## Scripts y orden

Los scripts de `bd/` se ejecutan en `SGSPDB` de la principal, en este orden. Varios tienen una **sección 0** que se ejecuta como `SYS` (privilegios sobre paquetes del sistema, la lista de control de red, el directorio del padrón, el perfil y los usuarios) y el resto como `SGS_ADMIN`; la sección 0 termina en la línea `-- 1. A partir de aqui, conectado como SGS_ADMIN`.

| Script | Usuario | Qué crea |
|---|---|---|
| `01_infraestructura.sql` | `SYS` o `SYSTEM` | Tablespaces `SGS_DATA` (máx. 4 GB), `SGS_IDX` (2 GB) y `SGS_AUD` (1 GB), el usuario `SGS_ADMIN` y sus 10 privilegios de sistema |
| `02_modelo.sql` | `SGS_ADMIN` | Las 57 tablas con sus secuencias, restricciones, índices y comentarios; la vista de precio de venta y los catálogos |
| `03_base_interna.sql` | Sección 0: `SYS`; resto: `SGS_ADMIN` | Privilegios sobre `DBMS_CRYPTO`, `UTL_SMTP` y `UTL_TCP`, y la lista de control de red; packages de errores, parámetros, cifrado y correo; parámetros, destinatarios y la clave del correo cifrada |
| `04_reglas_negocio.sql` | `SGS_ADMIN` | Triggers de cuentas, inventario, historial de precios y validaciones; packages de clientes, crédito, compras, inventario y ventas |
| `05_bitacoras.sql` | `SGS_ADMIN` | Package de bitácora, 33 triggers de auditoría y las vistas de la bitácora |
| `06_padron.sql` | Sección 0: `SYS`; resto: `SGS_ADMIN` | Directorio del padrón; tablas externas, package de carga y la carga inicial (unos minutos) |
| `07_procesos.sql` | `SGS_ADMIN` | Package de procesos y notificaciones y sus 9 jobs |
| `08_seguridad.sql` | Sección 0: `SYS`; resto: `SGS_ADMIN` | Perfil de contraseñas y usuarios por rol; roles con clave cifrada, packages de seguridad y privilegios de cada rol |
| `09_monitoreo.sql` | Sección 0: `SYS`; resto: `SGS_ADMIN` | Lectura de las vistas del sistema; package de monitoreo, vistas materializadas, 6 jobs, estadísticas y planes de ejecución |
| `10_datos_operaciones.sql` | `SGS_ADMIN` | Datos de prueba de las operaciones, hechos con los packages |
| `11_standby.sql` | `SYS` dentro de `SGSPDB` (o `SGS_ADMIN`) | Credencial del usuario `oracle` de Linux, package de administración del standby y los 4 jobs del respaldo y del standby |

`00_reinicio_desarrollo.sql` borra el esquema y solo se usa en el ambiente de desarrollo: **no se ejecuta en los servidores**. En la standby no se ejecuta ningún script: todo llega por el redo.

## Valores que se reemplazan

Los scripts del repositorio no tienen claves. Antes de ejecutarlos se reemplazan estos valores en una copia (la copia con claves nunca se sube al repositorio):

| Script | Valor | En los servidores |
|---|---|---|
| `01` | `<CLAVE_SGS_ADMIN>` | Clave de `SGS_ADMIN` |
| `03` | `<LLAVE_CIFRADO>` | Llave nueva de 64 caracteres hexadecimales, por ejemplo con `openssl rand -hex 32` |
| `03` | `<CLAVE_CORREO>` | Contraseña de aplicación de Gmail |
| `06` | `<RUTA_PADRON>` | `/opt/oracle/oradata/padron` |
| `08` | `<CLAVE_USUARIO_GERENTE>`, `<CLAVE_USUARIO_JEFE_DEPTO>`, `<CLAVE_USUARIO_JEFE_PROVEEDURIA>`, `<CLAVE_USUARIO_DIGITADOR>` | Claves de los usuarios por rol |
| `08` | `<CLAVE_ROL_GERENTE>`, `<CLAVE_ROL_JEFE_DEPTO>`, `<CLAVE_ROL_JEFE_PROVEEDURIA>`, `<CLAVE_ROL_DIGITADOR>` | Claves de los roles |

El wallet (`CORREO_WALLET`) y el puerto (`CORREO_PUERTO`) ya vienen con los valores de los servidores.

## Ejecución

Los scripts se ejecutan con SQL*Plus con `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`: sin esa variable, SQL*Plus lee el archivo con otro juego de caracteres y las tildes y eñes de los textos de los correos quedan dañadas dentro de los packages. Cada parte se ejecuta con este encabezado, que detiene la ejecución ante el primer error y evita que SQL*Plus interprete los `&` y las líneas en blanco de los bloques PL/SQL:

```
WHENEVER SQLERROR EXIT FAILURE
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
```

Conexiones (por Tailscale, desde el equipo cliente; el servicio `sgspdb` entra directo a la PDB):

```
sqlplus -s -L 'sys/"<CLAVE_SYS>"@//100.76.209.30:1521/sgspdb as sysdba' < parte.sql
sqlplus -s -L "SGS_ADMIN/<CLAVE_SGS_ADMIN>@//100.76.209.30:1521/sgspdb" < parte.sql
```

La sección 0 de un script se separa del resto por la línea que la cierra; por ejemplo, para `03_base_interna.sql`:

```
# Sección 0, como SYS
awk '/^-- 1\. A partir de aqui/{exit} {print}' 03_base_interna.sql > 03a_sys.sql
# Resto, como SGS_ADMIN
awk '/^-- 1\. A partir de aqui/{f=1} f' 03_base_interna.sql > 03b_admin.sql
```

En el proyecto la instalación se automatizó con un script de terminal que hace exactamente esto: reemplaza los valores en copias de los scripts, separa cada sección, ejecuta cada parte con su usuario, revisa después de cada parte de `SGS_ADMIN` que no haya objetos con errores de compilación (`USER_ERRORS`) y se detiene en el primer error. Antes de empezar comprueba que la base sea `SGSPRI` en rol `PRIMARY` y que el esquema todavía no exista, para no ejecutarlo por error contra la standby o dos veces. La instalación de los scripts `01` a `10` tardó 4 minutos, incluida la carga del padrón.

![Instalación del esquema en SGSPRI](docs/evidencias/capturas/I1_01_instalacion_sgspri.png)

## Jobs del servidor (`11_standby.sql`)

El script `11_standby.sql` se ejecuta en `SGSPRI` después de los demás, porque necesita los parámetros del `03` y los scripts de los servidores ya instalados. Pide la clave del usuario `oracle` de Linux sin mostrarla, para crear la credencial con la que los jobs ejecutan los scripts:

```
sqlplus / as sysdba
ALTER SESSION SET CONTAINER = SGSPDB;
@11_standby.sql
```

| Job | Qué ejecuta | Programación |
|---|---|---|
| `SGS_JOB_RESPALDO_DIARIO` | `respaldo_rman.sh` | Diario, a la hora de `RESP_HORA_DIARIO` (1:00 a. m.) |
| `SGS_JOB_STB_ARCHIVO` | `SGS_PKG_STANDBY.aplicar_archivo` | Diario, 00:10 |
| `SGS_JOB_STB_TRASLADO` | `SGS_PKG_STANDBY.trasladar` | Cada `STB_MINUTOS_TRASLADO` minutos (10) |
| `SGS_JOB_STB_BORRADO` | `SGS_PKG_STANDBY.borrar_archivos` | Diario, 00:20 |

![Credencial y jobs creados por 11_standby.sql](servidores/capturas/s5_rman/32_11_standby_verificacion.png)

## Verificación en la principal

Conectado como `SGS_ADMIN` a `SGSPRI`, esta consulta revisa la instalación completa. Cada fila debe decir `OK`; los 15 jobs son los de los scripts `07` y `09` (con `11_standby.sql` instalado son 19):

```
SELECT 'Tablas del modelo' AS revision, TO_CHAR(COUNT(*)) AS valor, CASE WHEN COUNT(*) = 57 THEN 'OK' ELSE 'FALLA' END AS resultado
  FROM USER_TABLES t
 WHERE t.EXTERNAL = 'NO' AND NOT EXISTS (SELECT 1 FROM USER_MVIEWS m WHERE m.MVIEW_NAME = t.TABLE_NAME)
UNION ALL
SELECT 'Tablas con 5 filas o mas', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) = 57 THEN 'OK' ELSE 'FALLA' END
  FROM (SELECT /*+ NO_MERGE */ TO_NUMBER(EXTRACTVALUE(XMLTYPE(DBMS_XMLGEN.GETXML('SELECT COUNT(*) AS C FROM ' || t.TABLE_NAME)), '/ROWSET/ROW/C')) AS filas
          FROM USER_TABLES t
         WHERE t.EXTERNAL = 'NO' AND ROWNUM > 0
           AND NOT EXISTS (SELECT 1 FROM USER_MVIEWS m WHERE m.MVIEW_NAME = t.TABLE_NAME))
 WHERE filas >= 5
UNION ALL
SELECT 'Packages (especificacion y cuerpo) validos', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) = 32 THEN 'OK' ELSE 'FALLA' END
  FROM USER_OBJECTS WHERE OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY') AND STATUS = 'VALID'
UNION ALL
SELECT 'Triggers habilitados', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) = 50 THEN 'OK' ELSE 'FALLA' END
  FROM USER_TRIGGERS WHERE STATUS = 'ENABLED'
UNION ALL
SELECT 'Vistas y vistas materializadas', TO_CHAR((SELECT COUNT(*) FROM USER_VIEWS)) || ' y ' || TO_CHAR((SELECT COUNT(*) FROM USER_MVIEWS)),
       CASE WHEN (SELECT COUNT(*) FROM USER_VIEWS) = 4 AND (SELECT COUNT(*) FROM USER_MVIEWS) = 2 THEN 'OK' ELSE 'FALLA' END
  FROM DUAL
UNION ALL
SELECT 'Objetos invalidos o con errores', TO_CHAR((SELECT COUNT(*) FROM USER_OBJECTS WHERE STATUS = 'INVALID' AND OBJECT_TYPE <> 'MATERIALIZED VIEW') + (SELECT COUNT(*) FROM USER_ERRORS)),
       CASE WHEN (SELECT COUNT(*) FROM USER_OBJECTS WHERE STATUS = 'INVALID' AND OBJECT_TYPE <> 'MATERIALIZED VIEW') + (SELECT COUNT(*) FROM USER_ERRORS) = 0 THEN 'OK' ELSE 'FALLA' END
  FROM DUAL
UNION ALL
SELECT 'Jobs programados y habilitados', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) = 15 THEN 'OK' ELSE 'FALLA' END
  FROM USER_SCHEDULER_JOBS WHERE ENABLED = 'TRUE'
UNION ALL
SELECT 'Personas del padron', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) >= 3762240 THEN 'OK' ELSE 'FALLA' END
  FROM SGS_PADRON
UNION ALL
SELECT 'Parametros cifrados (correo y 4 roles)', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) = 5 THEN 'OK' ELSE 'FALLA' END
  FROM SGS_PARAMETRO WHERE PAR_ES_CIFRADO = 'S'
UNION ALL
SELECT 'Premiaciones y cierres diarios', TO_CHAR((SELECT COUNT(*) FROM SGS_PREMIACION)) || ' y ' || TO_CHAR((SELECT COUNT(*) FROM SGS_CIERRE_DIARIO)),
       CASE WHEN (SELECT COUNT(*) FROM SGS_PREMIACION) >= 5 AND (SELECT COUNT(*) FROM SGS_CIERRE_DIARIO) >= 5 THEN 'OK' ELSE 'FALLA' END
  FROM DUAL
UNION ALL
SELECT 'Rechazos esperados en la bitacora de errores', TO_CHAR(COUNT(*)), CASE WHEN COUNT(*) >= 6 THEN 'OK' ELSE 'FALLA' END
  FROM SGS_BITACORA_ERROR
UNION ALL
SELECT 'Hora de la base (Costa Rica)', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI TZH:TZM'), CASE WHEN TO_CHAR(SYSTIMESTAMP, 'TZH:TZM') = '-06:00' THEN 'OK' ELSE 'FALLA' END
  FROM DUAL
```

Las vistas materializadas pueden aparecer como `INVALID` en `USER_OBJECTS` cuando sus tablas cambiaron después del último refresco: solo significa que están desactualizadas, y el job de las 00:30 las refresca. Un error real se ve en `USER_MVIEWS.COMPILE_STATE = 'COMPILATION_ERROR'`.

![Verificación general en SGSPRI](docs/evidencias/capturas/I1_02_verificacion_general.png)

## Verificación en la standby

Conectado como `SYS` a `SGSSTB`, el esquema y los datos deben ser los mismos que en la principal, y los datafiles de los tablespaces del sistema deben haberse creado solos en las rutas de la standby:

```
-- SGSSTB  PHYSICAL STANDBY  READ ONLY WITH APPLY
SELECT d.db_unique_name, d.database_role, d.open_mode FROM v$database d;
-- 61: las 57 del modelo, 2 externas y 2 de las vistas materializadas
SELECT COUNT(*) FROM DBA_TABLES WHERE OWNER = 'SGS_ADMIN';
-- El mismo total que en SGSPRI
SELECT COUNT(*) FROM SGS_ADMIN.SGS_PADRON;
-- /opt/oracle/oradata/SGSSTB/SGSPDB/sgs_*.dbf
SELECT file_name FROM DBA_DATA_FILES WHERE TABLESPACE_NAME LIKE 'SGS%';
```

Y en el broker, después de la carga del padrón, la standby debe estar al día:

![La standby al día después de la instalación](docs/evidencias/capturas/I1_04_broker_tras_instalacion.jpeg)

# Verificación del despliegue

## Correo desde el servidor

Como `SGS_ADMIN` en la principal:

```
BEGIN
    SGS_PKG_CORREO.enviar_a_tipo('DBA', 'Prueba SGS: correo enviado desde SGSPRI',
        'Hola, este correo lo envió Oracle 21c desde el servidor principal SGSPRI, directo por SMTP sobre TLS, sin VPN.');
END;
```

El correo llega a todos los destinatarios del tipo `DBA` de la tabla `SGS_DESTINATARIO`.

![Correo enviado desde SGSPRI](docs/evidencias/capturas/I3_01_correo_desde_sgspri.png)

## Jobs

```
SELECT job_name, state, TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI TZR') AS proxima_ejecucion, run_count, failure_count
  FROM user_scheduler_jobs
 ORDER BY next_run_date
```

Todos deben estar en `SCHEDULED`, con su próxima ejecución en hora `AMERICA/COSTA_RICA`. Cualquier job se puede ejecutar a demanda con `DBMS_SCHEDULER.RUN_JOB('<nombre>', use_current_session => FALSE)` y revisar su resultado en `USER_SCHEDULER_JOB_RUN_DETAILS`.

![Jobs programados en SGSPRI](docs/evidencias/capturas/I4_04_jobs_sgspri.png)

## Cambio de roles

Para confirmar que el despliegue sobrevive a un cambio de servidor, se hace un switchover a `SGSSTB` y de regreso (`dgmgrl sys@SGSPRI`: `SWITCHOVER TO 'SGSSTB';` y luego `SWITCHOVER TO 'SGSPRI';`). Con `SGSSTB` como principal se comprobó que los jobs, el correo, las operaciones del sistema, el respaldo y la carga del padrón funcionan sin cambiar nada, y que los datos escritos allí llegan a `SGSPRI`. El procedimiento completo está en el manual de administración del standby.

![Configuración con SGSSTB como principal](docs/evidencias/capturas/I4_09_configuracion_sgsstb_primary.jpeg)

## Lista de comprobación

| Comprobación | Dónde |
|---|---|
| Las dos VMs con la hora de Costa Rica sincronizada | `timedatectl` y `chronyc tracking` |
| Broker en `SUCCESS`, lag de transporte y de aplicación en 0 | `dgmgrl`: `SHOW CONFIGURATION;` y `SHOW DATABASE 'SGSSTB';` |
| Respaldo a demanda copiado al otro servidor | `respaldo_rman.sh` o `RUN_JOB('SGS_JOB_RESPALDO_DIARIO')` |
| Wallet y padrón en las dos VMs | `orapki wallet display` y `ls /opt/oracle/oradata/padron` |
| Verificación general del esquema en `OK` | Consulta de la sección anterior |
| Esquema replicado en la standby | Consultas en `SGSSTB` |
| Correo recibido desde la principal | `SGS_PKG_CORREO.enviar_a_tipo` |
| Jobs programados y sin fallos | `USER_SCHEDULER_JOBS` |
| Conexiones de DBeaver a las dos bases | Conexiones por Tailscale |

# Solución de los requerimientos

Esta tabla resume qué parte del sistema resuelve cada requerimiento del enunciado. El detalle de los packages, triggers y jobs está en el manual técnico de administración y mantenimiento, y el de los servidores en el manual de administración del standby.

| Requerimiento | Solución | Detalle |
|---|---|---|
| Cuentas por cobrar y por pagar automáticas | Triggers sobre las facturas, sus pagos y las notas de crédito mantienen el saldo de cada factura y el total de la cuenta | Manual técnico |
| Cambio automático del estado de la factura | El trigger del saldo pasa la factura a cancelada cuando su saldo llega a 0 | Manual técnico |
| Padrón nacional | Tablas externas sobre los archivos del TSE y `SGS_PKG_PADRON.cargar` (`MERGE` que nunca borra); el cliente nacional toma sus datos del padrón | Manual técnico |
| Inventario automático en compras, ventas y devoluciones | Lotes por línea de compra, existencias por lote y sucursal, movimientos con su documento y ventas por FEFO | Manual técnico |
| Historial automático de precios | Trigger sobre el costo del producto | Manual técnico |
| Límites de crédito al facturar | `CHECK` del saldo contra el límite en la cuenta, con la fila bloqueada `FOR UPDATE` | Manual técnico |
| Productos por vencer y con más de 6 meses (semanal) | `SGS_PKG_PROCESOS.reportar_inventario`, job semanal | Manual técnico |
| Promociones y acciones | Tipos de promoción y acciones calculadas al facturar | Manual técnico |
| Descuentos planeados (semanal) | `SGS_PKG_PROCESOS.incluir_descuentos`, job semanal | Manual técnico |
| Premiación de los 10 mejores clientes | `SGS_PKG_PROCESOS.premiar_clientes`, cada `PREMIO_FRECUENCIA_MESES` meses | Manual técnico |
| Bitácoras de las 7 áreas | `SGS_PKG_BITACORA` y 33 triggers de auditoría | Manual técnico |
| Notificaciones parametrizadas y clave cifrada | `SGS_PARAMETRO`, `SGS_DESTINATARIO` y `SGS_PKG_CIFRADO` (AES-256 con `DBMS_CRYPTO`) | Manual técnico |
| Correo directo desde Oracle, sin VPN | `SGS_PKG_CORREO` (`UTL_SMTP` con TLS), wallet y lista de control de red; Tailscale sin exit node | Este manual |
| Perfiles, roles y usuarios | Perfil `SGS_PERFIL_USUARIO`, usuarios por rol y roles `SGS_ROL_*` con privilegios mínimos | Manual técnico |
| Roles con clave cifrada | Claves en `SGS_PARAMETRO` cifradas y procedimientos que las asignan y activan | Manual técnico |
| Notificaciones del 85 %, 70 %, morosos y vencidos | `SGS_PKG_PROCESOS`, jobs diarios | Manual técnico |
| Cierre diario | `SGS_PKG_PROCESOS.cerrar_dia`, job diario | Manual técnico |
| Tablespaces, objetos inválidos e índices | `SGS_PKG_MONITOREO`, jobs diarios | Manual técnico |
| Dos servidores, principal y standby, Oracle 21c en Linux | `SGSPRI` y `SGSSTB` con Oracle Linux 8.10 y Oracle 21c EE | Este manual |
| Archivo cada 5 minutos o 50 MB | `ArchiveLagTarget` y redo logs de 50 MB, parametrizados | Manual del standby |
| Traslado cada 10 minutos y a demanda | `SGS_JOB_STB_TRASLADO` | Manual del standby |
| Borrado a los 3 días en los dos servidores | `SGS_JOB_STB_BORRADO` con RMAN | Manual del standby |
| Respaldo diario copiado a la standby y a demanda | `SGS_JOB_RESPALDO_DIARIO` | Manual del standby |
| Failover, switchover, recuperación y sincronización | Broker de Data Guard y RMAN | Manual del standby |
| Arquitectura en packages, transacciones, excepciones y concurrencia | 17 packages con `SAVEPOINT`, manejo de excepciones con `SGS_PKG_ERRORES` y `FOR UPDATE NOWAIT/WAIT` | Manual técnico |
| Todos los procesos con `DBMS_SCHEDULER` | 19 jobs | Manual técnico |
| Vistas materializadas y `EXPLAIN PLAN` | Ventas mensuales e inventario consolidado; análisis de planes | Manual técnico |

# Anexos

## A. Encendido y apagado de los servidores

Las bases no arrancan solas al encender las VMs. Como el rol de cada servidor puede cambiar después de un switchover, primero se monta cada base y se revisa su rol.

**Encender** (en cada servidor, como `oracle`):

```
lsnrctl start
sqlplus / as sysdba
STARTUP MOUNT;
SELECT db_unique_name, database_role FROM v$database;
```

En el que diga `PRIMARY` (normalmente `SGSPRI`), primero:

```
ALTER DATABASE OPEN;
```

En el que diga `PHYSICAL STANDBY` (normalmente `SGSSTB`):

```
ALTER DATABASE OPEN READ ONLY;
ALTER PLUGGABLE DATABASE SGSPDB OPEN READ ONLY;
```

El broker arranca solo la aplicación de cambios (puede tardar hasta un minuto en pasar a `READ ONLY WITH APPLY`). Al final, `dgmgrl sys@SGSPRI` → `SHOW CONFIGURATION;` debe decir `SUCCESS`.

**Apagar**: primero la standby y después la principal (`SHUTDOWN IMMEDIATE;` en cada una) y luego cada VM (`shutdown -h now` como `root`). Antes de suspender o apagar la HP se apagan siempre las VMs.

## B. Parámetros del sistema

| Parámetro | Valor inicial | Uso |
|---|---|---|
| `CORREO_REMITENTE` | `sgs.notificaciones.una@gmail.com` | Cuenta que envía las notificaciones |
| `CORREO_CLAVE` | Cifrado | Contraseña de aplicación de Gmail |
| `CORREO_SERVIDOR` | `smtp.gmail.com` | Servidor SMTP |
| `CORREO_PUERTO` | `465` | 465 = TLS desde el inicio, 587 = STARTTLS |
| `CORREO_WALLET` | `file:/opt/oracle/oradata/wallet_sgs` | Wallet con los certificados de Google |
| `PCT_AVISO_CLIENTE` | `0.85` | Uso del crédito a partir del cual se avisa al cliente |
| `PCT_AVISO_COORDINADOR` | `0.85` | Uso del crédito para la lista del coordinador |
| `PCT_AVISO_GERENTE_CXP` | `0.70` | Uso del crédito con proveedores para avisar al gerente |
| `DIAS_MOROSIDAD` | `30` | Días sin pagar para considerar moroso a un cliente |
| `DIAS_PROXIMO_VENCER` | `7` | Días antes del vencimiento para reportar un producto |
| `MESES_ANTIGUEDAD_BODEGA` | `6` | Meses en bodega para reportar un producto como antiguo |
| `PREMIO_CANTIDAD_CLIENTES` | `10` | Cantidad de mejores clientes que se premian |
| `PREMIO_MONTO_ORDEN` | `100000` | Monto de la orden de compra de cada premiado |
| `PREMIO_FRECUENCIA_MESES` | `6` | Cada cuántos meses se ejecuta la premiación |
| `PCT_MAX_TABLESPACE` | `0.85` | Uso máximo de un tablespace antes de notificar |
| `MINUTOS_SESION_BLOQUEADA` | `5` | Minutos de espera de una sesión bloqueada antes de avisar al DBA |
| `STB_MINUTOS_ARCHIVO` | `5` | Minutos máximos entre archivos de actualización |
| `STB_MB_ARCHIVO` | `50` | Tamaño en MB de un archivo de actualización |
| `STB_MINUTOS_TRASLADO` | `10` | Minutos entre traslados a la standby |
| `STB_DIAS_BORRADO` | `3` | Días tras los cuales se borran los archivos trasladados y aplicados |
| `RESP_HORA_DIARIO` | `1` | Hora del respaldo diario (hora de Costa Rica) |
| `CLAVE_ROL_GERENTE`, `CLAVE_ROL_JEFE_DEPTO`, `CLAVE_ROL_JEFE_PROVEEDURIA`, `CLAVE_ROL_DIGITADOR` | Cifrados | Claves de los roles |

Los porcentajes se guardan como fracción (`0.85` = 85 %). Los parámetros no cifrados se cambian con `SGS_PKG_PARAMETROS.actualizar('<CODIGO>', '<valor>')` y los cifrados con `SGS_PKG_CIFRADO.guardar_parametro`.

## C. Ambiente de desarrollo

Los scripts se desarrollaron y probaron primero en un contenedor Docker con Oracle Database Free en el Mac (PDB `FREEPDB1`), con DBeaver como cliente. En ese ambiente sí se usa `00_reinicio_desarrollo.sql` para reinstalar todo desde cero con los scripts `00` a `10`. Los scripts están escritos para Oracle 21c y no usan nada exclusivo de las versiones más nuevas, por eso corrieron en los servidores sin cambios.
