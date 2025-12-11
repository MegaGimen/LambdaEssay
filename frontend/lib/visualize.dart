import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

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
      // Use localhost:3000/convert to convert docx to html
      // doc2html.exe is expected to be running on port 3000
      final uri = Uri.parse('http://localhost:3000/convert');
      final request = http.MultipartRequest('POST', uri);
      
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'document.docx',
        contentType: MediaType('application', 'vnd.openxmlformats-officedocument.wordprocessingml.document'),
      ));

      print('Visualize: sending request to $uri');
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      print('Visualize: response status=${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonBody = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (jsonBody['success'] == true) {
           final htmlContent = jsonBody['html'] as String;
           // The styles are already included in the HTML from doc2html server
           // But we can wrap it if needed. The server code provided shows it includes full HTML structure.
           // However, inserting full HTML into a div might be tricky if it has <html><head><body> tags.
           // InnerHTML usually handles it by stripping html/head/body tags but keeping styles if possible,
           // or we might need to extract body content.
           // Let's try setting innerHtml directly first.
           
           _element.className = 'mammoth-content';
           _element.innerHtml = htmlContent;
        } else {
           throw Exception(jsonBody['error'] ?? 'Unknown error from converter');
        }
      } else {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }
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
