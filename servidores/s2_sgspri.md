# S2 — Oracle 21c en SGSPRI

Pasos confirmados para preparar `SGSPRI` e instalar Oracle Database 21c. Las capturas están en [`capturas/s2_sgspri/`](capturas/s2_sgspri/).

Estado: **Linux preparado para Oracle (preinstall, usuario `oracle`, kernel, hosts, SELinux, firewall y directorios).** Falta: software de Oracle y base de datos.

Todos los comandos se ejecutan como `root` por SSH desde la HP (`ssh root@192.168.56.101`).

---

## 1. Paquete de preparación de Oracle

```
dnf install -y oracle-database-preinstall-21c
dnf install -y unzip wget nano
```

El paquete `oracle-database-preinstall-21c` crea el usuario `oracle`, los grupos y los ajustes del kernel y de límites que pide Oracle.

> Si la instalación se interrumpe (por ejemplo, si la VM se congela), ejecutar `dnf reinstall -y oracle-database-preinstall-21c` para que vuelva a aplicar su configuración completa.

## 2. Verificación

```
id oracle
# uid=54321(oracle) gid=54321(oinstall) groups=54321(oinstall),54322(dba),54323(oper),
#   54324(backupdba),54325(dgdba),54326(kmdba),54330(racdba)

sysctl kernel.shmmax fs.file-max
# kernel.shmmax = 4398046511104
# fs.file-max = 6815744

passwd oracle   # contraseña definida (no se guarda en el repo)
```

## 3. Nombres de los servidores (`/etc/hosts`)

Data Guard se comunica por nombre de servidor.

```
cat >> /etc/hosts <<EOF
192.168.56.101  sgspri.localdomain  sgspri
192.168.56.102  sgsstb.localdomain  sgsstb
EOF
```

## 4. SELinux permisivo

Evita bloqueos de SELinux sobre Oracle y Data Guard en el laboratorio.

```
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0
getenforce          # Permissive
```

## 5. Firewall: puerto del listener

Puerto 1521 abierto para DBeaver (Mac de Isaac) y para la standby.

```
firewall-cmd --permanent --add-port=1521/tcp
firewall-cmd --reload
firewall-cmd --list-ports   # 1521/tcp
```

## 6. Directorios de Oracle

| Ruta | Uso |
|---|---|
| `/u01/app/oracle` | `ORACLE_BASE` |
| `/u01/app/oracle/product/21.0.0/dbhome_1` | `ORACLE_HOME` |
| `/u01/app/oraInventory` | Inventario de Oracle |

```
mkdir -p /u01/app/oracle/product/21.0.0/dbhome_1 /u01/app/oraInventory
chown -R oracle:oinstall /u01
chmod -R 775 /u01
```
