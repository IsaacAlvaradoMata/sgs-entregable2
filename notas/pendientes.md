# Pendientes

Qué falta y quién lo tiene. Se actualiza al avanzar; el detalle de cada etapa está en [`guia.md`](../guia.md).

| Pendiente | Responsable | Estado |
|---|---|---|
| `bd/02_modelo.sql`: estructura y datos de catálogos | Isaac | Hecho (2026-10-26) |
| Preguntar a Andrés si sus procesos de standby y RMAN necesitan alguna tabla (registro de traslados, respaldos) | Isaac | Pendiente |
| Datos de prueba de operaciones (compras, ventas, pagos, devoluciones, traslados) | Isaac | Después de B3 |
| Diagrama relacional y diccionario de datos (se generan del script al cerrar el modelo) | Isaac | Pendiente |
| Configurar la zona horaria `America/Costa_Rica` en el sistema operativo de `SGSPRI` y `SGSSTB` antes de instalar Oracle (Docker está en UTC; solo se tiene en cuenta al probar B6 en desarrollo) | Andrés | Pendiente |
| Probar desde `SGSPRI` y `SGSSTB` qué puerto de Gmail responde (`465` o `587`) y crear el wallet del correo en las dos VMs (ver `bd/03_base_interna.sql` y el parámetro `CORREO_PUERTO`). En la red de desarrollo el 587 no responde; se usa el 465 | Andrés | Pendiente |
| Tablas que llenan los procesos de B4, B6 y B8 (bitácora y su detalle, detalle de descuentos, premiación, órdenes de compra, cierre diario y su detalle, monitoreo): verificar 5 filas o más al cerrar esas etapas. `SGS_DESTINATARIO` tiene 3: agregar 2 más (otro coordinador y otro DBA) | Isaac | Pendiente |
| Padrón (B5): crear la **misma carpeta** en `SGSPRI` y `SGSSTB` para `PADRON_COMPLETO.txt` y `distelec.txt` (propuesta `/u01/app/oracle/sgs/padron`, dueño `oracle`). Así, después de un switchover o failover, el nuevo principal puede volver a cargar el padrón sin cambiar el directorio de Oracle | Andrés | Pendiente |
| Crear las dos bases con juego de caracteres `AL32UTF8` (los nombres del padrón traen Ñ y tildes) y el principal en `FORCE LOGGING` (Data Guard), para que la carga del padrón llegue completa a la standby | Andrés | Pendiente |
| Espacio para archivos de redo archivados: la carga del padrón (3,7 millones de filas) genera bastante redo de una vez | Andrés | Pendiente |
| `SGS_CIERRE_DIARIO` y `SGS_PREMIACION` tienen 1 fila (las crea el proceso). Para la regla de 5 filas por tabla: generar los cierres de días anteriores con `SGS_PKG_PROCESOS.cerrar_dia(fecha)` y decidir cómo completar las premiaciones (se hace al final, con los datos definitivos) | Isaac | Pendiente |
