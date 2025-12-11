import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js' as js;
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js_util' as js_util;

import 'utils/platform_registry.dart';

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
  bool _loading = false;
  String? _error;
  final String _viewType = 'docx-view-${DateTime.now().microsecondsSinceEpoch}';
  late html.DivElement _element;

  @override
  void initState() {
    super.initState();
    // Create a DivElement to render the HTML
    _element = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.overflow = 'auto'
      ..style.padding = '20px'
      ..style.backgroundColor = 'white'
      ..style.color = 'black'; // Ensure text is visible

    // Register the view factory
    // ignore: undefined_prefixed_name
    registerViewFactory(_viewType, (int viewId) => _element);

    if (widget.initialBytes != null) {
      _convert(widget.initialBytes!);
    }
  }

  Future<void> _convert(Uint8List bytes) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Check if mammoth is loaded
      if (!js.context.hasProperty('mammoth')) {
         throw Exception('Mammoth.js library not loaded');
      }

      final mammoth = js.context['mammoth'];
      
      // mammoth.convertToHtml({arrayBuffer: ...})
      final options = js.JsObject.jsify({
        'arrayBuffer': bytes.buffer,
      });

      final promise = mammoth.callMethod('convertToHtml', [options]);
      
      final result = await js_util.promiseToFuture(promise);
      // result is an object with 'value' (html) and 'messages'
      final htmlContent = js_util.getProperty(result, 'value');
      // final messages = js_util.getProperty(result, 'messages');
      
      // Update the DivElement
      _element.innerHtml = htmlContent;

    } catch (e) {
      setState(() {
        _error = 'Conversion failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickDocx() async {
    final input = html.FileUploadInputElement();
    input.accept = '.docx';
    input.click();
    await input.onChange.first;
    if (input.files?.isEmpty ?? true) return;
    final file = input.files!.first;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    
    final bytes = reader.result as Uint8List;
    setState(() {
       // Update title if needed?
    });
    _convert(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back), onPressed: widget.onBack)
            : null,
        title: Text(widget.title ?? 'Docx Preview'),
        actions: [
            IconButton(
                icon: const Icon(Icons.upload_file),
                onPressed: _pickDocx,
                tooltip: 'Open local .docx',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : HtmlElementView(viewType: _viewType),
    );
  }
}
