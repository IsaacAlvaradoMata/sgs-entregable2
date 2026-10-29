# S4 — Administración parametrizada del standby

El standby se administra solo con los valores de `SGS_ADMIN.SGS_PARAMETRO`: cambiar un valor en la tabla cambia el comportamiento sin tocar código. Capturas en [`capturas/s4_standby/`](capturas/s4_standby/).

Estado: **S4 completo.** Los tres procesos funcionan con `DBMS_SCHEDULER`, a demanda y leyendo los parámetros.

| Parámetro | Valor | Proceso |
|---|---|---|
| `STB_MINUTOS_ARCHIVO` | 5 | Archivo de actualización cada 5 minutos |
| `STB_MB_ARCHIVO` | 50 | … o cada 50 MB |
| `STB_MINUTOS_TRASLADO` | 10 | Traslado a la standby cada 10 minutos y a demanda |
| `STB_DIAS_BORRADO` | 3 | Borrado de archivos ya trasladados y aplicados con más de 3 días |

---

## 1. Esquema

Mismo esquema que el respaldo diario ([`s5_rman.md`](s5_rman.md) §9):

- Los jobs son de `SGS_ADMIN` y están en [`bd/11_standby.sql`](../bd/11_standby.sql). Cada job llama un procedimiento de `SGS_PKG_STANDBY` que **lee el parámetro al ejecutarse** (`SGS_PKG_PARAMETROS.obtener_numero`) y se lo pasa como argumento a un script de Linux.
- El procedimiento crea un job externo de un solo uso con la credencial `SGS_CRED_ORACLE`, lo ejecuta en la misma sesión y lo borra. Si el script termina con error, el job falla (`ORA-27369`) y el error queda en `SGS_BITACORA_ERROR`.
- Los scripts (`servidores/scripts/standby_*.sh`) corren como `oracle`, están instalados igual en `SGSPRI` y `SGSSTB` (`/home/oracle/scripts`) y **solo actúan si su base es la PRIMARY** (código `4` en la standby). Lo que hay que hacer en la otra base lo hacen por SSH, con la llave de `oracle` del S5.
- Cada ejecución deja un log en `/home/oracle/logs` (`archivo_*`, `traslado_*`, `borrado_*`).

Instalación de los scripts (como `oracle`, en los dos servidores):

```
for s in standby_archivo.sh standby_traslado.sh standby_borrado.sh; do
  curl -fsSL -o ~/scripts/$s https://raw.githubusercontent.com/IsaacAlvaradoMata/sgs-entregable2/main/servidores/scripts/$s
  chmod +x ~/scripts/$s
done
```

Instalación de los jobs: `bd/11_standby.sql` en `SGSPDB`, como `SGS_ADMIN` (o SYS dentro de la PDB); pide la clave de Linux de `oracle`.

| Job | Procedimiento | Programación |
|---|---|---|
| `SGS_JOB_STB_ARCHIVO` | `SGS_PKG_STANDBY.aplicar_archivo` | Diario, 00:10 |
| `SGS_JOB_STB_TRASLADO` | `SGS_PKG_STANDBY.trasladar` | Cada `STB_MINUTOS_TRASLADO` minutos |
| `SGS_JOB_STB_BORRADO` | `SGS_PKG_STANDBY.borrar_archivos` | Diario, 00:20 |
| `SGS_JOB_RESPALDO_DIARIO` | (script de respaldo, S5) | Diario a la hora de `RESP_HORA_DIARIO` |

A demanda: `EXEC DBMS_SCHEDULER.RUN_JOB('SGS_ADMIN.<JOB>', use_current_session => TRUE);`

## 2. Archivo cada 5 minutos o 50 MB

Script [`scripts/standby_archivo.sh`](scripts/standby_archivo.sh) `<minutos> <mb>`.

- **Minutos:** se aplican con la propiedad `ArchiveLagTarget` del broker (en segundos) en **las dos** bases, para que valga también después de un switchover. Se cambia con el broker y no con `ALTER SYSTEM` para que `SHOW CONFIGURATION` no marque la propiedad como inconsistente. Cada servidor cambia su propia base con `dgmgrl /` (la otra, por SSH), así que no se guarda la clave de SYS: desde `SGSPRI`, `dgmgrl /` no puede consultar `SGSSTB` (`ORA-01017`), porque para eso el broker necesita usuario y clave.

  ```
  dgmgrl -silent / "EDIT DATABASE 'SGSPRI' SET PROPERTY ArchiveLagTarget=300;"   -- en SGSPRI
  dgmgrl -silent / "EDIT DATABASE 'SGSSTB' SET PROPERTY ArchiveLagTarget=300;"   -- en SGSSTB
  SHOW PARAMETER archive_lag_target                                                -- 300 en las dos
  ```

- **MB:** se cumple con el tamaño de los redo logs (3 grupos de 50 MB, más 4 de standby redo): cada vez que uno se llena se genera un archivo. El script compara `STB_MB_ARCHIVO` con `v$log`; si no coinciden, **avisa al DBA por correo** (`SGS_PKG_CORREO.enviar_a_tipo('DBA', …)`). Rehacer los redo logs con Data Guard activo se hace a mano, en una ventana de mantenimiento.

Pruebas:

| Prueba | Resultado |
|---|---|
| Script en `SGSSTB` | `Resultado: 4` (no hace nada) |
| `standby_archivo.sh 10 50` en `SGSPRI` | `archive_lag_target` = `600` en las dos bases |
| `standby_archivo.sh 5 50` | vuelve a `300` en las dos |
| `standby_archivo.sh 5 40` | log `Redo logs de 50 MB (parámetro: 40 MB)` y correo "SGS: tamaño de los redo logs distinto de STB_MB_ARCHIVO" recibido |
| `SGS_PKG_PARAMETROS.actualizar('STB_MINUTOS_ARCHIVO', '10')` + `RUN_JOB('SGS_JOB_STB_ARCHIVO')` | `600` en las dos bases; con `'5'` vuelve a `300` |

## 3. Traslado cada 10 minutos y a demanda

Script [`scripts/standby_traslado.sh`](scripts/standby_traslado.sh). Con el broker en `ASYNC` el redo viaja a `SGSSTB` de forma continua; el script ejecuta `ALTER SYSTEM ARCHIVE LOG CURRENT`, que cierra el archivo actual y lo envía completo a la standby, donde se aplica. Anota en el log la secuencia enviada.

El procedimiento `trasladar`, después de ejecutar el script, compara `STB_MINUTOS_TRASLADO` con el `repeat_interval` de su job y, si cambió, **se reprograma solo** (`FREQ=MINUTELY;INTERVAL=<n>`).

Pruebas:

| Prueba | Resultado |
|---|---|
| Script en `SGSSTB` | `Resultado: 4` |
| Script en `SGSPRI` | `Secuencia enviada: 59`; en `SGSSTB` la última secuencia aplicada pasó de 57 a 59 |
| Job creado | primera ejecución `SUCCEEDED`; `FREQ=MINUTELY;INTERVAL=10` |
| `actualizar('STB_MINUTOS_TRASLADO', '5')` + `RUN_JOB` | el job queda en `INTERVAL=5`; con `'10'` vuelve a `INTERVAL=10` |

Para mostrarlo en la revisión, en `SGSSTB` antes y después del `RUN_JOB`:

```
SELECT MAX(sequence#) AS ultima_aplicada FROM v$archived_log WHERE applied = 'YES';
```

## 4. Borrado a los 3 días en los dos servidores

Script [`scripts/standby_borrado.sh`](scripts/standby_borrado.sh) `<dias>`. Borra con RMAN `DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-<dias>'` en la principal y, por SSH, en la standby (los jobs no corren en la standby, que está en solo lectura). Anota en el log cuántos archivos de más de N días había antes y después en cada servidor.

Las dos bases tienen la regla de RMAN que impide borrar lo que la standby no aplicó:

```
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;   -- SGSPRI (S5) y SGSSTB
```

En `SGSPRI` solo se borra lo que ya se trasladó y aplicó en la standby; en `SGSSTB`, lo que ya se aplicó.

Pruebas (la base es del 26-oct, así que con 3 días todavía no hay nada que borrar; para la prueba se usó un valor menor, `0.02` días ≈ 30 minutos):

| Prueba | Resultado |
|---|---|
| Script en `SGSSTB` | `Resultado: 4` |
| `standby_borrado.sh 0.02` en `SGSPRI` | `SGSPRI antes=71 después=0`, `SGSSTB antes=77 después=5`, líneas `deleted archived log`, sin avisos `RMAN-08` |
| Respaldo inmediatamente después | `Resultado: 0` (los respaldos quedan al día) |
| `RUN_JOB('SGS_JOB_STB_BORRADO')` | log `archivos de más de 3 días` en los dos servidores, `fin OK` |

Los 5 que quedan en `SGSSTB` son archivos que cumplieron los 30 minutos mientras corría el borrado (el conteo final se hace unos minutos después).
