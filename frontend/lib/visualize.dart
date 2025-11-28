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
  List<_Para>? content;

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
                  final p = content![index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: RichText(
                      textAlign: p.align,
                      text: TextSpan(children: p.spans),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Para {
  final List<InlineSpan> spans;
  final TextAlign align;
  _Para(this.spans, this.align);
}

List<_Para> _parseDocx(Uint8List bytes) {
  const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const rNs =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
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
  final paras = <_Para>[];
  for (final p in doc.findAllElements('p', namespace: wNs)) {
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
          final rid = _findEmbedRid(node, rNs);
          if (rid != null) {
            final target = rels[rid];
            if (target != null) {
              final path = 'word/$target';
              final imgFile = zip.files.where((f) => f.name == path).toList();
              if (imgFile.isNotEmpty) {
                final data =
                    Uint8List.fromList(imgFile.first.content as List<int>);
                spans.add(WidgetSpan(
                  alignment: ui.PlaceholderAlignment.aboveBaseline,
                  child: Image.memory(data, height: 20),
                ));
              }
            }
          }
        } else if (node.name.namespaceUri == wNs && node.name.local == 'tbl') {
          spans.add(TextSpan(text: '\n'));
        }
      }
    }
    paras.add(_Para(spans, align));
  }
  return paras;
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

String? _findEmbedRid(XmlElement drawing, String rNs) {
  for (final el in drawing.descendants.whereType<XmlElement>()) {
    if (el.name.local == 'blip') {
      final rid = el.getAttribute('embed', namespace: rNs);
      if (rid != null) return rid;
    }
  }
  return null;
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
