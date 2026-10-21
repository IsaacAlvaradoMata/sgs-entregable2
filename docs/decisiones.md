# Decisiones del proyecto

Registro de acuerdos tomados. Antes de usar un nombre, valor o criterio nuevo, se anota aquí.

## Etapa 0 — Acuerdos previos

| Fecha | Decisión | Valor |
|---|---|---|
| 2026-10-13 | Usuario dueño del esquema | `SGS_ADMIN` |
| 2026-10-13 | Pluggable database | `SGSPDB` |
| 2026-10-13 | Servidor principal (`DB_UNIQUE_NAME`) | `SGSPRI` |
| 2026-10-13 | Servidor standby (`DB_UNIQUE_NAME`) | `SGSSTB` |
| 2026-10-13 | Prefijo de objetos | `SGS_` |
| 2026-10-13 | Arquitectura | 2 VMs (Oracle Linux + Oracle 21c EE) en la HP de Andrés; Mac de Isaac como cliente con DBeaver. Validado con el profesor. |
| 2026-10-13 | Red | Principal ↔ standby por red interna de las VMs. Tailscale solo para que el Mac llegue a las VMs, **sin exit node**. |
| 2026-10-13 | Documentación de trabajo | Vive en este repositorio (guía en `docs/guia.md`). |
| 2026-10-13 | Cuenta remitente de notificaciones | `sgs.notificaciones.una@gmail.com` (la contraseña NO se guarda en el repo) |

## Parámetros

Los parámetros se guardan como **filas** dentro de la tabla de parámetros (no llevan prefijo `SGS_`; la tabla sí). Los valores se guardan en `VARCHAR2(250)` (sin CLOB). 🔴 = obligatorio por el enunciado · 🟢 = recomendado · 🔒 = cifrado con `DBMS_CRYPTO`.

**Destinatarios de notificaciones:** no van como parámetros. Se guardan en una **tabla de destinatarios** aparte (tipo: gerente, coordinador, DBA; uno o varios correos por tipo), porque el enunciado habla de "correo(s)". Su diseño se cierra en B1.

### Correo

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `CORREO_REMITENTE` | `sgs.notificaciones.una@gmail.com` | 🔴 | Isaac |
| `CORREO_CLAVE` | contraseña de aplicación de Gmail | 🔴🔒 | Isaac |
| `CORREO_SERVIDOR` | `smtp.gmail.com` | 🟢 | Isaac |
| `CORREO_PUERTO` | `587` | 🟢 | Isaac |

### Reglas de negocio

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `PCT_AVISO_CLIENTE` | 85 | 🟢 | Isaac |
| `PCT_AVISO_COORDINADOR` | 85 | 🟢 | Isaac |
| `PCT_AVISO_GERENTE_CXP` | 70 | 🟢 | Isaac |
| `DIAS_MOROSIDAD` | 30 | 🟢 | Isaac |
| `DIAS_PROXIMO_VENCER` | 7 | 🟢 | Isaac |
| `MESES_ANTIGUEDAD_BODEGA` | 6 | 🟢 | Isaac |
| `PREMIO_CANTIDAD_CLIENTES` | 10 | 🟢 | Isaac |
| `PREMIO_MONTO_ORDEN` | 100000 | 🔴 | Isaac |
| `PREMIO_FRECUENCIA_MESES` | 6 | 🔴 | Isaac |

### Monitoreo

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `PCT_MAX_TABLESPACE` | 85 | 🟢 | Isaac |

### Standby y respaldos

| Código | Valor inicial | Tipo | Lo usa |
|---|---|---|---|
| `STB_MINUTOS_ARCHIVO` | 5 | 🔴 | Andrés |
| `STB_MB_ARCHIVO` | 50 | 🔴 | Andrés |
| `STB_MINUTOS_TRASLADO` | 10 | 🔴 | Andrés |
| `STB_DIAS_BORRADO` | 3 | 🔴 | Andrés |
| `RESP_HORA_DIARIO` | **pendiente (Andrés)** | 🟢 | Andrés |

### Claves de roles

| Código | Valor | Tipo | Lo usa |
|---|---|---|---|
| `CLAVE_ROL_GERENTE` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_JEFE_DEPTO` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_JEFE_PROVEEDURIA` | se define en B7 | 🔴🔒 | Isaac |
| `CLAVE_ROL_DIGITADOR` | se define en B7 | 🔴🔒 | Isaac |

## Carril B — Base de datos

### B1 — Esquema

**Decisión 1 — Qué se integra del esquema de Andrés (`CADENA_NEGOCIOS`)** · 2026-10-13

Se integra (traducido a la convención SGS):
- Cuentas por cobrar y por pagar con sus abonos y estado.
- Condición (contado/crédito) y estado en las facturas de venta y de proveedor.
- Lote separado de la existencia, ligado al detalle de compra y con fecha de vencimiento.
- Descuento con días desde ingreso / días para vencer y validación por tipo de criterio.
- Tipo de pago en los abonos a proveedor.
- Porcentaje de impuesto por producto (opcional elegido).

No se integra: `BODEGA` (se mantiene `SUC_ES_CENTRAL`), `EMPRESA` (cubierto por tipo de negocio), `PRECIO_PRODUCTO` (el E2 pide historial de costo, ya cubierto), `CLIENTE` único (se mantiene la separación cliente / cliente persona), `CLIENTE_DIRECCION` (dos direcciones fijas), cantidades de promoción en `PROMOCION_PRODUCTO` (el E2 las ubica en la tabla de promociones).

**Forma de trabajo** · 2026-10-13
- Desarrollo en Docker (`FREEPDB1`); oficial en `SGSPRI` (`SGSPDB`).
- El script es lo oficial: nada se cambia solo en la base.
- Un script consolidado por etapa, probado desde cero antes de subirlo e integrarlo.
- El esquema del E1 (`IALVARADO`) se elimina del Docker; queda respaldado en `SGS_IsaacAlvarado.sql`.

## Carril S — Servidores

### S1 — VMs y red

**Infraestructura de las VMs** · 2026-10-17

| Elemento | Valor |
|---|---|
| Hipervisor | VirtualBox 7.2 en la HP (Windows 11 Pro, 16 GB RAM) |
| Sistema operativo | Oracle Linux 8.10, instalación "Server" (sin interfaz gráfica) |
| Recursos por VM | 5 GB RAM, 2 CPU, disco 80 GB VDI dinámico |
| Particiones | `/boot` 1 GiB, `swap` 5 GiB, `/` 74 GiB (sin `/home`) |
| Red interna (Data Guard) | Solo-anfitrión `192.168.56.0/24`, sin DHCP; la HP es `192.168.56.1` |
| Internet | Adaptador NAT en cada VM |

| Servidor | Hostname | IP red interna | Estado |
|---|---|---|---|
| `SGSPRI` | `sgspri.localdomain` | `192.168.56.101` | Linux instalado, SSH desde la HP ✅ |
| `SGSSTB` | `sgsstb.localdomain` | `192.168.56.102` | Clon de `SGSPRI` con identidad propia, solo software Oracle ✅ |

Pasos detallados en [`servidores/s1_sgspri.md`](../servidores/s1_sgspri.md).