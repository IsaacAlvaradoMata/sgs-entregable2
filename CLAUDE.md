# CLAUDE.md — Contexto del proyecto SGS (EIF-402, Entregable #2)

Este archivo es tu contexto completo. Vas a continuar el trabajo de un asistente que ya planificó todo el proyecto con Isaac. Actuá como ese asistente: mismo criterio, mismas decisiones, mismo ritmo. **No rediseñes lo que ya está decidido**. Si algo te parece mal, decilo y justificalo, pero no lo cambies sin que Isaac lo confirme.

---

## 1. Quién es Isaac y cómo trabajar con él

- Isaac es estudiante de Ingeniería en Sistemas en la Universidad Nacional de Costa Rica, Sede Regional Brunca (Pérez Zeledón).
- Hablale en **español**, con registro informal y técnico. Usá voseo costarricense ("podés", "tenés").
- **Paso a paso**: un tema a la vez. No le entregues scripts completos de una etapa por adelantado; ya lo corrigió antes por eso. Para el modelo (`02_modelo.sql`) se trabaja por **bloques funcionales** de tablas relacionadas (acordado 2026-10-26): resumís el diseño del bloque y qué cambia respecto al E1 → Isaac confirma → le das el bloque completo → lo corre con `Option + X` → una consulta de verificación por bloque, **siempre completa y lista para copiar** (Isaac no edita listas de tablas) → marcar en `guia.md` los ítems que ese bloque deja **completos** (no los parciales) → commit. Si una sentencia falla, se corrige solo esa.
- Cuando hay que corregir algo, entregá el **script corregido completo**, no fragmentos sueltos.
- En SQL usá **comentarios simples en línea**, no encabezados largos en bloque.
- Antes de diseñar, citá **textualmente** lo que pide el enunciado. **La fuente de verdad es el enunciado del E2** (y el del E1 en lo que sigue vigente para el modelo). Los laboratorios (`docs/ABD_L#3...`) solo sirven como patrón cuando el enunciado no define algo. Hay que apegarse al enunciado lo máximo posible; una mejora sobre lo que pide solo se hace si es claramente mejor y se le explica a Isaac (como el detalle de descuentos por producto y no por lote, porque en caja se escanea el producto).
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
- **Negocio**: `PCT_AVISO_CLIENTE` (0.85) · `PCT_AVISO_COORDINADOR` (0.85) · `PCT_AVISO_GERENTE_CXP` (0.70) · `DIAS_MOROSIDAD` (30) · `DIAS_PROXIMO_VENCER` (7) · `MESES_ANTIGUEDAD_BODEGA` (6) · `PREMIO_CANTIDAD_CLIENTES` (10) · `PREMIO_MONTO_ORDEN` (100000) 🔴 · `PREMIO_FRECUENCIA_MESES` (6) 🔴
- **Monitoreo**: `PCT_MAX_TABLESPACE` (0.85)
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
├── 02_modelo.sql                ← B1  ✅
├── 03_base_interna.sql          ← B2  ✅
├── 04_reglas_negocio.sql        ← B3  ✅
├── 05_bitacoras.sql             ← B4  ✅
├── 06_padron.sql                ← B5  ✅
├── 07_procesos.sql              ← B6  ✅
├── 08_seguridad.sql             ← B7  ✅
├── 09_monitoreo.sql             ← B8  ✅
└── 10_datos_operaciones.sql     ← datos de prueba de operaciones (con los packages; va al final)
```

- **Vos no podés ejecutar contra el Oracle de Isaac.** Tu sesión no llega a su Docker. Escribís y ordenás los scripts; Isaac los ejecuta y te pega los resultados o errores.
- Solo se sube al repo lo probado. Nunca contraseñas reales.
- Las claves de todos los ambientes van en `notas/claves.md`, que está en `.gitignore` (el repo es público): vive solo en el Mac de Isaac. Cada clave nueva se anota ahí.
- Flujo por paso: analizás la decisión y la describís con la cita del enunciado → Isaac confirma → la anotás en `docs/decisiones.md` → le das el script de ese paso → Isaac lo prueba en Docker → si funciona, se marca `- [x]` en `guia.md` y se hace commit.
- **Flujo rápido (acordado 2026-10-27, desde el paso 3.6):** (1) pedir confirmación solo cuando hay una decisión nueva; si el paso sigue un patrón ya acordado, en un mismo mensaje van el resumen y el código; (2) por cada paso se genera `bd/dbeaver/<paso>.sql` con `awk -f bd/dbeaver/convertir.awk` sobre la sección del script oficial, e Isaac lo corre con `Cmd + A` y `Option + X`; (3) una sola consulta de verificación por paso que devuelve filas con OK/FALLA; (4) menos capturas: una por resultado importante, y los errores esperados de packages se prueban juntos (cada uno en su BEGIN … EXCEPTION WHEN OTHERS THEN NULL END) y se muestran con una sola consulta a `SGS_BITACORA_ERROR`.

### Evidencias (para el PDF de evidencias)
- Solo de pasos que **ya funcionan**. Nunca de errores de nuestros scripts, pruebas fallidas ni capturas que Isaac manda para preguntar. **Excepción:** los errores **esperados** que demuestran que una restricción funciona sí son evidencia (ej. un rol sin permiso que intenta borrar y Oracle lo rechaza, una cuenta bloqueada por el perfil), como pide el laboratorio #3.
- Solo de **información concreta que hay que demostrar** (estados, tamaños, privilegios, datos resultantes). Nunca de un mensaje de ejecución exitosa: eso no aporta nada.
- Se toman justo después de cada consulta o subpaso, no todas al final. En cada paso le indicás a Isaac qué consulta correr y qué tiene que mostrar la captura.
- Isaac adjunta la captura; vos la guardás en `docs/evidencias/capturas/` con el nombre `<etapa>_<script>_<número>_<qué-muestra>.png` (ej. `B0_01_01_tablespaces.png`) y la registrás en `docs/evidencias/evidencias.md` (qué demuestra cada una). Ese `.md` es la base para armar el documento final.

### Porcentajes
Siempre como **fracción** (`0.15` = 15 %), `NUMBER(5,4)` + `CHECK BETWEEN 0 AND 1`, en tablas, parámetros y datos de prueba. En correos y reportes se muestran como `85 %`.

### Compatibilidad con 21c (Docker es 23ai, producción es 21c)
Prohibido: `IF NOT EXISTS` en DDL, `BOOLEAN` en columnas, `SELECT` sin `FROM DUAL`, `INSERT` multi-fila, `GROUP BY` por alias, `GRANT ... ON SCHEMA`, `DB_DEVELOPER_ROLE`. Tampoco `CONNECT`, `RESOURCE` ni `DBA`: privilegios explícitos.

### Ejecución en DBeaver (instrucciones para Isaac)
- Bloque PL/SQL (`DECLARE…END;`, `CREATE PROCEDURE/PACKAGE/TRIGGER`): seleccionar **sin la `/`** → `Cmd + Enter`.
- Varias sentencias SQL simples: seleccionar → `Option + X`.
- Una sola sentencia: cursor encima → `Cmd + Enter`.
- Con `/` al final de un trigger usando `Cmd+Enter` queda `INVALID`. `END nombre;` dentro de un procedimiento puede cortar el parseo: usar `END;`.
- **Varios triggers juntos con `Option + X` (probado 2026-10-27):** funciona si cada trigger va **sin la `/`**, **sin comentarios ni líneas en blanco dentro**, y separados entre sí por una línea en blanco. Con `/` y comentarios entre ellos falló (ORA-00900, el primero quedó INVALID). Los archivos del repo conservan las `/` (las necesitan SQL*Plus y SQL Developer); a Isaac se le pasan los bloques en el formato de DBeaver, listos para copiar.
- **Un bloque anónimo (`DECLARE … END;`) no va en un archivo de `bd/dbeaver/` (probado 2026-10-27):** DBeaver no lo separa del `CREATE` siguiente con la línea en blanco y da PLS-00103 ("Encountered the symbol CREATE"). Los archivos de DBeaver empiezan después de la validación de sesión; los bloques anónimos se corren aparte con `Cmd + Enter`.
- **Especificación y cuerpo de un package juntos con `Option + X` fallan (probado 2026-10-27, paso 4.1):** DBeaver metió el `CREATE PACKAGE BODY` dentro de la especificación (PLS-00103 en la línea del CREATE). Los packages van en su propio archivo `<paso>_package.sql` y se corren seleccionando la especificación → `Cmd + Enter`, y luego el cuerpo → `Cmd + Enter`. `Option + X` queda solo para triggers y sentencias SQL.

### Errores conocidos
- `SQLERRM` no va directo en un `INSERT VALUES` (ORA-00984): asignarlo antes a una variable.
- Una función **privada** de un package (no declarada en la especificación) no se puede usar dentro de una sentencia SQL (PLS-00231): calcular el valor antes en una variable y usar la variable en el SQL.
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
- Ampliación (2026-10-25): estado `'A'/'I'` en catálogos, montos `NUMBER(14,2)`, número de factura y desglose en factura de proveedor, traslado por lote (se cierra en decisión 6), abonos con el mecanismo único del E1 (`SGS_PAGO_FACTURA_*`). Análisis completo en `notas/analisis_e1.md`.

**No se integra**: `BODEGA` (se mantiene `SUC_ES_CENTRAL`), `EMPRESA`, `PRECIO_PRODUCTO` (el historial lo cubre `SGS_HISTORICO_PRECIO`), cliente único (se mantiene cliente/cliente_persona), `CLIENTE_DIRECCION`, cantidades de promoción en `PROMOCION_PRODUCTO`.

**Decisión 2 de B1 (confirmada 2026-10-25)** — opción C: encabezado por cliente/proveedor con límite y saldo total (fila que se bloquea con `FOR UPDATE`) + detalle por factura a crédito con monto original y saldo. Abonos en `SGS_PAGO_FACTURA_*`. Saldos mantenidos solo por triggers (desnormalización controlada). Detalle en `docs/decisiones.md`.

**Decisión 3 de B1 (confirmada 2026-10-25)** — estados, indicadores y datos personales cortos en `VARCHAR2(1)` + CHECK; tipos que guían lógica como palabra corta. Estado registro `A/I`; factura `P/C/N`; sexo `M/F`; estado civil `S/C/D/V/U`. Contado/crédito como `ES_CREDITO S/N`. El detalle de cuenta no lleva estado (vive en la factura).

**Decisión 4 de B1 (confirmada 2026-10-26)** — bitácora genérica: `SGS_BITACORA` (encabezado: área, tabla, operación, registro, usuario BD/SO, equipo, fecha, `ES_CRITICA`) + `SGS_BITACORA_DETALLE` (columna, valor anterior/nuevo en VARCHAR2(250)) + `SGS_BITACORA_ERROR` aparte. Todo en `SGS_AUD`. Qué es crítico se define en B4.

**Decisión 5 de B1 (confirmada 2026-10-26)** — `SGS_PADRON` + `SGS_DISTRITO_ELECTORAL`; FK opcional desde `SGS_CLIENTE_PERSONA` (solo clientes `NACIONAL`, validado por trigger); cédula nacional de 9 dígitos; el registro de cliente nacional autocompleta nombre y apellidos desde el padrón (el sexo se digita: el TSE no lo trae; se quitaron PAD_SEXO y PAD_JUNTA); la carga usa `MERGE`, nunca vacía la tabla. Formato del archivo se resuelve en B5.

**Decisión 6 de B1 (confirmada 2026-10-26)** — `SGS_LOTE` (nace de la línea de factura de proveedor) + `SGS_EXISTENCIA` (lote × sucursal) + traslado encabezado/detalle por lote + `SGS_MOVIMIENTO_INVENTARIO` (cada entrada/salida por lote con su documento). Ventas por FEFO; la factura no lleva lote, el movimiento sí.

**Avance al 2026-10-26** (detalle en `guia.md`, `docs/decisiones.md` y `docs/evidencias/evidencias.md`):
- **B1 (modelo):** `bd/02_modelo.sql` con 57 tablas por bloques funcionales, vista de precio de venta y datos de catálogos (mínimo 5 filas). Probado desde cero (`00` → `01` → `02`). Pendientes: datos de operaciones (después de B3, con los packages), diagrama y diccionario (se generan del script al cerrar el modelo), retomar las capturas 1 a 4 de B1 (el modelo pasó de 55 a 57 tablas).
- **B2 (base interna) completa:** `bd/03_base_interna.sql` con `SGS_PKG_ERRORES`, `SGS_PKG_PARAMETROS`, `SGS_PKG_CIFRADO` (cuerpo con `DBMS_DDL.CREATE_WRAPPED`, llave como `<LLAVE_CIFRADO>` en el repo) y `SGS_PKG_CORREO` (Gmail por el puerto 465 en desarrollo, wallet en `/opt/oracle/oradata/wallet_sgs`, ver `servidores/configuracion/wallet_correo.md`). Correo de prueba recibido.
- **B3 (reglas de negocio) completa:** `bd/04_reglas_negocio.sql` (triggers de cuentas, inventario, historial y validaciones; packages de clientes, compras, inventario y ventas, con SAVEPOINT, FOR UPDATE NOWAIT/WAIT y bitácora de errores) y `bd/10_datos_operaciones.sql` (datos de operaciones con los packages + simulación de fechas para B6).
- **B4 (bitácoras) completa:** `bd/05_bitacoras.sql` (`SGS_PKG_BITACORA`, 33 triggers `TRG_AUD_*` generados de las columnas del modelo, vistas `SGS_VW_BITACORA` y `SGS_VW_BITACORA_CRITICA`); críticas definidas en `docs/decisiones.md`. Probado: rastro en las 7 áreas, críticas bien marcadas y el `ROLLBACK` deshace el rastro.
- **B5 (padrón) completa en Docker:** `bd/06_padron.sql` (directorio `SGS_DIR_PADRON` desde SYSDBA, tablas externas `SGS_EXT_DISTELEC` y `SGS_EXT_PADRON` sobre los TXT del TSE, `SGS_PKG_PADRON.cargar` con `MERGE` que nunca borra). Cargados 2179 distritos y 3 762 240 personas; recargar el mismo archivo no cambia nada. Sin job: el enunciado no lo pide. Falta acordar con Andrés la carpeta en las VMs.
- Instalación en SGSPRI (valores por servidor, orden, verificaciones): `servidores/configuracion/instalacion_bd_sgspri.md`.
- **B6 (procesos y notificaciones) completa:** `bd/07_procesos.sql` con `SGS_PKG_PROCESOS` (N1 a N5 diarios a las 07:00; P1 inventario y P2 descuentos semanales; P3 premiación cada `PREMIO_FRECUENCIA_MESES` meses; P4 cierre diario a las 00:05 del día anterior) y 9 jobs de `DBMS_SCHEDULER` en hora de Costa Rica. Todos probados a demanda con su correo. Decisiones en `docs/decisiones.md`; N2 en espera de la respuesta del profesor.
- **B7 (seguridad) completa:** `bd/08_seguridad.sql`: perfil `SGS_PERFIL_USUARIO`, usuarios por rol (confirmado por el profesor) con `DEFAULT ROLE NONE`, roles `SGS_ROL_*` con clave cifrada en `CLAVE_ROL_*`, `SGS_PKG_SEGURIDAD.asignar_clave_rol`, `SGS_PKG_ROLES.clave_rol` y `SGS_PKG_ACCESO.activar_rol` (derechos del invocador). `asignar_credito` pasó a `SGS_PKG_CREDITO` (en el 04). Probado con los 4 usuarios, bloqueo y reutilización.
- **Instalación completa en Docker:** `bash bd/local/instalar_docker.sh` (en `.gitignore`: pone las claves de desarrollo, corre 00 a 10 con SQL*Plus y el usuario de cada sección, se detiene en el primer error; logs en `bd/local/instalacion/logs/`). Para SGSPRI se arma uno igual con las claves de producción.
- **Scripts con muchos bloques PL/SQL se corren con SQL*Plus dentro del contenedor** (`docker exec -i oracle_una sqlplus -s -L "<usuario>/<clave>@//localhost:1521/FREEPDB1" < archivo`); las copias con claves de desarrollo van en `bd/local/` (en `.gitignore`). En 26ai la falta de privilegio sale como `ORA-41900`; en 21c es `ORA-01031`.
- **SQL*Plus siempre con `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`** (`docker exec -i -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 oracle_una sqlplus ...`): sin eso SQL*Plus lee el archivo UTF-8 como un juego de caracteres de un byte y las tildes y la Ñ de los textos quedan dañadas dentro del package (pasó en B8; DBeaver no tiene el problema). En SGSPRI, `export NLS_LANG=AMERICAN_AMERICA.AL32UTF8` antes de usar SQL*Plus.
- **B8 (monitoreo) completa:** `bd/09_monitoreo.sql`: `SGS_PKG_MONITOREO` (tablespaces, objetos inválidos e índices diarios; bloqueos cada 15 min con `MINUTOS_SESION_BLOQUEADA`; registro diario con reporte y crecimiento), columna nueva `MON_ERRORES` (también en `02_modelo.sql`), vista `SGS_VW_CRECIMIENTO`, vistas materializadas `SGS_MV_VENTAS_MENSUALES` y `SGS_MV_INVENTARIO_CONSOLIDADO` (refresco diario 00:30), análisis de planes en `docs/optimizacion.md`. 15 jobs en total.
- **Carril B completo (B1 a B8).** 5 filas o más en las 57 tablas (sección D de `10_datos_operaciones.sql`: premiaciones con fecha de corte, cierres, descuentos, monitoreo). Instalación desde cero probada el 2026-10-28 con `bd/local/instalar_docker.sh` (00 → 10 en 1 min 27 s, todo OK) y capturas 1 a 4 de B1 retomadas. Siguiente: diagrama y diccionario de datos, y paso a SGSPRI cuando Andrés tenga Tailscale listo.
- Conexiones DBeaver: `Docker - SGS_ADMIN (FREEPDB1)`, SYSTEM y `free (SYSDBA)` (entra como SYS a `FREEPDB1`). Bloques PL/SQL con `Cmd + Enter`; varias sentencias con `Option + X`.
- El Docker está en hora UTC (6 h adelante); en los servidores se configura `America/Costa_Rica` (pendiente de Andrés).

**Avance de Andrés (informado 2026-10-27):** VMs en VirtualBox con Oracle Linux 8.10 + Oracle 21c EE: `SGSPRI` en `192.168.56.101` y `SGSSTB` en `192.168.56.102` (red solo anfitrión, existe solo dentro de la HP). CDB `SGS` (`DB_UNIQUE_NAME=SGSPRI`) con la PDB `SGSPDB` (servicio `sgspdb`, puerto 1521). Data Guard funcionando hacia `SGSSTB`. Para que Isaac llegue desde el Mac, las dos VMs se unen a la tailnet de Isaac con una llave de autorización que genera Isaac (sin exit node; Data Guard sigue por `192.168.56.x`).

**Pendiente de Andrés:** definir `RESP_HORA_DIARIO`; unir las VMs a Tailscale y abrir el listener en la IP `100.x`; zona horaria; wallet del correo y prueba de puertos en las dos VMs; decir si standby/RMAN necesitan alguna tabla. Ver `notas/pendientes.md`.

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
6. **Nunca te pongás como colaborador** en commits ni PRs: sin línea `Co-Authored-By` ni "Generated with Claude Code". El autor es solo Isaac.
