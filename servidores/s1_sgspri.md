# S1 — VM SGSPRI (servidor principal)

Pasos confirmados para crear la VM del servidor principal. Cada paso se probó y funcionó; las capturas están en [`capturas/s1_sgspri/`](capturas/s1_sgspri/). Sirve de base para el manual de instalación.

Estado: **Linux instalado, red e internet funcionando, acceso por SSH desde la HP.** Falta: preparar Linux para Oracle e instalar Oracle 21c (S2).

---

## 1. Equipo anfitrión (HP)

| Elemento | Valor |
|---|---|
| Modelo | HP ProBook 445 G10 |
| Procesador | AMD Ryzen 5 7530U (6 núcleos / 12 hilos) |
| RAM | 16 GB |
| Disco | 475 GB (271 GB libres al iniciar) |
| Sistema | Windows 11 Pro |

## 2. Preparar Windows para VirtualBox

Windows usa la virtualización para su propia seguridad, lo que hace más lentas las VMs de VirtualBox.

1. Seguridad de Windows → Seguridad del dispositivo → Aislamiento del núcleo → **Integridad de memoria: Desactivado**.
2. Características de Windows → desmarcar **Plataforma de máquina virtual** (Hyper-V, Plataforma del hipervisor y Espacio aislado ya estaban desmarcados).
3. En `cmd` como administrador:
   ```
   bcdedit /set hypervisorlaunchtype off
   ```
   Verificar con `bcdedit /enum {current}` → debe aparecer `hypervisorlaunchtype Off`.
4. Reiniciar.
5. Si `msinfo32` sigue indicando "Se detectó un hipervisor" o "Seguridad basada en virtualización: En ejecución", apagar la seguridad basada en virtualización (VBS) desde `cmd` como administrador y reiniciar:
   ```
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LsaCfgFlags /t REG_DWORD /d 0 /f
   ```
6. Verificar en `msinfo32`: "Seguridad basada en virtualización: **No habilitado**" y las cuatro líneas "Hyper-V - …" en **Sí**.

> **Por qué es obligatorio:** con el hipervisor de Windows activo, VirtualBox corre sobre él y la VM se traba (`kernel:watchdog: BUG: soft lockup - CPU#0 stuck`), corta el SSH y llega a congelarse durante cargas pesadas como `dnf install`. Pasó en esta instalación y se resolvió con el paso 5.

## 3. VirtualBox

1. Descargar VirtualBox 7.2 para Windows desde https://www.virtualbox.org/wiki/Downloads (*Windows hosts*). El Extension Pack no se necesita.
2. Instalar con las opciones por defecto y elegir **Expert Mode** al abrirlo.
3. Red solo-anfitrión (Archivo → Herramientas → Network Manager → Redes solo-anfitrión):
   - Adaptador `VirtualBox Host-Only Ethernet Adapter`, configurado manualmente: `192.168.56.1` / `255.255.255.0`.
   - **Servidor DHCP deshabilitado** (las VMs usan IP fija).

## 4. Crear la VM

ISO: `OracleLinux-R8-U10-x86_64-dvd.iso` (Oracle Linux 8.10, ISO completa) desde https://yum.oracle.com/oracle-linux-isos.html. Se usa la 8 porque es la certificada para Oracle 21c.

| Opción | Valor |
|---|---|
| Nombre | `SGSPRI` |
| Tipo / versión | Linux / Oracle Linux 8.x (64-bit) |
| Instalación desatendida | **Desmarcada** |
| Memoria | 5120 MB |
| CPU | 2 |
| EFI | Desmarcado |
| Disco | 80 GB, **VDI**, dinámico (sin reservar completo) |
| Adaptador 1 | NAT (internet) |
| Adaptador 2 | Adaptador solo-anfitrión (`VirtualBox Host-Only Ethernet Adapter`) |
| Orden de arranque | Óptica, Disco duro (sin disquete) |
| Audio | Deshabilitado |

## 5. Instalar Oracle Linux 8.10

En el menú de arranque: **Install Oracle Linux 8.10.0**. Idioma del instalador: English (United States).

| Sección | Valor |
|---|---|
| Keyboard | Spanish; Castilian (Latin American) primero, English (US) segundo |
| Time & Date | Americas / Costa Rica |
| Software Selection | **Server** (sin interfaz gráfica, para ahorrar RAM) |
| Installation Destination | Custom: `/boot` 1 GiB, `swap` 5 GiB, `/` 74 GiB (se eliminó `/home`) |
| KDUMP | Deshabilitado |
| Host Name | `sgspri.localdomain` |
| enp0s3 | NAT, DHCP (`10.0.2.15`) |
| enp0s8 | Manual `192.168.56.101/24`, sin gateway |
| Root Password | Definida (no se guarda en el repo) |
| User Creation | Ninguno (el usuario `oracle` se crea después) |

Al terminar se quitó la ISO (Dispositivos → Unidades ópticas) y se reinició. Si la pantalla queda en `[terminated]`, reiniciar con Máquina → Reiniciar.

## 6. Verificación y corrección de la red

Primer inicio como `root`:

```
hostname          # sgspri.localdomain
ip addr           # enp0s3 con 10.0.2.15
ping -c 3 google.com
```

**Problema encontrado:** `enp0s8` quedó sin IP (la conexión no estaba activa aunque el instalador la mostraba). Solución:

```
nmcli con mod enp0s8 ipv4.method manual ipv4.addresses 192.168.56.101/24 connection.autoconnect yes
nmcli con up enp0s8
ip addr show enp0s8   # inet 192.168.56.101/24
nmcli con show        # enp0s3 y enp0s8 activas
```

## 7. Acceso por SSH desde la HP

En PowerShell de Windows:

```
ssh root@192.168.56.101
```

La primera vez se acepta la huella con `yes`. Oracle Linux 8 permite el acceso de root por SSH por defecto.

## 8. Sincronización de la hora (en SGSPRI y SGSSTB)

La zona horaria (`America/Costa_Rica`, CST -0600) quedó desde la instalación, pero la sincronización automática venía apagada (`NTP service: inactive`). Los jobs programados y Data Guard necesitan la misma hora exacta en los dos servidores. Como `root`, en cada uno:

```
systemctl enable --now chronyd
timedatectl
# Time zone: America/Costa_Rica (CST, -0600)
# System clock synchronized: yes
# NTP service: active
```

**Corrección de golpe (2026-10-29).** Al suspender la HP con las VMs encendidas, los relojes quedaron atrasados unos 54 minutos (`chronyc tracking`: `3242 seconds slow` en `SGSPRI`, `3190` en `SGSSTB`), y por defecto chronyd corrige grandes desfases muy despacio. Los jobs corren según esa hora, así que se corrigió de golpe y se configuró para que lo haga solo siempre que el desfase pase de 1 segundo. Como `root`, en cada VM:

```
chronyc makestep                                              # 200 OK; System time 0.000000000
sed -i 's/^makestep .*/makestep 1 -1/' /etc/chrony.conf
grep makestep /etc/chrony.conf                                # makestep 1 -1
systemctl restart chronyd
timedatectl                                                   # hora real; System clock synchronized: yes (tarda ~1 min)
chronyc tracking                                              # System time en fracciones de segundo
```

Capturas en [`capturas/operacion/`](capturas/operacion/) (08 a 15). Antes de suspender o apagar la HP se apagan las VMs con la rutina de [`operacion_diaria.md`](operacion_diaria.md).
