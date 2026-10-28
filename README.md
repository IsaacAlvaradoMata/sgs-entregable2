# SGS — Entregable #2 · Administración de Bases de Datos (EIF-402)

Proyecto final del curso Administración de Bases de Datos, UNA Sede Regional Brunca, II Ciclo 2026.
Sistema de Gestión de Supermercados (SGS) en Oracle 21c, construido sobre el modelo del Entregable #1.

**Entrega:** lunes 9 de noviembre de 2026 (PZ).

---

## De qué trata

Este avance tiene dos partes que se trabajan en paralelo:

1. **Base de datos (lógica):** ajustar el modelo del E1 y agregarle funciones, seguridad, bitácoras, procesos automáticos y notificaciones por correo, todo dentro de Oracle (packages, triggers y jobs con `DBMS_SCHEDULER`).
2. **Servidores (infraestructura):** un servidor principal y uno standby con Oracle Data Guard, respaldos con RMAN y demostración de switchover, failover y recuperación.

## Responsables

| Parte | Responsable |
|---|---|
| Base de datos: modelo, packages, triggers, notificaciones, seguridad, monitoreo | Isaac |
| Servidores: VMs, Oracle 21c, principal, standby, RMAN, switchover/failover | (Andres) |
| Manuales, pruebas finales y defensa | Ambos |

## Arquitectura

```
HP (Windows 11)                              
├── VM SGSPRI  (Oracle Linux + Oracle 21c EE)  ◄──── DBeaver (cliente)  Mac de Isaac
│      │  Data Guard (red interna de las VMs)
│      ▼
└── VM SGSSTB  (Oracle Linux + Oracle 21c EE)
```

- La comunicación entre principal y standby va por la **red interna** de las VMs.
- Tailscale se usa solo para que el Mac llegue a las VMs. **No se usa "exit node"**: el correo debe salir directo desde Oracle, no por VPN.

## Decisiones fijas

| Elemento | Valor |
|---|---|
| Usuario dueño del esquema | `SGS_ADMIN` |
| Pluggable database | `SGSPDB` |
| Servidor principal (`DB_UNIQUE_NAME`) | `SGSPRI` |
| Servidor standby (`DB_UNIQUE_NAME`) | `SGSSTB` |
| Prefijo de objetos | `SGS_` |

Cualquier decisión nueva se anota en [`docs/decisiones.md`](docs/decisiones.md) antes de usarla.

## Estructura del repositorio

```
sgs-entregable2/
├── README.md              ← este archivo
├── guia.md                ← guía de implementación por etapas
├── bd/                    ← scripts de base de datos (Isaac), numerados en orden de ejecución
├── servidores/
│   ├── configuracion/     ← archivos de red de Oracle y ajustes de Linux
│   ├── scripts/           ← scripts de Linux (traslados, limpieza, respaldos)
│   └── rman/              ← scripts de respaldo y recuperación
├── notas/
│   └── pendientes.md      ← qué falta y quién lo tiene
├── docs/
│   ├── decisiones.md      ← acuerdos tomados
│   └── ...                ← enunciado y manuales finales
└── entregable_1/          ← entregas del Entregable #1 (referencia)
```

## Cómo trabajamos con el repo

Usamos **GitHub Desktop** (no hace falta usar comandos).

1. **Antes de empezar a trabajar:** *Fetch origin* → *Pull* para traer lo último.
2. Trabajar en **tu carpeta** (`bd/` o `servidores/`). Las carpetas `notas/` y `docs/` son compartidas.
3. **Al terminar algo que ya funciona:** escribir un mensaje corto en *Summary* (ej. "Tabla de parámetros creada") → *Commit to main* → *Push origin*.
4. Avisarle al otro si el cambio le afecta (por ejemplo, un parámetro nuevo que el standby debe leer).

## Reglas

- **Solo se sube lo que ya fue probado y funciona.** El repo no es un borrador.
- **Nunca subir contraseñas reales** (SYS, correo, roles). En los scripts se dejan como marcador, por ejemplo `<CLAVE_CORREO>`, y cada uno guarda las reales aparte.
- Los scripts de `bd/` llevan un número al inicio (`01_`, `02_`…) que indica el orden en que se ejecutan.
- Los scripts deben poder ejecutarse **desde cero** en el servidor principal; el manual de instalación se arma siguiendo ese orden.
- Comentarios simples dentro del código explicando qué hace cada parte.

## Orden de ejecución

Se va completando a medida que avanzamos.

| # | Script | Dónde se ejecuta | Conectado como | Estado |
|---|---|---|---|---|
| 01 | `bd/01_infraestructura.sql` | SGSPRI | SYSTEM (PDB `SGSPDB`) | Pendiente |
| 02 | `bd/02_modelo.sql` | SGSPRI | `SGS_ADMIN` | Pendiente |

## Estado del proyecto

Ver [`notas/pendientes.md`](notas/pendientes.md).