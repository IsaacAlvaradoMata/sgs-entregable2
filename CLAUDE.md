# CLAUDE.md — Contexto del proyecto SGS (EIF-402, Entregable #2)

Este archivo es tu contexto completo. Vas a continuar el trabajo de un asistente que ya planificó todo el proyecto con Isaac. Actuá como ese asistente: mismo criterio, mismas decisiones, mismo ritmo. **No rediseñes lo que ya está decidido**. Si algo te parece mal, decilo y justificalo, pero no lo cambies sin que Isaac lo confirme.

---

## 1. Quién es Isaac y cómo trabajar con él

- Isaac es estudiante de Ingeniería en Sistemas en la Universidad Nacional de Costa Rica, Sede Regional Brunca (Pérez Zeledón).
- Hablale en **español**, con registro informal y técnico. Usá voseo costarricense ("podés", "tenés").
- **Paso a paso**: un objeto o un tema a la vez. No le entregues scripts completos de una etapa por adelantado; ya lo corrigió antes por eso.
- Cuando hay que corregir algo, entregá el **script corregido completo**, no fragmentos sueltos.
- En SQL usá **comentarios simples en línea**, no encabezados largos en bloque.
- Antes de diseñar, citá **textualmente** lo que pide el enunciado.
- Guardá el avance en archivos (por ejemplo `docs/decisiones.md`), no solo en la conversación.
- En todo lo que va dirigido al profesor (manuales, comentarios de scripts), escribí como si **Isaac** le explicara al profesor. No le expliqués conceptos básicos al profe ni le citás los números de requisito del enunciado.
- En guías y manuales documentá **solo pasos confirmados que funcionan**. Nada de intentos fallidos.

---

## 2. El curso y la entrega

- Curso: **Administración de Bases de Datos, EIF-402**, II Ciclo 2026. Profesores: Hairol Romero y Jeremy Elizondo.
- **Entrega del Entregable #2 (final): lunes 9 de noviembre de 2026.**
- Trabajo en parejas: **Isaac + Andrés**.

### Rúbrica principal
| Área | Peso | Detalle |
|---|---|---|
| Standby | 35% | Implementación 20 · admin/sincronización 5 · RMAN 5 · failover/switchover 5 |
| Arquitectura e implementación | 25% | Arquitectura 8 · procedimientos/funciones 12 · transaccional 2.5 · triggers 2.5 |
| Administración | 20% | Seguridad 5 · scheduler 5 · bitácoras 5 · monitoreo 5 |
| Documentación | 10% | |
| Defensa | 10% | |

### Escala de funcionamiento (también suma 100%)
Negocio 40% (padrón 6%, inventario 5%) · Seguridad 15% · Automatización 15% · Bitácoras 10% · Notificaciones 10% · Monitoreo 10%.

---

## 3. Punto de partida (Entregable #1)

- **Esquema de Isaac** (base elegida, nota 95): usuario `IALVARADO`, prefijo `SGS_`, 34 tablas en 7 grupos: núcleo, producto, inventario por lote, facturación de venta, facturación de proveedor, devoluciones/notas de crédito, promociones/descuentos. Tablespaces `SGS_DATA`, `SGS_IDX`, `SGS_AUD`. Tiene `SGS_BITACORA` y `SGS_HISTORICO_PRECIO` (sin lógica todavía) y la vista `SGS_VW_PRECIO_VENTA`. Script original: `SGS_IsaacAlvarado.sql`.
- **Esquema de Andrés** (nota 91): `CADENA_NEGOCIOS`, 41 tablas, carpeta `Script/`.
- **Correcciones del profe a Isaac**: nacionalidad y residencia deben referenciar una tabla de países; no usar CLOB (usar `VARCHAR2(250)`); estados y género en `VARCHAR2(1)`.
- **Correcciones a Andrés**: no usar CHAR; aplicar estándar de nombres; estados y género en `VARCHAR2(1)` con CHECK.

---

## 4. Arquitectura (confirmada por el profesor)

```
HP de Andrés (Windows 11)                  Mac de Isaac (Apple Silicon)
├── VM SGSPRI (Oracle Linux 8 + 21c EE) ◄──── DBeaver (cliente)
│      │ Data Guard (red interna de las VMs)
└── VM SGSSTB (Oracle Linux 8 + 21c EE)
```

- El profesor confirmó que dos VMs en una misma computadora cuentan como dos servidores.
- **Tailscale** en ambas VMs y en el Mac, **sin exit node**: el correo no puede salir por VPN. La sincronización principal↔standby va por la red interna de las VMs, no por Tailscale. Verificación: `ip route get 142.250.0.1` debe mostrar la interfaz normal (ej. `enp0s3`), no `tailscale0`.
- Data Guard requiere Enterprise Edition. Oracle 21c no tiene versión ARM nativa, por eso los servidores van en la HP.
- **Desarrollo actual**: Oracle Free 23ai en Docker en el Mac de Isaac (contenedor `oracle_una`, PDB `FREEPDB1`), con DBeaver.

### División del trabajo
- **Isaac (carril B)**: modelo, packages, triggers, notificaciones, seguridad, monitoreo.
- **Andrés (carril S)**: VMs, Oracle 21c, standby, RMAN, switchover/failover.
- **Ambos**: manuales y defensa.

---

## 5. Nombres fijos (Etapa 0)

| Elemento | Valor |
|---|---|
| Usuario dueño | `SGS_ADMIN` |
| PDB de producción | `SGSPDB` |
| Servidor principal | `SGSPRI` |
| Servidor standby | `SGSSTB` |
| Prefijo de objetos | `SGS_` |
| Correo del proyecto | `sgs.notificaciones.una@gmail.com` |
| Clave SGS_ADMIN | `SgsDev2026` (**solo Docker de desarrollo**, nunca en producción ni en el repo como clave real) |

---

## 6. Parámetros

Van en una tabla de parámetros (`SGS_` en la tabla, **sin prefijo** en los códigos porque son filas de datos). 🔴 obligatorio por enunciado · 🔒 cifrado.

- **Correo**: `CORREO_REMITENTE` 🔴 · `CORREO_CLAVE` 🔴🔒 · `CORREO_SERVIDOR` (smtp.gmail.com) · `CORREO_PUERTO` (587)
- **Negocio**: `PCT_AVISO_CLIENTE` (85) · `PCT_AVISO_COORDINADOR` (85) · `PCT_AVISO_GERENTE_CXP` (70) · `DIAS_MOROSIDAD` (30) · `DIAS_PROXIMO_VENCER` (7) · `MESES_ANTIGUEDAD_BODEGA` (6) · `PREMIO_CANTIDAD_CLIENTES` (10) · `PREMIO_MONTO_ORDEN` (100000) 🔴 · `PREMIO_FRECUENCIA_MESES` (6) 🔴
- **Monitoreo**: `PCT_MAX_TABLESPACE` (85)
- **Standby (Andrés)**: `STB_MINUTOS_ARCHIVO` (5) 🔴 · `STB_MB_ARCHIVO` (50) 🔴 · `STB_MINUTOS_TRASLADO` (10) 🔴 · `STB_DIAS_BORRADO` (3) 🔴 · `RESP_HORA_DIARIO` (**pendiente**)
- **Claves de roles** (se definen en B7): `CLAVE_ROL_GERENTE`, `CLAVE_ROL_JEFE_DEPTO`, `CLAVE_ROL_JEFE_PROVEEDURIA`, `CLAVE_ROL_DIGITADOR` 🔴🔒

Los **destinatarios de notificaciones** van en una tabla aparte (tipo gerente/coordinador/DBA, uno o varios correos por tipo), no como parámetros, porque el enunciado dice "correo(s)".

---

## 7. Metodología acordada

- **El script es lo oficial, no la base.** Nada se cambia solo en la base.
- Ciclo por pieza: diseñar → Isaac ejecuta en DBeaver contra Docker → probar → guardar en el script numerado → subir al repo → al cerrar la etapa, ejecutar en SGSPRI.
- **Un script consolidado por etapa**, probado desde cero (con `00_reinicio_desarrollo.sql`) antes de subirlo:

```
bd/
├── 00_reinicio_desarrollo.sql   ← solo Docker  ✅
├── 01_infraestructura.sql       ← tablespaces y SGS_ADMIN  ✅
├── 02_modelo.sql                ← B1 (siguiente)
├── 03_base_interna.sql          ← B2
├── 04_reglas_negocio.sql        ← B3
├── 05_bitacoras.sql             ← B4
├── 06_padron.sql                ← B5
├── 07_procesos.sql              ← B6
├── 08_seguridad.sql             ← B7
└── 09_monitoreo.sql             ← B8
```

- **Vos no podés ejecutar contra el Oracle de Isaac.** Tu sesión no llega a su Docker. Escribís y ordenás los scripts; Isaac los ejecuta y te pega los resultados o errores.
- Solo se sube al repo lo probado. Nunca contraseñas reales.

### Compatibilidad con 21c (Docker es 23ai, producción es 21c)
Prohibido: `IF NOT EXISTS` en DDL, `BOOLEAN` en columnas, `SELECT` sin `FROM DUAL`, `INSERT` multi-fila, `GROUP BY` por alias, `GRANT ... ON SCHEMA`, `DB_DEVELOPER_ROLE`. Tampoco `CONNECT`, `RESOURCE` ni `DBA`: privilegios explícitos.

### Ejecución en DBeaver (instrucciones para Isaac)
- Bloque PL/SQL (`DECLARE…END;`, `CREATE PROCEDURE/PACKAGE/TRIGGER`): seleccionar **sin la `/`** → `Cmd + Enter`.
- Varias sentencias SQL simples: seleccionar → `Option + X`.
- Una sola sentencia: cursor encima → `Cmd + Enter`.
- Con `/` al final de un trigger usando `Cmd+Enter` queda `INVALID`. `END nombre;` dentro de un procedimiento puede cortar el parseo: usar `END;`.

### Errores conocidos
- `SQLERRM` no va directo en un `INSERT VALUES` (ORA-00984): asignarlo antes a una variable.
- No existe `CREATE OR REPLACE SEQUENCE`.
- Usuarios y objetos van en la PDB, nunca en `CDB$ROOT` (ORA-65096).
- `GRANT ... ON DIRECTORY` y privilegios sobre `DBMS_CRYPTO`, `UTL_SMTP`, `UTL_FILE` se otorgan desde la conexión SYSDBA ("free (SYSDBA)" en DBeaver).
- `SET ROLE` no funciona dentro de un procedimiento definer: usar `DBMS_SESSION.SET_ROLE` con `AUTHID CURRENT_USER`.

### Riesgos técnicos
1. Correo desde Oracle con TLS + wallet + contraseña de aplicación de Gmail: lo más riesgoso del carril B.
2. `SET ROLE` en procedimientos (ver arriba).
3. Data Guard solo en EE.
4. 21c sin ARM.

---

## 8. Estado actual

**Hecho:**
- Análisis del enunciado y rúbrica; comparación de esquemas; arquitectura validada; nombres fijos; repo creado; correo creado.
- `README.md`, `guia.md`, `docs/decisiones.md`.
- `bd/00_reinicio_desarrollo.sql` ejecutado: `IALVARADO` y tablespaces del E1 eliminados del Docker.
- `bd/01_infraestructura.sql` ejecutado y verificado: 3 tablespaces ONLINE con MAXSIZE finito (4G/2G/1G), `SGS_ADMIN` OPEN, 8 privilegios explícitos (CREATE SESSION, TABLE, SEQUENCE, VIEW, MATERIALIZED VIEW, PROCEDURE, TRIGGER, JOB), 0 roles.

**Decisión 1 de B1 (confirmada)** — se integra del esquema de Andrés, traducido a convención SGS:
- Cuentas por cobrar y por pagar con abonos y estado.
- Condición (contado/crédito) y estado en facturas de venta y de proveedor.
- Lote separado de la existencia, ligado al detalle de compra, con fecha de vencimiento.
- Descuento con días desde ingreso / días para vencer y validación por tipo de criterio.
- Tipo de pago en abonos a proveedor.
- Porcentaje de impuesto por producto.

**No se integra**: `BODEGA` (se mantiene `SUC_ES_CENTRAL`), `EMPRESA`, `PRECIO_PRODUCTO` (el historial lo cubre `SGS_HISTORICO_PRECIO`), cliente único (se mantiene cliente/cliente_persona), `CLIENTE_DIRECCION`, cantidades de promoción en `PROMOCION_PRODUCTO`.

**Decisión 2 de B1 — EN CURSO, falta que Isaac confirme.** Dónde vive el saldo de clientes y proveedores:
- (A) Solo calculado, como en el E1: choca con la letra del enunciado.
- (B) Saldo por factura: normalizado, pero no hay "saldo del cliente".
- (C) **Recomendada**: encabezado por cliente/proveedor con saldo total + detalle por factura. Calza literal con el enunciado ("aumentar el saldo del cliente" + "agregar al detalle"), permite `SELECT ... FOR UPDATE` sobre el encabezado (requisito de concurrencia) y sostiene los límites de crédito y los avisos de 85% y 70%. La redundancia se defiende como desnormalización controlada mantenida por triggers. La CxC por factura de Andrés pasa a ser el detalle.

**Decisiones pendientes de B1:**
3. Códigos de atributos de dominio corto (estados, sexo, estado civil, tipo de persona).
4. Bitácoras: una general con valor anterior/nuevo vs. una tabla de auditoría por área.
5. Enlace padrón ↔ clientes (relación opcional: extranjeros y empresas no están en el padrón).
6. Modelado de lotes.

Después de cerrar las 6 decisiones se escribe `bd/02_modelo.sql`, tabla por tabla, con Isaac probando en Docker.

**Pendiente de Isaac:** crear la conexión DBeaver "Docker - SGS_ADMIN (FREEPDB1)". No borrar "free (SYSDBA)".

**Pendiente de Andrés:** RAM y disco libre de la HP (se necesitan ~16 GB RAM y ~100 GB de disco); definir `RESP_HORA_DIARIO`; instalar VirtualBox, Oracle Linux 8 y Oracle 21c EE; crear las dos VMs con red interna + NAT.

**Preguntas abiertas al profesor:**
- ¿El aviso del 85% al coordinador "en cuentas por pagar" es de clientes o de proveedores? (la escala dice "Proveedores con límite de crédito").
- ¿El 70% del gerente es sobre el límite de cada proveedor o un límite global de CxP?
- ¿Quién es "el coordinador"?
- ¿"Cargar automáticamente el padrón" incluye descargarlo o basta cargarlo desde archivo?
- ¿Cómo se combinan las dos tablas de calificación?
- ¿Los manuales son cuatro documentos o uno?

---

## 9. Qué hacer al arrancar una sesión

1. Leé este archivo, `README.md`, `guia.md` y `docs/decisiones.md`. Revisá todo `bd/` y cualquier script del E1 o de Andrés que esté en el repo. Si el enunciado (PDF) está en el repo, leelo; si no está, pedíselo a Isaac.
2. Si algo del repo contradice este archivo, avisale a Isaac antes de seguir. Lo más reciente que él confirme manda.
3. Decile en pocas líneas dónde estamos y cuál es el siguiente paso concreto.
4. Cada decisión que Isaac confirme, anotala en `docs/decisiones.md`. Al cerrar una etapa, marcá su estado en la matriz de trazabilidad de `guia.md` y actualizá la sección 8 de este archivo.
5. Hacé commits pequeños y con mensajes claros en español, solo con lo que Isaac confirmó que funciona.
