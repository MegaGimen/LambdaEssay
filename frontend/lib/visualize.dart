import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

class VisualizeDocxPage extends StatefulWidget {
  final Uint8List? initialBytes;
  final String? title;
  final VoidCallback? onBack;

  const VisualizeDocxPage({
    super.key,
    this.initialBytes,
    this.title,
    this.onBack,
  });

  @override
  State<VisualizeDocxPage> createState() => _VisualizeDocxPageState();
}

class _VisualizeDocxPageState extends State<VisualizeDocxPage> {
  Uint8List? _pdfBytes;
  String? _fileName;
  final PdfViewerController _pdfViewerController = PdfViewerController();

  @override
  void initState() {
    super.initState();
    if (widget.initialBytes != null) {
      _pdfBytes = widget.initialBytes;
      _fileName = widget.title;
    }
    // Add listeners to prevent browser zoom
    // This attempts to block the default browser zoom behavior when the user uses Ctrl+Scroll or Ctrl +/-
    // allowing the PDF viewer's internal zoom or just preventing UI scaling.
    html.window.addEventListener('wheel', _preventBrowserZoom, true);
    html.window.addEventListener('keydown', _preventBrowserKeyZoom, true);
  }

  @override
  void dispose() {
    html.window.removeEventListener('wheel', _preventBrowserZoom, true);
    html.window.removeEventListener('keydown', _preventBrowserKeyZoom, true);
    super.dispose();
  }

  void _preventBrowserZoom(html.Event e) {
    if (e is html.WheelEvent && e.ctrlKey) {
      e.preventDefault();
    }
  }

  void _preventBrowserKeyZoom(html.Event e) {
    if (e is html.KeyboardEvent && e.ctrlKey) {
      // Prevent Ctrl + (+, -, 0, =)
      if (e.key == '=' || e.key == '-' || e.key == '+' || e.key == '0') {
        e.preventDefault();
      }
    }
  }

  Future<void> _pickPdf() async {
    final input = html.FileUploadInputElement();
    input.accept = '.pdf';
    input.click();
    await input.onChange.first;
    if (input.files?.isEmpty ?? true) return;
    final file = input.files!.first;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    setState(() {
      _pdfBytes = reader.result as Uint8List;
      _fileName = file.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back), onPressed: widget.onBack)
            : null,
        title: Text(_fileName ?? widget.title ?? 'PDF 预览'),
        actions: [
          if (_pdfBytes != null)
            IconButton(
              icon: const Icon(Icons.upload_file),
              onPressed: _pickPdf,
              tooltip: '上传新的 PDF',
            ),
          if (_pdfBytes != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _pdfBytes = null;
                  _fileName = null;
                });
              },
              tooltip: '关闭',
            ),
        ],
      ),
      body: _pdfBytes == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('请上传 PDF 文件进行预览'),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _pickPdf,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('上传 PDF'),
                  ),
                ],
              ),
            )
          : SfPdfViewer.memory(
              _pdfBytes!,
              controller: _pdfViewerController,
            ),
    );
  }
}

void main() {
  runApp(const MaterialApp(home: VisualizeDocxPage()));
}
