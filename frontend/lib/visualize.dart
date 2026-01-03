import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:file_picker/file_picker.dart';

String appDataCacheDirPath() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty) {
    return '$app${Platform.pathSeparator}cache';
  }
  return Directory.systemTemp.path;
}

String cachePdfPathForSha(String sha1) {
  return '${appDataCacheDirPath()}${Platform.pathSeparator}$sha1.pdf';
}

String cacheThumbPathForSha(String sha1) {
  return '${appDataCacheDirPath()}${Platform.pathSeparator}$sha1.png';
}

Future<Directory> ensureAppDataCacheDir() async {
  final dir = Directory(appDataCacheDirPath());
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}

class PdfPreviewPane extends StatefulWidget {
  final Uint8List? bytes;
  final String? filePath;
  final double minZoom;
  final double maxZoom;
  final double initialZoom;
  final bool thumbnailMode;

  const PdfPreviewPane({
    super.key,
    this.bytes,
    this.filePath,
    this.minZoom = 0.5,
    this.maxZoom = 3.0,
    this.initialZoom = 1.0,
    this.thumbnailMode = false,
  });

  @override
  State<PdfPreviewPane> createState() => _PdfPreviewPaneState();
}

class _PdfPreviewPaneState extends State<PdfPreviewPane> {
  final PdfViewerController _controller = PdfViewerController();
  late double _zoomLevel;

  @override
  void initState() {
    super.initState();
    _zoomLevel = widget.initialZoom;
    _controller.zoomLevel = _zoomLevel;
  }

  @override
  void didUpdateWidget(covariant PdfPreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialZoom != widget.initialZoom) {
      _zoomLevel = widget.initialZoom;
      _controller.zoomLevel = _zoomLevel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasBytes = widget.bytes != null && widget.bytes!.isNotEmpty;
    final hasFile = widget.filePath != null && widget.filePath!.isNotEmpty;
    if (!hasBytes && !hasFile) {
      return const Center(child: Text('暂无可预览的 PDF'));
    }

    final viewer = hasFile
        ? SfPdfViewer.file(
            File(widget.filePath!),
            controller: _controller,
            canShowScrollHead: !widget.thumbnailMode,
            canShowPaginationDialog: !widget.thumbnailMode,
            enableDoubleTapZooming: !widget.thumbnailMode,
            enableTextSelection: !widget.thumbnailMode,
            pageLayoutMode: widget.thumbnailMode
                ? PdfPageLayoutMode.single
                : PdfPageLayoutMode.continuous,
          )
        : SfPdfViewer.memory(
            widget.bytes!,
            controller: _controller,
            canShowScrollHead: !widget.thumbnailMode,
            canShowPaginationDialog: !widget.thumbnailMode,
            enableDoubleTapZooming: !widget.thumbnailMode,
            enableTextSelection: !widget.thumbnailMode,
            pageLayoutMode: widget.thumbnailMode
                ? PdfPageLayoutMode.single
                : PdfPageLayoutMode.continuous,
          );

    if (widget.thumbnailMode) {
      return AbsorbPointer(child: viewer);
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 8),
            const Text('缩放', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: _zoomLevel.clamp(widget.minZoom, widget.maxZoom),
                min: widget.minZoom,
                max: widget.maxZoom,
                onChanged: (v) {
                  setState(() {
                    _zoomLevel = v;
                    _controller.zoomLevel = v;
                  });
                },
              ),
            ),
          ],
        ),
        Expanded(child: viewer),
      ],
    );
  }
}

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
            min: 0.5,
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
