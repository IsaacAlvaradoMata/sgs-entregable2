// Convierte un manual escrito en Markdown a Word con el estilo de los documentos del proyecto.
// Soporta: portada (bloque inicial entre lineas ---), # ## ### titulos, parrafos, **negrita**, `codigo`,
// listas con - (dos niveles) y 1., bloques ``` de codigo, tablas |, notas con >, imagenes ![pie](ruta) y <<<SALTO>>>.
// Las rutas de las imagenes son relativas a la raiz del repo.
// Uso (desde la raiz del repo, con la libreria docx de npm): node docs/manuales/md_a_docx.js <manual.md> <salida.docx>
const fs = require('fs');
const path = require('path');
const {
    Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer,
    AlignmentType, HeadingLevel, WidthType, ShadingType, BorderStyle, PageNumber, TableOfContents,
    LevelFormat, VerticalAlign
} = require('docx');

const [, , entrada, salida] = process.argv;
const raiz = process.cwd();
const lineas = fs.readFileSync(entrada, 'utf8').replace(/\r/g, '').split('\n');

const FUENTE = 'Times New Roman';
const MONO = 'Courier New';
const ROJO = 'A6192E';
const ANCHO = 9360;
const borde = { style: BorderStyle.SINGLE, size: 4, color: 'BFBFBF' };
const bordes = { top: borde, bottom: borde, left: borde, right: borde };

// Texto con **negrita** y `codigo`
function runs(texto, base = {}) {
    const partes = texto.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter((p) => p !== '');
    return partes.map((p) => {
        if (p.startsWith('**') && p.endsWith('**')) return new TextRun({ text: p.slice(2, -2), font: FUENTE, bold: true, ...base });
        if (p.startsWith('`') && p.endsWith('`')) return new TextRun({ text: p.slice(1, -1), font: MONO, size: base.size ? base.size - 2 : 20, ...base, ...{ font: MONO } });
        return new TextRun({ text: p, font: FUENTE, ...base });
    });
}

// Tamano de una imagen PNG o JPEG
function dimensiones(buf) {
    if (buf[0] === 0x89 && buf[1] === 0x50) return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), tipo: 'png' };
    let i = 2;
    while (i < buf.length) {
        if (buf[i] !== 0xff) { i++; continue; }
        const m = buf[i + 1];
        if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { h: buf.readUInt16BE(i + 5), w: buf.readUInt16BE(i + 7), tipo: 'jpg' };
        i += 2 + buf.readUInt16BE(i + 2);
    }
    throw new Error('Imagen no reconocida');
}

function celda(t, ancho, op = {}) {
    return new TableCell({
        width: { size: ancho, type: WidthType.DXA },
        borders: bordes,
        verticalAlign: VerticalAlign.CENTER,
        margins: { top: 40, bottom: 40, left: 80, right: 80 },
        shading: op.encabezado ? { fill: ROJO, type: ShadingType.CLEAR, color: 'auto' } : (op.par ? { fill: 'F5F5F5', type: ShadingType.CLEAR, color: 'auto' } : undefined),
        children: [new Paragraph({ children: runs(t, { size: 18, bold: op.encabezado ? true : undefined, color: op.encabezado ? 'FFFFFF' : undefined }) })]
    });
}

function tabla(filas) {
    const n = filas[0].length;
    // Ancho de cada columna segun el texto mas largo (con minimo), ajustado al ancho de la pagina
    const largos = Array.from({ length: n }, (_, c) => Math.max(9, filas[0][c].length + 3, ...filas.map((f) => Math.min((f[c] || '').length, 60))));
    const total = largos.reduce((a, b) => a + b, 0);
    const anchos = largos.map((l) => Math.floor((l / total) * ANCHO));
    anchos[n - 1] += ANCHO - anchos.reduce((a, b) => a + b, 0);
    return new Table({
        width: { size: ANCHO, type: WidthType.DXA },
        columnWidths: anchos,
        rows: filas.map((f, i) => new TableRow({
            tableHeader: i === 0, cantSplit: true,
            children: f.map((v, c) => celda(v, anchos[c], { encabezado: i === 0, par: i > 0 && i % 2 === 0 }))
        }))
    });
}

const doc = [];
let portada = {};
let figura = 0;
let instancia = 0;
let ultimaNumerada = 0;
let primerH1 = true;
let i = 0;

// Portada: bloque inicial entre lineas ---
if (lineas[0] === '---') {
    i = 1;
    while (lineas[i] !== '---') {
        const [k, ...v] = lineas[i].split(':');
        portada[k.trim()] = v.join(':').trim();
        i++;
    }
    i++;
}

while (i < lineas.length) {
    const l = lineas[i];
    if (l.trim() === '') { i++; continue; }

    if (l.trim() === '<<<SALTO>>>') { doc.push(new Paragraph({ pageBreakBefore: true, children: [] })); i++; continue; }

    const h = l.match(/^(#{1,3}) (.*)$/);
    if (h) {
        const nivel = h[1].length;
        const heading = [HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3][nivel - 1];
        doc.push(new Paragraph({ heading, keepNext: true, pageBreakBefore: nivel === 1 && !primerH1, children: runs(h[2]) }));
        if (nivel === 1) primerH1 = false;
        i++; continue;
    }

    if (l.startsWith('```')) {
        const codigo = [];
        i++;
        while (i < lineas.length && !lineas[i].startsWith('```')) codigo.push(lineas[i++]);
        i++;
        codigo.forEach((c, k) => doc.push(new Paragraph({
            keepNext: k < codigo.length - 1 && codigo.length < 25,
            spacing: { before: k === 0 ? 80 : 0, after: k === codigo.length - 1 ? 160 : 0 },
            shading: { fill: 'F2F2F2', type: ShadingType.CLEAR, color: 'auto' },
            indent: { left: 120, right: 120 },
            children: [new TextRun({ text: c === '' ? ' ' : c, font: MONO, size: 16 })]
        })));
        continue;
    }

    if (l.startsWith('|')) {
        const filas = [];
        while (i < lineas.length && lineas[i].startsWith('|')) {
            const celdas = lineas[i].trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
            if (!celdas.every((c) => /^:?-+:?$/.test(c))) filas.push(celdas);
            i++;
        }
        doc.push(tabla(filas));
        doc.push(new Paragraph({ spacing: { after: 120 }, children: [] }));
        continue;
    }

    const img = l.match(/^!\[(.*)\]\((.*)\)$/);
    if (img) {
        const buf = fs.readFileSync(path.join(raiz, img[2]));
        const d = dimensiones(buf);
        const escala = Math.min(1, 560 / d.w, 520 / d.h);
        figura++;
        doc.push(new Paragraph({ alignment: AlignmentType.CENTER, keepNext: true, spacing: { before: 120 },
            children: [new ImageRun({ type: d.tipo, data: buf, transformation: { width: Math.round(d.w * escala), height: Math.round(d.h * escala) } })] }));
        doc.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 },
            children: runs(`Figura ${figura}. ${img[1]}`, { size: 18, italics: true, color: '595959' }) }));
        i++; continue;
    }

    if (l.startsWith('> ')) {
        const texto = [];
        while (i < lineas.length && lineas[i].startsWith('> ')) texto.push(lineas[i++].slice(2));
        doc.push(new Paragraph({
            spacing: { before: 80, after: 160 },
            border: { left: { style: BorderStyle.SINGLE, size: 18, color: ROJO, space: 8 } },
            shading: { fill: 'FBEFF1', type: ShadingType.CLEAR, color: 'auto' },
            indent: { left: 240 },
            children: runs(texto.join(' '), { size: 20 })
        }));
        continue;
    }

    const vin = l.match(/^( *)- (.*)$/);
    const num = l.match(/^( *)\d+\. (.*)$/);
    if (vin || num) {
        // Una lista numerada que no empieza en 1 sigue la anterior (por ejemplo, despues de un bloque de codigo)
        const sigue = num && !l.match(/^ *1\. /) && ultimaNumerada > 0;
        if (!sigue) instancia++;
        if (num) ultimaNumerada = sigue ? ultimaNumerada : instancia;
        while (i < lineas.length) {
            const v = lineas[i].match(/^( *)- (.*)$/);
            const n = lineas[i].match(/^( *)\d+\. (.*)$/);
            if (!v && !n) break;
            const m = v || n;
            const nivel = m[1].length >= 2 ? 1 : 0;
            doc.push(new Paragraph({
                numbering: { reference: n ? 'numeros' : 'vinetas', level: nivel, instance: n ? ultimaNumerada : undefined },
                spacing: { after: 60 }, children: runs(m[2])
            }));
            i++;
        }
        doc.push(new Paragraph({ spacing: { after: 60 }, children: [] }));
        continue;
    }

    // Parrafo: lineas seguidas hasta una linea vacia o un elemento distinto
    const texto = [];
    while (i < lineas.length && lineas[i].trim() !== '' && !/^(#{1,3} |```|\||!\[|> |( *)- |( *)\d+\. |<<<SALTO>>>)/.test(lineas[i])) texto.push(lineas[i++].trim());
    doc.push(new Paragraph({ spacing: { after: 120 }, children: runs(texto.join(' ')) }));
}

// Portada con el logo de la UNA
const centrado = (t, op = {}, despues = 120) => new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: despues }, children: [new TextRun({ text: t, font: FUENTE, ...op })] });
const logo = fs.readFileSync(path.join(raiz, 'docs/modelo/logo_una.png'));
const hojaPortada = [
    new Paragraph({ spacing: { before: 600, after: 400 }, alignment: AlignmentType.CENTER, children: [new ImageRun({ type: 'png', data: logo, transformation: { width: 220, height: 175 } })] }),
    centrado('Universidad Nacional de Costa Rica, Sede Regional Brunca, Campus Pérez Zeledón', {}, 360),
    centrado('Administración de Bases de Datos (EIF-402)', {}, 360),
    centrado(portada.titulo, { bold: true, size: 32 }, 80),
    centrado('Sistema de Gestión de Supermercados (SGS)', {}, 80),
    centrado('Entregable #2', {}, 600),
    centrado('Estudiantes:', {}, 40),
    centrado('Isaac Alvarado Mata', {}, 40),
    centrado('Andrés Fabián Abarca Rodríguez', {}, 360),
    centrado('Profesores:', {}, 40),
    centrado('Hairol Romero y Jeremy Elizondo', {}, 360),
    centrado('II Ciclo 2026')
];

const pagina = { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } };
const documento = new Document({
    features: { updateFields: true },
    creator: 'Isaac Alvarado Mata',
    title: portada.titulo,
    styles: {
        default: { document: { run: { font: FUENTE, size: 22 } } },
        paragraphStyles: [
            { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
              run: { size: 30, bold: true, font: FUENTE, color: ROJO }, paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
            { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
              run: { size: 25, bold: true, font: FUENTE }, paragraph: { spacing: { before: 280, after: 100 }, outlineLevel: 1 } },
            { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
              run: { size: 22, bold: true, font: FUENTE, color: ROJO }, paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 2 } }
        ]
    },
    numbering: { config: [
        { reference: 'vinetas', levels: [
            { level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 720, hanging: 360 } } } },
            { level: 1, format: LevelFormat.BULLET, text: '–', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 1440, hanging: 360 } } } }] },
        { reference: 'numeros', levels: [
            { level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 720, hanging: 360 } } } },
            { level: 1, format: LevelFormat.LOWER_LETTER, text: '%2)', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 1440, hanging: 360 } } } }] }
    ] },
    sections: [
        { properties: { page: pagina }, children: hojaPortada },
        {
            properties: { page: pagina },
            headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
                children: [new TextRun({ text: `${portada.titulo} — Sistema de Gestión de Supermercados (SGS)`, font: FUENTE, size: 16, color: '808080' })] })] }) },
            footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
                new TextRun({ text: 'Página ', font: FUENTE, size: 16 }), new TextRun({ children: [PageNumber.CURRENT], font: FUENTE, size: 16 }),
                new TextRun({ text: ' de ', font: FUENTE, size: 16 }), new TextRun({ children: [PageNumber.TOTAL_PAGES], font: FUENTE, size: 16 })] })] }) },
            children: [
                new Paragraph({ spacing: { after: 160 }, children: [new TextRun({ text: 'Índice', font: FUENTE, bold: true, size: 30, color: ROJO })] }),
                new TableOfContents('Índice', { hyperlink: true, headingStyleRange: '1-2' }),
                new Paragraph({ pageBreakBefore: true, children: [] }),
                ...doc
            ]
        }
    ]
});

Packer.toBuffer(documento).then((b) => { fs.writeFileSync(salida, b); console.log('Generado: ' + salida + ' (' + figura + ' figuras)'); });
