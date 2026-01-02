import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:file_picker/file_picker.dart';

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

  double _zoomLevel = 1.0;

  @override
  void initState() {
    super.initState();
    if (widget.initialBytes != null) {
      _pdfBytes = widget.initialBytes;
      _fileName = widget.title;
    }
  }

  Future<void> _pickPdf() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.bytes != null) {
        setState(() {
          _pdfBytes = file.bytes;
          _fileName = file.name;
        });
      }
    }
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
          Slider(
            value: _zoomLevel,
            min: 1.0,
            max: 3.0,
            onChanged: (value) {
              setState(() {
                _zoomLevel = value;
                _pdfViewerController.zoomLevel = value;
              });
            },
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
