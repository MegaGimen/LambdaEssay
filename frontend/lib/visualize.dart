import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:html' as html;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

class VisualizeDocxPage extends StatefulWidget {
  const VisualizeDocxPage({super.key});
  @override
  State<VisualizeDocxPage> createState() => _VisualizeDocxPageState();
}

class _VisualizeDocxPageState extends State<VisualizeDocxPage> {
  bool loading = false;
  String? error;
  String? fileName;
  List<_Block>? content;

  Future<void> _pickAndParse() async {
    if (!kIsWeb) {
      setState(() => error = '仅支持 Web 环境');
      return;
    }
    final input = html.FileUploadInputElement();
    input.accept = '.docx';
    input.click();
    await input.onChange.first;
    final file = input.files?.isNotEmpty == true ? input.files!.first : null;
    if (file == null) return;
    fileName = file.name;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    final result = reader.result;
    Uint8List bytes;
    if (result is ByteBuffer) {
      bytes = Uint8List.view(result);
    } else if (result is Uint8List) {
      bytes = result;
    } else if (result is List<int>) {
      bytes = Uint8List.fromList(result);
    } else {
      throw Exception('不支持的文件读取结果类型');
    }
    setState(() {
      loading = true;
      error = null;
      content = null;
    });
    try {
      final paras = _parseDocx(bytes);
      setState(() {
        content = paras;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DOCX 解析预览')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: loading ? null : _pickAndParse,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('选择 DOCX 文件'),
                ),
                const SizedBox(width: 12),
                if (fileName != null) Text(fileName!),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          if (loading)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (content == null)
            const Expanded(
              child: Center(child: Text('请选择 DOCX 文件进行解析')),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: content!.length,
                itemBuilder: (context, index) {
                  final b = content![index];
                  switch (b.type) {
                    case _BlockType.para:
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: RichText(
                          textAlign: b.align ?? TextAlign.left,
                          text: TextSpan(children: b.spans ?? const []),
                        ),
                      );
                    case _BlockType.divider:
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(height: 1, thickness: 1),
                      );
                    case _BlockType.table:
                      return _TableView(block: b);
                    case _BlockType.header:
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children:
                            b.children?.map((e) => _renderChild(e)).toList() ??
                                const [],
                      );
                    case _BlockType.footer:
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children:
                            b.children?.map((e) => _renderChild(e)).toList() ??
                                const [],
                      );
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderChild(_Block b) {
    switch (b.type) {
      case _BlockType.para:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: RichText(
            textAlign: b.align ?? TextAlign.left,
            text: TextSpan(children: b.spans ?? const []),
          ),
        );
      case _BlockType.divider:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, thickness: 1),
        );
      case _BlockType.table:
        return _TableView(block: b);
      case _BlockType.header:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:
              b.children?.map((e) => _renderChild(e)).toList() ?? const [],
        );
      case _BlockType.footer:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:
              b.children?.map((e) => _renderChild(e)).toList() ?? const [],
        );
    }
  }
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _Para {
  final List<InlineSpan> spans;
  final TextAlign align;
  _Para(this.spans, this.align);
}

enum _BlockType { para, divider, table, header, footer }

class _Block {
  final _BlockType type;
  final List<InlineSpan>? spans;
  final TextAlign? align;
  final List<List<_Para>>? tableRows;
  final List<_Block>? children;
  _Block({
    required this.type,
    this.spans,
    this.align,
    this.tableRows,
    this.children,
  });
}

class _TableView extends StatelessWidget {
  final _Block block;
  const _TableView({required this.block});
  @override
  Widget build(BuildContext context) {
    final rows = block.tableRows ?? const <List<_Para>>[];
    final colCount = rows.isNotEmpty
        ? rows.map((r) => r.length).reduce((a, b) => a > b ? a : b)
        : 0;
    final widths = <int, TableColumnWidth>{};
    for (var i = 0; i < colCount; i++) {
      widths[i] = const FlexColumnWidth();
    }
    return Container(
      decoration:
          BoxDecoration(border: Border.all(color: const Color(0xFF444444))),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        columnWidths: widths,
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          for (final row in rows)
            TableRow(
              children: [
                for (final cell in row)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: RichText(
                      textAlign: cell.align,
                      text: TextSpan(children: cell.spans),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

List<_Block> _parseDocx(Uint8List bytes) {
  const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const rNs =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  const aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  const wpNs =
      'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  const wpsNs =
      'http://schemas.microsoft.com/office/word/2010/wordprocessingShape';
  const vNs = 'urn:schemas-microsoft-com:vml';
  final zip = ZipDecoder().decodeBytes(bytes);
  final docFile = zip.files.firstWhere(
    (f) => f.name == 'word/document.xml',
    orElse: () => throw Exception('缺少 word/document.xml'),
  );
  final xmlStr = utf8.decode(docFile.content as List<int>);
  final doc = XmlDocument.parse(xmlStr);
  final rels = <String, String>{};
  final relFile =
      zip.files.where((f) => f.name == 'word/_rels/document.xml.rels').toList();
  if (relFile.isNotEmpty) {
    final relStr = utf8.decode(relFile.first.content as List<int>);
    final relDoc = XmlDocument.parse(relStr);
    for (final rel in relDoc.findAllElements('Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id != null && target != null) rels[id] = target;
    }
  }
  final blocks = <_Block>[];
  final body = doc.findAllElements('body', namespace: wNs).first;
  for (final el in body.children.whereType<XmlElement>()) {
    if (el.name.namespaceUri == wNs && el.name.local == 'p') {
      final para =
          _parseParagraph(el, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
      blocks.add(
          _Block(type: _BlockType.para, spans: para.spans, align: para.align));
      final pPr = el.getElement('pPr', namespace: wNs);
      final pBdr = pPr?.getElement('pBdr', namespace: wNs);
      if (pBdr?.getElement('bottom', namespace: wNs) != null) {
        blocks.add(_Block(type: _BlockType.divider));
      }
    } else if (el.name.namespaceUri == wNs && el.name.local == 'tbl') {
      final table = _parseTable(el, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
      blocks.add(_Block(type: _BlockType.table, tableRows: table));
    }
  }
  final sectPr = body.getElement('sectPr', namespace: wNs);
  if (sectPr != null) {
    final headerRefs =
        sectPr.findElements('headerReference', namespace: wNs).toList();
    XmlElement? headerRef = headerRefs
        .where((e) => e.getAttribute('type', namespace: wNs) == 'default')
        .firstOrNull;
    headerRef ??= headerRefs.isNotEmpty ? headerRefs.first : null;
    if (headerRef != null) {
      final rid = headerRef.getAttribute('id', namespace: rNs);
      if (rid != null && rels[rid] != null) {
        final path = 'word/${rels[rid]!}';
        final hf = zip.files.where((f) => f.name == path).toList();
        if (hf.isNotEmpty) {
          final hdrDoc =
              XmlDocument.parse(utf8.decode(hf.first.content as List<int>));
          final hs = _parseContainerBlocks(
              hdrDoc.rootElement, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
          blocks.insert(0, _Block(type: _BlockType.header, children: hs));
        }
      }
    }
    final footerRefs =
        sectPr.findElements('footerReference', namespace: wNs).toList();
    XmlElement? footerRef = footerRefs
        .where((e) => e.getAttribute('type', namespace: wNs) == 'default')
        .firstOrNull;
    footerRef ??= footerRefs.isNotEmpty ? footerRefs.first : null;
    if (footerRef != null) {
      final rid = footerRef.getAttribute('id', namespace: rNs);
      if (rid != null && rels[rid] != null) {
        final path = 'word/${rels[rid]!}';
        final ff = zip.files.where((f) => f.name == path).toList();
        if (ff.isNotEmpty) {
          final ftrDoc =
              XmlDocument.parse(utf8.decode(ff.first.content as List<int>));
          final fs = _parseContainerBlocks(
              ftrDoc.rootElement, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
          blocks.add(_Block(type: _BlockType.footer, children: fs));
        }
      }
    }
  }
  return blocks;
}

List<InlineSpan> _parseRun(XmlElement r, String wNs) {
  final spans = <InlineSpan>[];
  final rPr = r.getElement('rPr', namespace: wNs);
  final bold = rPr?.getElement('b', namespace: wNs) != null;
  final italic = rPr?.getElement('i', namespace: wNs) != null;
  final uVal =
      rPr?.getElement('u', namespace: wNs)?.getAttribute('val', namespace: wNs);
  final strike = rPr?.getElement('strike', namespace: wNs) != null;
  final colorVal = rPr
      ?.getElement('color', namespace: wNs)
      ?.getAttribute('val', namespace: wNs);
  final highlightVal = rPr
      ?.getElement('highlight', namespace: wNs)
      ?.getAttribute('val', namespace: wNs);
  final szVal = rPr
      ?.getElement('sz', namespace: wNs)
      ?.getAttribute('val', namespace: wNs);
  double? fontSize;
  if (szVal != null) {
    final n = int.tryParse(szVal);
    if (n != null) fontSize = n / 2.0;
  }
  var decoration = TextDecoration.none;
  if (uVal != null && uVal != 'none') decoration = TextDecoration.underline;
  if (strike)
    decoration =
        TextDecoration.combine([decoration, TextDecoration.lineThrough]);
  Color? color;
  if (colorVal != null && colorVal.toLowerCase() != 'auto') {
    color = _parseColor(colorVal);
  }
  Color? bgColor;
  if (highlightVal != null) bgColor = _parseHighlight(highlightVal);
  final style = TextStyle(
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    decoration: decoration,
    color: color,
    backgroundColor: bgColor,
    fontSize: fontSize,
  );
  for (final child in r.children) {
    if (child is XmlElement && child.name.local == 't') {
      final txt = child.innerText;
      spans.add(TextSpan(text: txt, style: style));
    } else if (child is XmlElement && child.name.local == 'tab') {
      spans.add(TextSpan(text: '\t', style: style));
    } else if (child is XmlElement && child.name.local == 'br') {
      spans.add(TextSpan(text: '\n', style: style));
    }
  }
  return spans;
}

_Para _parseParagraph(
  XmlElement p,
  String wNs,
  String rNs,
  Archive zip,
  Map<String, String> rels,
  String aNs,
  String wpNs,
  String wpsNs,
  String vNs,
) {
  final spans = <InlineSpan>[];
  var align = TextAlign.left;
  final pPr = p.getElement('pPr', namespace: wNs);
  final jc = pPr
      ?.getElement('jc', namespace: wNs)
      ?.getAttribute('val', namespace: wNs);
  if (jc == 'center') align = TextAlign.center;
  if (jc == 'right') align = TextAlign.right;
  if (jc == 'both') align = TextAlign.justify;
  for (final node in p.children) {
    if (node is XmlElement) {
      if (node.name.namespaceUri == wNs && node.name.local == 'r') {
        spans.addAll(_parseRun(node, wNs));
      } else if (node.name.namespaceUri == wNs &&
          node.name.local == 'hyperlink') {
        for (final rn in node.findElements('r', namespace: wNs)) {
          spans.addAll(_parseRun(rn, wNs));
        }
      } else if (node.name.local == 'drawing') {
        final inline = node.findElements('inline', namespace: wpNs).firstOrNull;
        final anchor = node.findElements('anchor', namespace: wpNs).firstOrNull;
        if (inline != null) {
          final blip =
              inline.findAllElements('blip', namespace: aNs).firstOrNull;
          final rid = blip?.getAttribute('embed', namespace: rNs);
          final extent = inline.getElement('extent', namespace: wpNs);
          double? w;
          double? h;
          if (extent != null) {
            final cx = extent.getAttribute('cx');
            final cy = extent.getAttribute('cy');
            final wx = cx != null ? _emuToPx(int.tryParse(cx)) : null;
            final hy = cy != null ? _emuToPx(int.tryParse(cy)) : null;
            w = wx;
            h = hy;
          }
          if (rid != null && rels[rid] != null) {
            final path = 'word/${rels[rid]!}';
            final imgFile = zip.files.where((f) => f.name == path).firstOrNull;
            if (imgFile != null) {
              final data = Uint8List.fromList(imgFile.content as List<int>);
              spans.add(WidgetSpan(
                alignment: ui.PlaceholderAlignment.aboveBaseline,
                child: Image.memory(data,
                    width: w, height: h, fit: BoxFit.contain),
              ));
            }
          }
        } else if (anchor != null) {
          final txbx = anchor
              .findAllElements('graphicData', namespace: aNs)
              .expand((g) => g.findAllElements('wsp', namespace: wpsNs))
              .expand((wsp) => wsp.findAllElements('txbx', namespace: wpsNs))
              .firstOrNull;
          if (txbx != null) {
            final content =
                txbx.findAllElements('txbxContent', namespace: wNs).firstOrNull;
            if (content != null) {
              final paras = _parseContainerBlocks(
                      content, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs)
                  .where((b) => b.type == _BlockType.para)
                  .map((b) =>
                      _Para(b.spans ?? const [], b.align ?? TextAlign.left))
                  .toList();
              spans.add(WidgetSpan(
                child: Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF777777))),
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final p in paras)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: RichText(
                              textAlign: p.align,
                              text: TextSpan(children: p.spans)),
                        ),
                    ],
                  ),
                ),
              ));
            }
          } else {
            final blip =
                anchor.findAllElements('blip', namespace: aNs).firstOrNull;
            final rid = blip?.getAttribute('embed', namespace: rNs);
            final extent = anchor.getElement('extent', namespace: wpNs);
            double? w;
            double? h;
            if (extent != null) {
              final cx = extent.getAttribute('cx');
              final cy = extent.getAttribute('cy');
              w = cx != null ? _emuToPx(int.tryParse(cx)) : null;
              h = cy != null ? _emuToPx(int.tryParse(cy)) : null;
            }
            if (rid != null && rels[rid] != null) {
              final path = 'word/${rels[rid]!}';
              final imgFile =
                  zip.files.where((f) => f.name == path).firstOrNull;
              if (imgFile != null) {
                final data = Uint8List.fromList(imgFile.content as List<int>);
                spans.add(WidgetSpan(
                    child: Image.memory(data,
                        width: w, height: h, fit: BoxFit.contain)));
              }
            }
          }
        } else {
          final vTextBox = node
              .findAllElements('pict', namespace: wNs)
              .expand((pict) => pict.findAllElements('shape', namespace: vNs))
              .expand((sh) => sh.findAllElements('textbox', namespace: vNs))
              .firstOrNull;
          if (vTextBox != null) {
            final content = vTextBox
                .findAllElements('txbxContent', namespace: wNs)
                .firstOrNull;
            if (content != null) {
              final paras = _parseContainerBlocks(
                      content, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs)
                  .where((b) => b.type == _BlockType.para)
                  .map((b) =>
                      _Para(b.spans ?? const [], b.align ?? TextAlign.left))
                  .toList();
              spans.add(WidgetSpan(
                child: Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF777777))),
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final p in paras)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: RichText(
                              textAlign: p.align,
                              text: TextSpan(children: p.spans)),
                        ),
                    ],
                  ),
                ),
              ));
            }
          }
        }
      } else if (node.name.namespaceUri == wNs && node.name.local == 'tbl') {
        spans.add(TextSpan(text: '\n'));
      }
    }
  }
  return _Para(spans, align);
}

List<List<_Para>> _parseTable(
  XmlElement tbl,
  String wNs,
  String rNs,
  Archive zip,
  Map<String, String> rels,
  String aNs,
  String wpNs,
  String wpsNs,
  String vNs,
) {
  final rows = <List<_Para>>[];
  for (final tr in tbl.findAllElements('tr', namespace: wNs)) {
    final cells = <_Para>[];
    for (final tc in tr.findAllElements('tc', namespace: wNs)) {
      final merged = <InlineSpan>[];
      var align = TextAlign.left;
      for (final p in tc.findAllElements('p', namespace: wNs)) {
        final parsed =
            _parseParagraph(p, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
        merged.addAll(parsed.spans);
        merged.add(const TextSpan(text: '\n'));
        align = parsed.align;
      }
      cells.add(_Para(merged, align));
    }
    rows.add(cells);
  }
  return rows;
}

List<_Block> _parseContainerBlocks(
  XmlElement container,
  String wNs,
  String rNs,
  Archive zip,
  Map<String, String> rels,
  String aNs,
  String wpNs,
  String wpsNs,
  String vNs,
) {
  final list = <_Block>[];
  for (final el in container.children.whereType<XmlElement>()) {
    if (el.name.namespaceUri == wNs && el.name.local == 'p') {
      final para =
          _parseParagraph(el, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
      list.add(
          _Block(type: _BlockType.para, spans: para.spans, align: para.align));
    } else if (el.name.namespaceUri == wNs && el.name.local == 'tbl') {
      final table = _parseTable(el, wNs, rNs, zip, rels, aNs, wpNs, wpsNs, vNs);
      list.add(_Block(type: _BlockType.table, tableRows: table));
    }
  }
  return list;
}

double? _emuToPx(int? emu) {
  if (emu == null) return null;
  return emu / 9525.0;
}

Color? _parseColor(String val) {
  final v = val.trim();
  if (v.length == 6) {
    final n = int.tryParse(v, radix: 16);
    if (n != null) return Color(0xFF000000 | n);
  }
  switch (v.toLowerCase()) {
    case 'yellow':
      return const Color(0xFFFFFF00);
    case 'green':
      return const Color(0xFF00FF00);
    case 'cyan':
      return const Color(0xFF00FFFF);
    case 'magenta':
      return const Color(0xFFFF00FF);
    case 'blue':
      return const Color(0xFF0000FF);
    case 'red':
      return const Color(0xFFFF0000);
    case 'black':
      return const Color(0xFF000000);
    case 'white':
      return const Color(0xFFFFFFFF);
    case 'darkblue':
      return const Color(0xFF00008B);
    case 'darkcyan':
      return const Color(0xFF008B8B);
    case 'darkmagenta':
      return const Color(0xFF8B008B);
    case 'darkred':
      return const Color(0xFF8B0000);
    case 'darkyellow':
      return const Color(0xFFB5B500);
    case 'darkgray':
      return const Color(0xFFA9A9A9);
    case 'lightgray':
      return const Color(0xFFD3D3D3);
  }
  return null;
}

Color? _parseHighlight(String val) {
  switch (val.toLowerCase()) {
    case 'yellow':
      return const Color(0xFFFFFF00);
    case 'green':
      return const Color(0xFF92D050);
    case 'cyan':
      return const Color(0xFF00FFFF);
    case 'magenta':
      return const Color(0xFFFF00FF);
    case 'blue':
      return const Color(0xFF00B0F0);
    case 'red':
      return const Color(0xFFFF0000);
    case 'black':
      return const Color(0xFF000000);
    case 'white':
      return const Color(0xFFFFFFFF);
    case 'darkblue':
      return const Color(0xFF00008B);
    case 'darkcyan':
      return const Color(0xFF008B8B);
    case 'darkmagenta':
      return const Color(0xFF8B008B);
    case 'darkred':
      return const Color(0xFF8B0000);
    case 'darkyellow':
      return const Color(0xFFB5B500);
    case 'darkgray':
      return const Color(0xFFA9A9A9);
    case 'lightgray':
      return const Color(0xFFD3D3D3);
    case 'none':
      return null;
  }
  if (val.length == 6) {
    final n = int.tryParse(val, radix: 16);
    if (n != null) return Color(0xFF000000 | n);
  }
  return null;
}

void main() {
  runApp(const MaterialApp(home: VisualizeDocxPage()));
}
