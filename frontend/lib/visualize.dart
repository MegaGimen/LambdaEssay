import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
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
    print('Visualize: received bytes length=${bytes.length}');
    if (bytes.length >= 4) {
      print('Visualize: header=${bytes.sublist(0, 4)}');
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Check if mammoth is loaded
      if (!js_util.hasProperty(html.window, 'mammoth')) {
        throw Exception('Mammoth.js library not loaded');
      }

      final mammoth = js_util.getProperty(html.window, 'mammoth');

      // Create a JS Uint8Array from the bytes to ensure we have a valid JS ArrayBuffer
      // This helps avoid issues with Dart ByteBuffer mapping
      // Note: Passing Dart Uint8List to JS Uint8Array constructor works because Uint8List is Iterable.
      final jsUint8Array = js_util.callConstructor(
        js_util.getProperty(html.window, 'Uint8Array'), 
        [bytes]
      );
      final arrayBuffer = js_util.getProperty(jsUint8Array, 'buffer');

      // mammoth.convertToHtml({arrayBuffer: ...})
      final options = js_util.newObject();
      js_util.setProperty(options, 'arrayBuffer', arrayBuffer);

      print('Visualize: calling mammoth.convertToHtml');
      final promise = js_util.callMethod(mammoth, 'convertToHtml', [options]);

      final result = await js_util.promiseToFuture(promise);
      print('Visualize: conversion result obtained');
      
      // result is an object with 'value' (html) and 'messages'
      final htmlContent = js_util.getProperty(result, 'value') as String;
      final messages = js_util.getProperty(result, 'messages');
      print('Visualize: messages=$messages');

      // Process highlights and styles
      final processedHtml = _processHighlights(htmlContent);
      final finalHtml = _wrapWithStyles(processedHtml);

      // Update the DivElement
      // Add a class for styling scope
      _element.className = 'mammoth-content';
      _element.innerHtml = finalHtml;
    } catch (e) {
      print('Visualize: error=$e');
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

  String _processHighlights(String html) {
    var result = html;
    final patterns = [
      r'<span[^>]*background:yellow[^>]*>(.*?)<\/span>',
      r'<span[^>]*background-color:yellow[^>]*>(.*?)<\/span>',
      r'<span[^>]*background-color:#?ffff00[^>]*>(.*?)<\/span>',
      r'<span[^>]*background:#?ffff00[^>]*>(.*?)<\/span>',
    ];

    for (final pattern in patterns) {
      result = result.replaceAllMapped(
        RegExp(pattern, caseSensitive: false, multiLine: true),
        (match) => '<mark>${match.group(1)}</mark>',
      );
    }
    return result;
  }

  String _wrapWithStyles(String content) {
    // Styles adapted from server.js
    // Scoped to .mammoth-content to avoid global pollution if possible
    const styles = '''
<style>
  .mammoth-content * { 
    font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif;
  }
  
  .mammoth-content table {
    border-collapse: collapse;
    width: 100%;
    border: 1px solid #000;
    margin: 10px 0;
  }
  
  .mammoth-content th, .mammoth-content td {
    border: 1px solid #000;
    padding: 8px;
  }
  
  .mammoth-content th {
    background-color: #f2f2f2;
  }
  
  .mammoth-content mark {
    background-color: yellow;
    padding: 2px 4px;
  }
  
  /* Root level styles */
  .mammoth-content {
    font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif;
    line-height: 1.6;
    color: black;
  }
</style>
''';
    return styles + content;
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
    
    final result = reader.result;
    Uint8List bytes;
    if (result is Uint8List) {
      bytes = result;
    } else if (result is ByteBuffer) {
      bytes = result.asUint8List();
    } else {
      // Fallback or error
      bytes = Uint8List(0);
    }

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
              ? Center(
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)))
              : HtmlElementView(viewType: _viewType),
    );
  }
}
