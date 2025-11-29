import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:js' as js;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

class VisualizeDocxPage extends StatefulWidget {
  const VisualizeDocxPage({super.key});
  @override
  State<VisualizeDocxPage> createState() => _VisualizeDocxPageState();
}

class _VisualizeDocxPageState extends State<VisualizeDocxPage> {
  bool loading = false;
  String? error;
  String? fileName;
  List<Uint8List>? _pdfList;
  List<String>? _fileNames;
  String? _debugUrl;
  String? _lastContentType;
  String? _statusText;
  bool _useIframeFallback = false;

  Uint8List? _leftPdfBytes;
  Uint8List? _rightPdfBytes;
  String? _leftName;
  String? _rightName;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _pickPdf(String side) async {
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
      if (side == 'left') {
        _leftPdfBytes = reader.result as Uint8List;
        _leftName = file.name;
      } else {
        _rightPdfBytes = reader.result as Uint8List;
        _rightName = file.name;
      }
      // Clear other modes
      _pdfList = null;
      fileName = null;
      _fileNames = null;
      _debugUrl = null;
      loading = false;
      error = null;
    });
  }

  // ignore: unused_element
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
    xhr.onError.listen((_) {
      setState(() {
        error = '网络错误或后端未启动';
        loading = false;
      });
    });
    xhr.send(form);
    await xhr.onLoadEnd.first;
    if (xhr.status == 200) {
      _lastContentType = xhr.getResponseHeader('content-type');
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
      _setPdfBytes(pdfBytes, name: file.name);
    } else {
      setState(() {
        error = xhr.status == 0 ? '网络错误或后端未启动' : '转换失败: ${xhr.status}';
        loading = false;
      });
    }
  }

  // ignore: unused_element
  Future<void> _pickMultipleDocxAndConvert() async {
    if (!kIsWeb) {
      setState(() => error = '仅支持 Web 环境');
      return;
    }
    final input = html.FileUploadInputElement();
    input.accept = '.docx';
    input.multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;
    setState(() {
      loading = true;
      error = null;
      fileName = null;
      _fileNames = null;
    });
    final outputs = <Uint8List>[];
    final names = <String>[];
    for (final f in files.take(2)) {
      names.add(f.name);
      final form = html.FormData();
      form.appendBlob('file', f, f.name);
      form.append('to', 'pdf');
      final xhr = html.HttpRequest();
      xhr.open('POST', 'http://localhost:8080/convert', async: true);
      xhr.responseType = 'arraybuffer';
      xhr.onError.listen((_) {
        setState(() {
          error = '网络错误或后端未启动';
          loading = false;
        });
      });
      xhr.send(form);
      await xhr.onLoadEnd.first;
      if (xhr.status == 200) {
        _lastContentType = xhr.getResponseHeader('content-type');
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
        outputs.add(pdfBytes);
      } else {
        setState(() {
          error = xhr.status == 0 ? '网络错误或后端未启动' : '转换失败: ${xhr.status}';
          loading = false;
        });
        return;
      }
    }
    final filtered = <Uint8List>[];
    final filteredNames = <String>[];
    for (int i = 0; i < outputs.length; i++) {
      if (_looksLikePdf(outputs[i])) {
        filtered.add(outputs[i]);
        filteredNames.add(names[i]);
      }
    }
    if (filtered.isEmpty) {
      setState(() {
        error = '未检测到有效的 PDF 内容；content-type: ${_lastContentType ?? '未知'}';
        loading = false;
      });
      return;
    }
    setState(() {
      _pdfList = filtered;
      _fileNames = filteredNames;
      loading = false;
    });
  }

  bool _looksLikePdf(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    // PDF 以 %PDF- 开头
    const sig = [0x25, 0x50, 0x44, 0x46];
    if (bytes.length < sig.length) return false;
    for (int i = 0; i < sig.length; i++) {
      if (bytes[i] != sig[i]) return false;
    }
    return true;
  }

  void _setPdfBytes(Uint8List bytes, {String? name}) {
    if (!_looksLikePdf(bytes)) {
      final blob =
          html.Blob([bytes], _lastContentType ?? 'application/octet-stream');
      _debugUrl = html.Url.createObjectUrl(blob);
      setState(() {
        error = '收到的内容不是有效 PDF；content-type: ${_lastContentType ?? '未知'}';
        loading = false;
        _fileNames = name != null ? [name] : null;
        _pdfList = null;
      });
      return;
    }
    _pdfList = [bytes];
    try {
      final blob = html.Blob([bytes], 'application/pdf');
      _debugUrl = html.Url.createObjectUrl(blob);
    } catch (_) {}
    setState(() {
      loading = false;
      _statusText = '已接收 PDF，字节数: ${bytes.length}';
    });
  }

  String _suggestedDownloadName() {
    final ct = (_lastContentType ?? '').toLowerCase();
    if (ct.contains('application/pdf')) {
      return 'converted.pdf';
    }
    if (ct.contains(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document')) {
      return 'response.docx';
    }
    if (ct.contains('application/json')) {
      return 'response.json';
    }
    if (ct.contains('text/plain')) {
      return 'response.txt';
    }
    // 无 header 时用字节判断
    if (_pdfList != null &&
        _pdfList!.isNotEmpty &&
        _looksLikePdf(_pdfList!.first)) {
      return 'converted.pdf';
    }
    return 'response.bin';
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
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 隐藏 DOCX 转换入口，仅保留 PDF 上传
                // ElevatedButton.icon(
                //   onPressed: loading ? null : _pickDocxAndConvert,
                //   icon: const Icon(Icons.upload_file),
                //   label: const Text('DOCX 转 PDF'),
                // ),
                // ElevatedButton.icon(
                //   onPressed: loading ? null : _pickMultipleDocxAndConvert,
                //   icon: const Icon(Icons.view_sidebar),
                //   label: const Text('多 DOCX 并排'),
                // ),
                // const SizedBox(
                //   height: 20,
                //   child: VerticalDivider(color: Colors.grey),
                // ),
                ElevatedButton.icon(
                  onPressed: () => _pickPdf('left'),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: Text(_leftName == null ? '上传左侧 PDF' : '左: $_leftName'),
                  style: _leftName != null
                      ? ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade100,
                          foregroundColor: Colors.black)
                      : null,
                ),
                ElevatedButton.icon(
                  onPressed: () => _pickPdf('right'),
                  icon: const Icon(Icons.picture_as_pdf),
                  label:
                      Text(_rightName == null ? '上传右侧 PDF' : '右: $_rightName'),
                  style: _rightName != null
                      ? ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade100,
                          foregroundColor: Colors.black)
                      : null,
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _leftPdfBytes = null;
                      _rightPdfBytes = null;
                      _leftName = null;
                      _rightName = null;
                      _pdfList = null;
                      fileName = null;
                      _fileNames = null;
                      _debugUrl = null;
                      error = null;
                    });
                  },
                  icon: const Icon(Icons.refresh),
                  tooltip: '重置所有',
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_debugUrl != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextButton(
                onPressed: () {
                  final anchor = html.AnchorElement(href: _debugUrl!)
                    ..download = _suggestedDownloadName();
                  anchor.click();
                },
                child: const Text('下载后端返回内容以调试'),
              ),
            ),
          if (loading)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_leftPdfBytes != null && _rightPdfBytes != null)
            Expanded(
              child: SideBySidePdfTemplate(
                pdfs: [_leftPdfBytes!, _rightPdfBytes!],
                titles: [_leftName ?? 'Left', _rightName ?? 'Right'],
              ),
            )
          else if (_pdfList == null)
            const Expanded(
              child: Center(child: Text('请选择 DOCX 文件进行预览')),
            )
          else
            Expanded(
              child: _pdfList!.length >= 2
                  ? SideBySidePdfTemplate(pdfs: _pdfList!, titles: _fileNames)
                  : Column(
                      children: [
                        if (_statusText != null)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(_statusText!,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        Expanded(
                          child: _useIframeFallback && _debugUrl != null
                              ? HtmlElementView.fromTagName(
                                  tagName: 'iframe',
                                  onElementCreated: (element) {
                                    final iframe =
                                        element as html.IFrameElement;
                                    iframe.style.border = 'none';
                                    iframe.style.width = '100%';
                                    iframe.style.height = '100%';
                                    iframe.src = _debugUrl!;
                                  },
                                )
                              : SfPdfViewer.memory(
                                  _pdfList!.first,
                                  onDocumentLoaded:
                                      (PdfDocumentLoadedDetails d) {
                                    setState(() {
                                      _statusText =
                                          '文档已加载，共 ${d.document.pages.count} 页';
                                    });
                                  },
                                  onDocumentLoadFailed:
                                      (PdfDocumentLoadFailedDetails f) {
                                    setState(() {
                                      error = 'PDF 加载失败: ${f.error}';
                                      _useIframeFallback = true;
                                    });
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

class SideBySidePdfTemplate extends StatefulWidget {
  final List<Uint8List> pdfs;
  final List<String>? titles;
  const SideBySidePdfTemplate({super.key, required this.pdfs, this.titles});

  @override
  State<SideBySidePdfTemplate> createState() => _SideBySidePdfTemplateState();
}

class _SideBySidePdfTemplateState extends State<SideBySidePdfTemplate> {
  late final PdfViewerController _leftCtrl;
  late final PdfViewerController _rightCtrl;
  ScrollMetrics? _leftMetrics;
  ScrollMetrics? _rightMetrics;
  bool _syncingLeftToRight = false;
  bool _syncingRightToLeft = false;
  bool _syncingZoomLeftToRight = false;
  bool _syncingZoomRightToLeft = false;
  bool _useFallback = false;

  @override
  void initState() {
    super.initState();
    _leftCtrl = PdfViewerController();
    _rightCtrl = PdfViewerController();
  }

  bool _onLeftScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      _leftMetrics = n.metrics;
      if (_syncingRightToLeft) {
        _syncingRightToLeft = false;
        return false;
      }
      final left = n.metrics;
      final right = _rightMetrics;
      if (right != null &&
          left.maxScrollExtent > 0 &&
          right.maxScrollExtent > 0) {
        final ratio = left.pixels / left.maxScrollExtent;
        final target = ratio * right.maxScrollExtent;
        _syncingLeftToRight = true;
        _rightCtrl.jumpTo(yOffset: target);
      }
    }
    return false;
  }

  bool _onRightScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      _rightMetrics = n.metrics;
      if (_syncingLeftToRight) {
        _syncingLeftToRight = false;
        return false;
      }
      final right = n.metrics;
      final left = _leftMetrics;
      if (left != null &&
          right.maxScrollExtent > 0 &&
          left.maxScrollExtent > 0) {
        final ratio = right.pixels / right.maxScrollExtent;
        final target = ratio * left.maxScrollExtent;
        _syncingRightToLeft = true;
        _leftCtrl.jumpTo(yOffset: target);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_useFallback) {
      return SideBySideIframeTemplate(pdfs: widget.pdfs, titles: widget.titles);
    }
    final pdfs = widget.pdfs;
    final showTwo = pdfs.length >= 2;
    if (!showTwo) {
      return SfPdfViewer.memory(
        pdfs.first,
        controller: _leftCtrl,
        onDocumentLoadFailed: (d) {
          setState(() {
            _useFallback = true;
          });
        },
      );
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              if (widget.titles != null && widget.titles!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(widget.titles![0],
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onLeftScroll,
                  child: SfPdfViewer.memory(
                    pdfs[0],
                    controller: _leftCtrl,
                    onDocumentLoadFailed: (d) {
                      setState(() {
                        _useFallback = true;
                      });
                    },
                    onZoomLevelChanged: (PdfZoomDetails d) {
                      if (_syncingZoomRightToLeft) {
                        _syncingZoomRightToLeft = false;
                        return;
                      }
                      _syncingZoomLeftToRight = true;
                      _rightCtrl.zoomLevel = d.newZoomLevel;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              if (widget.titles != null && widget.titles!.length > 1)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(widget.titles![1],
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onRightScroll,
                  child: SfPdfViewer.memory(
                    pdfs[1],
                    controller: _rightCtrl,
                    onDocumentLoadFailed: (d) {
                      setState(() {
                        _useFallback = true;
                      });
                    },
                    onZoomLevelChanged: (PdfZoomDetails d) {
                      if (_syncingZoomLeftToRight) {
                        _syncingZoomLeftToRight = false;
                        return;
                      }
                      _syncingZoomRightToLeft = true;
                      _leftCtrl.zoomLevel = d.newZoomLevel;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class SideBySideIframeTemplate extends StatefulWidget {
  final List<Uint8List> pdfs;
  final List<String>? titles;
  const SideBySideIframeTemplate({super.key, required this.pdfs, this.titles});

  @override
  State<SideBySideIframeTemplate> createState() =>
      _SideBySideIframeTemplateState();
}

class _SideBySideIframeTemplateState extends State<SideBySideIframeTemplate> {
  late String _leftUrl;
  late String _rightUrl;
  final String _leftId = 'iframe_left_${DateTime.now().millisecondsSinceEpoch}';
  final String _rightId =
      'iframe_right_${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _leftUrl = _createViewerUrl(widget.pdfs[0], 'left');
    if (widget.pdfs.length > 1) {
      _rightUrl = _createViewerUrl(widget.pdfs[1], 'right');
    } else {
      _rightUrl = 'about:blank';
    }
    _setupMessageListener();
  }

  @override
  void dispose() {
    html.Url.revokeObjectUrl(_leftUrl);
    if (widget.pdfs.length > 1) {
      html.Url.revokeObjectUrl(_rightUrl);
    }
    super.dispose();
  }

  void _setupMessageListener() {
    html.window.onMessage.listen((event) {
      final data = event.data;
      if (data is Map || (data is js.JsObject)) {
        // Handle both Dart Map and JS Object
        // However, event.data from postMessage usually comes as a Dart-accessible object if simple,
        // or we might need to access properties dynamically.
        // Let's assume it's a JS-interop map or similar.
        dynamic mapData = data;
        // If it's a JSObject, we might need to convert it.
        // But simpler: just try to access fields if possible or pass it through.

        final leftFrame =
            html.document.getElementById(_leftId) as html.IFrameElement?;
        final rightFrame =
            html.document.getElementById(_rightId) as html.IFrameElement?;

        // Forward to both, let them filter by 'side'
        // But we need to avoid loops. The message contains 'side' of origin.
        // We can just broadcast.
        leftFrame?.contentWindow?.postMessage(mapData, '*');
        rightFrame?.contentWindow?.postMessage(mapData, '*');
      }
    });
  }

  String _createViewerUrl(Uint8List bytes, String side) {
    final base64Pdf = base64Encode(bytes);
    final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    body { margin: 0; padding: 0; background-color: #525659; }
    #container { display: flex; flex-direction: column; align-items: center; }
    canvas { margin-bottom: 10px; box-shadow: 0 2px 5px rgba(0,0,0,0.5); background-color: white; }
    #controls {
      position: fixed;
      bottom: 20px;
      right: 20px;
      display: flex;
      flex-direction: column;
      gap: 5px;
      z-index: 1000;
    }
    button {
      width: 30px;
      height: 30px;
      font-size: 20px;
      cursor: pointer;
      background: white;
      border: 1px solid #ccc;
      border-radius: 4px;
    }
  </style>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>
</head>
<body>
  <div id="container"></div>
  <div id="controls">
    <button onclick="zoom(0.2)">+</button>
    <button onclick="zoom(-0.2)">-</button>
  </div>
  <script>
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
    
    const binaryString = atob("$base64Pdf");
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const side = "$side";
    let pdfDoc = null;
    let isSyncing = false;
    let currentScale = 1.0;

    // 防止 iframe 内的缩放事件冒泡到主页面，并实现内部缩放
    window.addEventListener('wheel', function(e) {
      if (e.ctrlKey) {
        e.preventDefault();
        // 滚轮向下(deltaY > 0)是缩小，向上是放大
        // 调整步进值，使其平滑
        const delta = e.deltaY > 0 ? -0.05 : 0.05;
        zoom(delta);
      }
    }, { passive: false });
    
    // 拦截键盘缩放，只在 iframe 聚焦时生效
    window.addEventListener('keydown', function(e) {
      if (e.ctrlKey) {
        if (e.key === '=' || e.key === '+') {
          e.preventDefault();
          zoom(0.1);
        } else if (e.key === '-') {
          e.preventDefault();
          zoom(-0.1);
        } else if (e.key === '0') {
          e.preventDefault();
          // 重置缩放逻辑可以自己实现，这里暂且不处理或设为1.0
          currentScale = 1.0;
          render();
          window.parent.postMessage({
            type: 'sync-zoom',
            side: side,
            scale: currentScale
          }, '*');
        }
      }
    });

    // 处理触摸板/移动端的双指缩放手势 (Safari/Webkit)
    window.addEventListener('gesturestart', function(e) {
      e.preventDefault();
    });
    window.addEventListener('gesturechange', function(e) {
      e.preventDefault();
      // e.scale 是相对于 gesturestart 时的比例
      // 这里简化处理，只根据变化方向微调
      if (e.scale > 1) {
        zoom(0.02);
      } else if (e.scale < 1) {
        zoom(-0.02);
      }
    });
    
    async function render() {
      if (!pdfDoc) return;
      
      // Save scroll ratio
      const h = document.documentElement.scrollHeight - window.innerHeight;
      const ratio = h > 0 ? window.scrollY / h : 0;

      const container = document.getElementById('container');
      container.innerHTML = '';
      
      for (let i = 1; i <= pdfDoc.numPages; i++) {
        const page = await pdfDoc.getPage(i);
        const viewport = page.getViewport({scale: currentScale});
        const canvas = document.createElement('canvas');
        const context = canvas.getContext('2d');
        canvas.height = viewport.height;
        canvas.width = viewport.width;
        // canvas.style.width = '100%'; // Do not force 100% width if we want zoom to work properly horizontally?
        // Actually if we force 100% width, canvas resolution increases but visual size stays same?
        // No, usually we want visual size to grow.
        canvas.style.maxWidth = '100%';
        canvas.style.height = 'auto';
        
        // If we want true zoom, we should probably let it grow beyond 100% or handle overflow.
        // But for "side by side", usually we want it to fit or scroll horizontally.
        // Let's remove maxWidth restriction for zoom? Or keep it?
        // If I keep maxWidth 100%, zooming in just increases resolution (sharpness) but not size on screen if it's already filling width.
        // But if page is small, it grows.
        // Let's try to set specific style width/height to match viewport.
        canvas.style.width = viewport.width + 'px';
        canvas.style.height = viewport.height + 'px';
        canvas.style.maxWidth = 'none'; // Allow horizontal scroll

        container.appendChild(canvas);
        await page.render({canvasContext: context, viewport: viewport}).promise;
      }
      
      // Restore scroll
      const newH = document.documentElement.scrollHeight - window.innerHeight;
      if (newH > 0) {
        window.scrollTo(0, ratio * newH);
      }
    }

    function zoom(delta) {
      const newScale = currentScale + delta;
      if (newScale < 0.2 || newScale > 5.0) return;
      currentScale = newScale;
      render();
      window.parent.postMessage({
        type: 'sync-zoom',
        side: side,
        scale: currentScale
      }, '*');
    }
    
    (async function() {
      const loadingTask = pdfjsLib.getDocument({data: bytes});
      pdfDoc = await loadingTask.promise;
      render();
    })();
    
    window.addEventListener('scroll', () => {
      if (isSyncing) {
        isSyncing = false;
        return;
      }
      const h = document.documentElement.scrollHeight - window.innerHeight;
      if (h <= 0) return;
      const ratio = window.scrollY / h;
      window.parent.postMessage({
        type: 'sync-scroll',
        side: side,
        ratio: ratio
      }, '*');
    });
    
    window.addEventListener('message', (event) => {
      const data = event.data;
      if (!data) return;
      
      if (data.type === 'sync-scroll' && data.side !== side) {
        const h = document.documentElement.scrollHeight - window.innerHeight;
        if (h > 0) {
          isSyncing = true;
          window.scrollTo(0, data.ratio * h);
        }
      }
      
      if (data.type === 'sync-zoom' && data.side !== side) {
        if (Math.abs(currentScale - data.scale) > 0.01) {
           currentScale = data.scale;
           render();
        }
      }
    });
  </script>
</body>
</html>
''';
    final blob = html.Blob([htmlContent], 'text/html');
    return html.Url.createObjectUrl(blob);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              if (widget.titles != null && widget.titles!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(widget.titles![0],
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              Expanded(
                child: HtmlElementView.fromTagName(
                  tagName: 'iframe',
                  onElementCreated: (element) {
                    final iframe = element as html.IFrameElement;
                    iframe.id = _leftId;
                    iframe.style.border = 'none';
                    iframe.style.width = '100%';
                    iframe.style.height = '100%';
                    iframe.src = _leftUrl;
                  },
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              if (widget.titles != null && widget.titles!.length > 1)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(widget.titles![1],
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              Expanded(
                child: widget.pdfs.length > 1
                    ? HtmlElementView.fromTagName(
                        tagName: 'iframe',
                        onElementCreated: (element) {
                          final iframe = element as html.IFrameElement;
                          iframe.id = _rightId;
                          iframe.style.border = 'none';
                          iframe.style.width = '100%';
                          iframe.style.height = '100%';
                          iframe.src = _rightUrl;
                        },
                      )
                    : const Center(child: Text('No second PDF')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

void main() {
  runApp(const MaterialApp(home: VisualizeDocxPage()));
}
