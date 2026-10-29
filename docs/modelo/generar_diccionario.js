// Genera el diccionario de datos (Word) a partir del catalogo de Oracle del esquema SGS_ADMIN.
// Pasos (desde la raiz del repo, con la libreria docx de npm instalada):
//   1. docker cp docs/modelo/extraer_diccionario.sql oracle_una:/tmp/e.sql
//      docker exec -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 oracle_una bash -c 'sqlplus -s -L "SGS_ADMIN/<clave>@//<servidor>:1521/<servicio>" @/tmp/e.sql'
//      for f in meta cols otros; do docker cp oracle_una:/tmp/$f.txt <carpeta>/$f.txt; done
//   2. awk '/^-- [0-9]+\. /{sec=$0; sub(/^-- [0-9]+\. /,"",sec)} /^CREATE TABLE /{t=$3; sub(/\(.*/,"",t); print "G|" sec "|" t}' bd/02_modelo.sql > <carpeta>/grupos.txt
//   3. node docs/modelo/generar_diccionario.js <carpeta> docs/modelo/logo_una.png docs/modelo/SGS_diccionario_datos.docx
const fs = require('fs');
const path = require('path');
const {
    Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer,
    AlignmentType, HeadingLevel, WidthType, ShadingType, BorderStyle, PageNumber, PageBreak,
    TableOfContents, LevelFormat, VerticalAlign
} = require('docx');

const [, , carpeta, logo, salida] = process.argv;
const leer = (archivo) => fs.readFileSync(path.join(carpeta, archivo), 'utf8').split('\n').map((l) => l.replace(/\r$/, ''));

// Datos del catalogo
const tablas = {};
const columnas = {};
const restricciones = {};
const indices = {};
for (const l of leer('meta.txt')) {
    const p = l.split('|');
    if (p[0] === 'T') tablas[p[1]] = { tablespace: p[2], comentario: p[3] || '' };
    if (p[0] === 'K') (restricciones[p[1]] ||= []).push({ nombre: p[2], tipo: p[3], columnas: p[4], detalle: p.slice(5).join('|') });
    if (p[0] === 'I') (indices[p[1]] ||= []).push({ nombre: p[2], unico: p[3], tablespace: p[4], columnas: p[5] });
}
for (const l of leer('cols.txt')) {
    const p = l.split('|');
    if (p[0] === 'C') (columnas[p[1]] ||= []).push({ nombre: p[3], tipo: p[4], nulos: p[5], defecto: p[6], comentario: p.slice(7).join('|') });
}
const grupos = [];
for (const l of leer('grupos.txt')) {
    const p = l.split('|');
    if (p[0] !== 'G') continue;
    let g = grupos.find((x) => x.clave === p[1]);
    if (!g) grupos.push((g = { clave: p[1], tablas: [] }));
    g.tablas.push(p[2]);
}
const otros = { V: [], M: [], X: [] };
for (const l of leer('otros.txt')) {
    const p = l.split('|');
    if (otros[p[0]]) otros[p[0]].push(p);
}

// Nombre y descripcion de cada grupo funcional
const GRUPOS = {
    'Catalogos base': ['Catálogos base', 'Datos de referencia que usan los demás grupos: países, sucursales (la bodega central es una sucursal marcada), tipo de negocio, usuarios del sistema, familias de producto y tipos de pago.'],
    'Personas': ['Personas', 'Clientes y proveedores, y el padrón nacional del TSE con sus distritos electorales. El cliente nacional se enlaza a su persona del padrón, de donde toma nombre y apellidos.'],
    'Producto': ['Producto', 'Artículos facturables (supertipo de productos y servicios), códigos de barras, configuración de cada producto por sucursal e historial automático de precios de costo.'],
    'Compras y cuentas por pagar': ['Compras y cuentas por pagar', 'Facturas de proveedor con su detalle y sus pagos, y la cuenta por pagar de cada proveedor (límite y saldo total) con el detalle de cada factura a crédito.'],
    'Ventas y cuentas por cobrar': ['Ventas y cuentas por cobrar', 'Facturas de venta con su detalle y sus pagos, y la cuenta por cobrar de cada cliente (límite y saldo total) con el detalle de cada factura a crédito.'],
    'Devoluciones': ['Devoluciones', 'Notas de crédito de venta y de proveedor, con su detalle por línea de la factura que se devuelve.'],
    'Inventario': ['Inventario', 'Lotes que nacen de cada línea de compra, existencia por lote y sucursal, traslados entre sucursales y el movimiento de cada entrada y salida con su documento.'],
    'Promociones y descuentos': ['Promociones y descuentos', 'Tipos de promoción, promociones con sus productos patrocinadores y sus premios, acciones otorgadas a cada factura, y descuentos planeados por familia, proveedor o fecha con su detalle de productos.'],
    'Administracion': ['Administración', 'Parámetros del sistema, destinatarios de las notificaciones, bitácoras de cambios y de errores, cierres diarios, premiaciones con sus órdenes de compra y el registro diario del monitoreo.']
};
const TIPO_RESTRICCION = { P: 'Llave primaria', U: 'Única', R: 'Llave foránea', C: 'Check' };

// Estilo
const FUENTE = 'Times New Roman';
const ROJO = 'A6192E';
const ANCHO = 9360;
const borde = { style: BorderStyle.SINGLE, size: 4, color: 'BFBFBF' };
const bordes = { top: borde, bottom: borde, left: borde, right: borde };

const texto = (t, op = {}) => new TextRun({ text: t, font: FUENTE, ...op });
const parrafo = (t, op = {}) => new Paragraph({ spacing: { after: 120 }, ...op, children: Array.isArray(t) ? t : [texto(t)] });

function celda(t, ancho, op = {}) {
    return new TableCell({
        width: { size: ancho, type: WidthType.DXA },
        borders: bordes,
        verticalAlign: VerticalAlign.CENTER,
        margins: { top: 40, bottom: 40, left: 80, right: 80 },
        shading: op.encabezado ? { fill: ROJO, type: ShadingType.CLEAR, color: 'auto' } : (op.par ? { fill: 'F5F5F5', type: ShadingType.CLEAR, color: 'auto' } : undefined),
        children: [new Paragraph({
            children: [texto(t === '' || t === undefined || t === null ? '—' : String(t), {
                size: 16, bold: !!op.encabezado, color: op.encabezado ? 'FFFFFF' : undefined
            })]
        })]
    });
}

function tabla(encabezados, anchos, filas) {
    return new Table({
        width: { size: ANCHO, type: WidthType.DXA },
        columnWidths: anchos,
        rows: [
            new TableRow({ tableHeader: true, children: encabezados.map((e, i) => celda(e, anchos[i], { encabezado: true })) }),
            ...filas.map((f, n) => new TableRow({ cantSplit: true, children: f.map((v, i) => celda(v, anchos[i], { par: n % 2 === 1 })) }))
        ]
    });
}

const subtitulo = (t) => new Paragraph({ spacing: { before: 160, after: 80 }, keepNext: true, children: [texto(t, { bold: true, size: 20, color: ROJO })] });

// Conteos para la introduccion
const todas = Object.values(restricciones).flat();
const cuenta = (tipo) => todas.filter((r) => r.tipo === tipo).length;
const totalColumnas = Object.values(columnas).reduce((s, c) => s + c.length, 0);
const totalIndices = Object.values(indices).reduce((s, c) => s + c.length, 0);

// Portada
const portada = [
    new Paragraph({ spacing: { before: 600, after: 400 }, alignment: AlignmentType.CENTER, children: [new ImageRun({ type: 'png', data: fs.readFileSync(logo), transformation: { width: 220, height: 175 } })] }),
    parrafo('Universidad Nacional de Costa Rica, Sede Regional Brunca, Campus Pérez Zeledón', { alignment: AlignmentType.CENTER, spacing: { after: 360 } }),
    parrafo('Administración de Bases de Datos (EIF-402)', { alignment: AlignmentType.CENTER, spacing: { after: 360 } }),
    parrafo([texto('Diccionario de Datos', { bold: true, size: 32 })], { alignment: AlignmentType.CENTER, spacing: { after: 80 } }),
    parrafo('Sistema de Gestión de Supermercados (SGS)', { alignment: AlignmentType.CENTER, spacing: { after: 80 } }),
    parrafo('Entregable #2', { alignment: AlignmentType.CENTER, spacing: { after: 600 } }),
    parrafo('Estudiantes:', { alignment: AlignmentType.CENTER, spacing: { after: 40 } }),
    parrafo('Isaac Alvarado Mata', { alignment: AlignmentType.CENTER, spacing: { after: 40 } }),
    parrafo('Andrés Fabián Abarca Rodríguez', { alignment: AlignmentType.CENTER, spacing: { after: 360 } }),
    parrafo('Profesores:', { alignment: AlignmentType.CENTER, spacing: { after: 40 } }),
    parrafo('Hairol Romero y Jeremy Elizondo', { alignment: AlignmentType.CENTER, spacing: { after: 360 } }),
    parrafo('II Ciclo 2026', { alignment: AlignmentType.CENTER })
];

// Introduccion y convenciones
const vinetas = (lista) => lista.map((t) => new Paragraph({ numbering: { reference: 'vinetas', level: 0 }, spacing: { after: 60 }, children: [texto(t)] }));
const introduccion = [
    new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [texto('Introducción')] }),
    parrafo(`Este documento describe las ${Object.keys(tablas).length} tablas del esquema SGS_ADMIN tal como quedaron instaladas en la PDB SGSPDB del servidor principal SGSPRI (Oracle 21c Enterprise Edition), y que se replican a la standby SGSSTB. Se generó directamente del catálogo de la base (USER_TABLES, USER_TAB_COLUMNS, USER_COL_COMMENTS, USER_CONSTRAINTS y USER_INDEXES), así que corresponde exactamente al script bd/02_modelo.sql; las descripciones son los comentarios que cada tabla y columna tiene en la base.`),
    parrafo(`En total son ${totalColumnas} columnas, ${cuenta('P')} llaves primarias, ${cuenta('R')} llaves foráneas, ${cuenta('U')} restricciones de unicidad, ${cuenta('C')} restricciones de validación (CHECK) con nombre y ${totalIndices} índices. Las tablas se agrupan en los mismos ${grupos.length} bloques funcionales del script.`),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Convenciones')] }),
    ...vinetas([
        'Todos los objetos llevan el prefijo SGS_ y cada columna el prefijo corto de su tabla (por ejemplo, PAI_ en SGS_PAIS).',
        'Cada tabla tiene una llave primaria numérica que se alimenta con su secuencia SEQ_<tabla>.',
        'Las restricciones tienen nombre: PK_ (llave primaria), FK_ (llave foránea), UK_ (unicidad) y CK_ (validación). Las de NOT NULL se muestran en la columna «Nulos» de cada tabla.',
        'Estados e indicadores en VARCHAR2(1) con CHECK (por ejemplo, A/I para activo e inactivo, S/N para sí y no). Los porcentajes se guardan como fracción (0.15 = 15 %), en NUMBER(5,4) entre 0 y 1.',
        'Tablespaces: SGS_DATA para las tablas, SGS_IDX para los índices y SGS_AUD para las bitácoras.'
    ]),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Resumen de tablas')] }),
    tabla(['Tabla', 'Grupo', 'Descripción'], [3400, 1800, 4160],
        grupos.flatMap((g) => g.tablas.map((t) => [t, GRUPOS[g.clave][0], tablas[t].comentario])))
];

// Una seccion por grupo y una subseccion por tabla
const cuerpo = [];
for (const g of grupos) {
    const [nombre, descripcion] = GRUPOS[g.clave];
    cuerpo.push(new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [texto(nombre)] }));
    cuerpo.push(parrafo(descripcion));
    for (const t of g.tablas) {
        const cols = columnas[t] || [];
        cuerpo.push(new Paragraph({ heading: HeadingLevel.HEADING_2, keepNext: true, children: [texto(t)] }));
        cuerpo.push(parrafo(tablas[t].comentario));
        cuerpo.push(parrafo([texto('Tablespace: ', { bold: true, size: 20 }), texto(tablas[t].tablespace, { size: 20 }),
            texto('    Columnas: ', { bold: true, size: 20 }), texto(String(cols.length), { size: 20 })]));
        cuerpo.push(tabla(['Columna', 'Tipo', 'Nulos', 'Por defecto', 'Descripción'], [2050, 1550, 650, 1500, 3610],
            cols.map((c) => [c.nombre, c.tipo, c.nulos === 'Y' ? 'Sí' : 'No', c.defecto, c.comentario])));
        const rs = restricciones[t] || [];
        if (rs.length) {
            cuerpo.push(subtitulo('Restricciones'));
            cuerpo.push(tabla(['Nombre', 'Tipo', 'Columnas', 'Detalle'], [2500, 1250, 2200, 3410],
                rs.map((r) => [r.nombre, TIPO_RESTRICCION[r.tipo], r.columnas, r.tipo === 'R' ? 'Referencia a ' + r.detalle : r.detalle])));
        }
        const is = indices[t] || [];
        if (is.length) {
            cuerpo.push(subtitulo('Índices'));
            cuerpo.push(tabla(['Nombre', 'Único', 'Columnas', 'Tablespace'], [3000, 900, 3760, 1700],
                is.map((i) => [i.nombre, i.unico === 'UNIQUE' ? 'Sí' : 'No', i.columnas, i.tablespace])));
        }
    }
}

// Otros objetos del esquema
const DESC_VISTAS = {
    SGS_VW_PRECIO_VENTA: 'Precio de venta calculado por producto y sucursal (costo, utilidad, descuento e impuesto).',
    SGS_VW_BITACORA: 'Encabezado de la bitácora de cambios con el detalle de cada columna modificada.',
    SGS_VW_BITACORA_CRITICA: 'Solo las operaciones críticas de la bitácora, para la gerencia.',
    SGS_VW_CRECIMIENTO: 'Crecimiento de la base entre los registros diarios del monitoreo.',
    SGS_MV_VENTAS_MENSUALES: 'Ventas por mes y sucursal; las devoluciones se cuentan en el mes de la factura que devuelven.',
    SGS_MV_INVENTARIO_CONSOLIDADO: 'Existencia por producto y sucursal, con su valor al costo de compra de cada lote.',
    SGS_EXT_DISTELEC: 'Lee el archivo distelec.txt del TSE (distritos electorales), línea completa.',
    SGS_EXT_PADRON: 'Lee el archivo PADRON_COMPLETO.txt del TSE por posiciones fijas.'
};
const otrosObjetos = [
    new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [texto('Otros objetos del esquema')] }),
    parrafo('Además de las tablas, el esquema tiene vistas para consultar la información ya calculada, las dos vistas materializadas que se refrescan cada día después del cierre y las tablas externas con las que se carga el padrón.'),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Vistas')] }),
    tabla(['Vista', 'Descripción'], [3200, 6160], otros.V.map((v) => [v[1], DESC_VISTAS[v[1]] || v[2]])),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Vistas materializadas')] }),
    tabla(['Vista materializada', 'Refresco', 'Descripción'], [3200, 1700, 4460],
        otros.M.map((m) => [m[1], m[2] === 'COMPLETE DEMAND' ? 'Completo, bajo demanda (job diario 00:30)' : m[2], DESC_VISTAS[m[1]] || ''])),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Tablas externas')] }),
    tabla(['Tabla externa', 'Directorio', 'Descripción'], [3200, 1700, 4460], otros.X.map((x) => [x[1], x[2], DESC_VISTAS[x[1]] || x[3]])),
    new Paragraph({ heading: HeadingLevel.HEADING_2, children: [texto('Secuencias')] }),
    parrafo(`El esquema tiene ${Object.keys(tablas).length} secuencias, una por tabla, con el nombre SEQ_ seguido del nombre de la tabla sin el prefijo (por ejemplo, SEQ_PAIS para SGS_PAIS). Cada una alimenta la llave primaria de su tabla.`)
];

const doc = new Document({
    features: { updateFields: true },
    creator: 'Isaac Alvarado Mata',
    title: 'Diccionario de Datos - SGS',
    styles: {
        default: { document: { run: { font: FUENTE, size: 22 } } },
        paragraphStyles: [
            { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
              run: { size: 30, bold: true, font: FUENTE, color: ROJO }, paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
            { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
              run: { size: 24, bold: true, font: FUENTE }, paragraph: { spacing: { before: 280, after: 80 }, outlineLevel: 1 } }
        ]
    },
    numbering: { config: [{ reference: 'vinetas', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] }] },
    sections: [
        {
            properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
            children: portada
        },
        {
            properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
            headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
                children: [texto('Diccionario de Datos — Sistema de Gestión de Supermercados (SGS)', { size: 16, color: '808080' })] })] }) },
            footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
                children: [texto('Página ', { size: 16 }), new TextRun({ children: [PageNumber.CURRENT], font: FUENTE, size: 16 }),
                    texto(' de ', { size: 16 }), new TextRun({ children: [PageNumber.TOTAL_PAGES], font: FUENTE, size: 16 })] })] }) },
            children: [
                new Paragraph({ spacing: { after: 160 }, children: [texto('Índice', { bold: true, size: 30, color: ROJO })] }),
                new TableOfContents('Índice', { hyperlink: true, headingStyleRange: '1-2' }),
                ...introduccion,
                ...cuerpo,
                ...otrosObjetos
            ]
        }
    ]
});

Packer.toBuffer(doc).then((buffer) => {
    fs.writeFileSync(salida, buffer);
    console.log('Diccionario generado: ' + salida);
});
