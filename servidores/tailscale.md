# Tailscale en SGSPRI y SGSSTB

Para que el Mac de Isaac llegue a las VMs (la red `192.168.56.x` solo existe dentro de la HP). Las dos VMs se unieron a la **red de Tailscale de Isaac** con una llave de autorización que él generó.

> No se guardan capturas en el repo porque muestran la llave y el correo personal de Isaac.

## Instalación (en cada VM, como `root`)

```
curl -fsSL https://tailscale.com/install.sh | sh     # instala y activa el servicio tailscaled
tailscale up --authkey <LLAVE> --hostname sgspri      # en SGSSTB: --hostname sgsstb
tailscale ip -4
history -c                                            # borra la llave del historial
```

- La llave se genera en https://login.tailscale.com/admin/settings/keys (**Reusable**, para las dos VMs) y se pasa por privado. No va en el repo.
- Cuando las dos VMs están conectadas, Isaac la **revoca** (las VMs siguen conectadas).

## Resultado

| Equipo | Hostname Tailscale | IP Tailscale |
|---|---|---|
| `SGSPRI` | `sgspri` | `100.76.209.30` |
| `SGSSTB` | `sgsstb` | `100.69.133.78` |
| Mac de Isaac | `macbook-pro` | `100.84.178.31` |

## Sin exit node: el correo sale directo

El enunciado exige que el correo salga directo desde Oracle, sin VPN. Tailscale solo enruta el tráfico hacia IPs `100.x` de la red; el resto sale por el adaptador NAT:

```
tailscale status        # no aparece ningún "exit node"
ip route get 8.8.8.8    # 8.8.8.8 via 10.0.2.2 dev enp0s3   ← internet directo, no tailscale0
```

Data Guard tampoco usa Tailscale: la sincronización va por la red interna `192.168.56.x`.

## Oracle por Tailscale

No hace falta tocar el `listener.ora`: como su `HOST` es el nombre del propio servidor (`sgspri.localdomain`), el listener escucha en **todas** las tarjetas de red, incluida la de Tailscale (`ss -ltn | grep 1521` → `*:1521`).

> Agregar una segunda dirección con la IP `100.x` hace fallar el listener con `TNS-12542: address already in use`, porque ese puerto ya está ocupado por la primera dirección.

Para que el servicio `sgspdb` aparezca (`status READY`) la base debe registrarse en el listener; ver la corrección de `local_listener` en [`s3_dataguard.md`](s3_dataguard.md) (sección 11).

**Prueba de conexión por Tailscale** (desde `SGSSTB`, simulando el Mac de Isaac):

```
tnsping 100.76.209.30:1521/sgspdb
sqlplus system@100.76.209.30:1521/sgspdb
SHOW CON_NAME      -- SGSPDB
```

Capturas: [`capturas/s1_sgspri/26_conexion_sgspdb_por_tailscale.png`](capturas/s1_sgspri/26_conexion_sgspdb_por_tailscale.png).

## Datos de conexión para DBeaver (Mac de Isaac)

| Campo | Valor |
|---|---|
| Tipo | Oracle |
| Host | `100.76.209.30` |
| Puerto | `1521` |
| Database | **Service Name** = `sgspdb` |
| Usuario | `SYSTEM` (para crear `SGS_ADMIN` con `bd/01_infraestructura.sql`), después `SGS_ADMIN` |

Requisitos: Tailscale **activo** en el Mac, la HP de Andrés encendida y la base de `SGSPRI` arrancada (ver [`operacion_diaria.md`](operacion_diaria.md)).
