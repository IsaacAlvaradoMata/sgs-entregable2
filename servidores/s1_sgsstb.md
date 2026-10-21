# S1 — VM SGSSTB (servidor standby)

`SGSSTB` se creó **clonando `SGSPRI`** cuando esta ya tenía Linux, la preparación para Oracle, el software de Oracle 21c y el listener, pero **todavía sin base de datos** (como pide S2: la standby queda solo con el software). Así las dos quedan con las mismas rutas y paquetes. Capturas en [`capturas/s1_sgsstb/`](capturas/s1_sgsstb/).

Estado: **`SGSSTB` con identidad propia (nombre, IP, SID y listener).**

---

## 1. Clonar

Con `SGSPRI` **apagada** (`shutdown -h now`), en VirtualBox: clic derecho sobre `SGSPRI` → **Clonar**.

| Opción | Valor |
|---|---|
| Nombre | `SGSSTB` |
| Ruta | `C:\Users\USUARIO UNA PZ\VirtualBox VMs` |
| Clone Type | **Clonación completa** (disco independiente `SGSSTB.vdi`) |
| Política de dirección MAC | **Generar nuevas direcciones MAC para todos los adaptadores de red** |
| Mantener nombres de disco / UUIDs | Desmarcadas |

## 2. Darle identidad propia

**Con `SGSPRI` apagada** (al inicio las dos tienen la IP `.101`), encender solo `SGSSTB` y entrar con `ssh root@192.168.56.101`:

```
hostnamectl set-hostname sgsstb.localdomain
sed -i 's/ORACLE_SID=SGSPRI/ORACLE_SID=SGSSTB/' /home/oracle/.bash_profile
sed -i 's/sgspri.localdomain/sgsstb.localdomain/' /opt/oracle/homes/OraDBHome21cEE/network/admin/listener.ora

# Último, porque corta el SSH:
nmcli con mod enp0s8 ipv4.addresses 192.168.56.102/24 && nmcli con up enp0s8
```

Reconectar con `ssh root@192.168.56.102`. SSH avisa que la huella ya la conoce de `192.168.56.101`: es normal por ser un clon, se responde `yes`.

## 3. Verificación

```
hostname                                   # sgsstb.localdomain
ip addr show enp0s8                        # inet 192.168.56.102/24 (MAC distinta a SGSPRI)
grep ORACLE_SID /home/oracle/.bash_profile # export ORACLE_SID=SGSSTB
cat /opt/oracle/homes/OraDBHome21cEE/network/admin/listener.ora   # HOST = sgsstb.localdomain
```
