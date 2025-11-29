import 'dart:typed_data';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'web_view_registry.dart' as wvr;

class VisualizeDocxPage extends StatefulWidget {
  const VisualizeDocxPage({super.key});
  @override
  State<VisualizeDocxPage> createState() => _VisualizeDocxPageState();
}

class _VisualizeDocxPageState extends State<VisualizeDocxPage> {
  bool loading = false;
  String? error;
  String? fileName;
  String? _pdfObjectUrl;
  html.IFrameElement? _iframe;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      wvr.registerPdfViewFactory('pdf-view', (int viewId) {
        final iframe = html.IFrameElement();
        iframe.style.border = 'none';
        iframe.style.width = '100%';
        iframe.style.height = '100%';
        if (_pdfObjectUrl != null) iframe.src = _pdfObjectUrl!;
        _iframe = iframe;
        return iframe;
      });
    }
  }

  @override
  void dispose() {
    if (_pdfObjectUrl != null) {
      html.Url.revokeObjectUrl(_pdfObjectUrl!);
      _pdfObjectUrl = null;
    }
    super.dispose();
  }

  Future<void> _pickDocxAndConvert() async {
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
    setState(() {
      loading = true;
      error = null;
      fileName = file.name;
    });
    final form = html.FormData();
    form.appendBlob('file', file, file.name);
    form.append('to', 'pdf');
    final xhr = html.HttpRequest();
    xhr.open('POST', 'http://localhost:8080/convert', async: true);
    xhr.responseType = 'arraybuffer';
    xhr.send(form);
    await xhr.onLoadEnd.first;
    if (xhr.status == 200) {
      final res = xhr.response;
      Uint8List pdfBytes;
      if (res is ByteBuffer) {
        pdfBytes = Uint8List.view(res);
      } else if (res is Uint8List) {
        pdfBytes = res;
      } else if (res is List<int>) {
        pdfBytes = Uint8List.fromList(res);
      } else {
        setState(() {
          error = '转换返回类型不支持';
          loading = false;
        });
        return;
      }
      final url = html.Url.createObjectUrl(
        html.Blob([pdfBytes], 'application/pdf'),
      );
      _setPdfUrl(url);
    } else {
      setState(() {
        error = '转换失败: ${xhr.status}';
        loading = false;
      });
    }
  }

  Future<void> _pickPdf() async {
    if (!kIsWeb) {
      setState(() => error = '仅支持 Web 环境');
      return;
    }
    final input = html.FileUploadInputElement();
    input.accept = '.pdf';
    input.click();
    await input.onChange.first;
    final file = input.files?.isNotEmpty == true ? input.files!.first : null;
    if (file == null) return;
    setState(() {
      loading = true;
      error = null;
      fileName = file.name;
    });
    final url = html.Url.createObjectUrl(file);
    _setPdfUrl(url);
  }

  void _setPdfUrl(String url) {
    if (_pdfObjectUrl != null) {
      html.Url.revokeObjectUrl(_pdfObjectUrl!);
    }
    _pdfObjectUrl = url;
    _iframe?.src = url;
    setState(() {
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF 预览')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: loading ? null : _pickDocxAndConvert,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('选择 DOCX 并转换为 PDF'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: loading ? null : _pickPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('选择 PDF 文件'),
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
          else if (_pdfObjectUrl == null)
            const Expanded(
              child: Center(child: Text('请选择 DOCX 或 PDF 进行预览')),
            )
          else
            Expanded(
              child: HtmlElementView(viewType: 'pdf-view'),
            ),
        ],
      ),
    );
  }
}

void main() {
  runApp(const MaterialApp(home: VisualizeDocxPage()));
}
