import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

void _debugDocumentXml(Directory dir1, Directory dir2) {
  final f1 = File('${dir1.path}/word/document.xml');
  final f2 = File('${dir2.path}/word/document.xml');

  final content1 = f1.readAsStringSync();
  final content2 = f2.readAsStringSync();

  final doc1 = XmlDocument.parse(content1);
  final doc2 = XmlDocument.parse(content2);

  final body1 = doc1.findAllElements('w:body').first;
  final body2 = doc2.findAllElements('w:body').first;

  final children1 = body1.children.where((c) => c is XmlElement).toList();
  final children2 = body2.children.where((c) => c is XmlElement).toList();

  final strs1 = children1.map((n) => _getNormalizedXmlString(n)).toList();
  final strs2 = children2.map((n) => _getNormalizedXmlString(n)).toList();

  print('Children count: ${strs1.length} vs ${strs2.length}');

  final outputBuffer = StringBuffer();
  outputBuffer.writeln('Children count: ${strs1.length} vs ${strs2.length}');

  // Simple pairwise check for debugging
  int maxLen = strs1.length > strs2.length ? strs1.length : strs2.length;
  for (int i = 0; i < maxLen; i++) {
    String? s1 = i < strs1.length ? strs1[i] : null;
    String? s2 = i < strs2.length ? strs2[i] : null;

    if (s1 != s2) {
      outputBuffer.writeln('\n--- Difference at index $i ---');
      if (s1 != null)
        outputBuffer.writeln('DOC 1:\n$s1');
      else
        outputBuffer.writeln('DOC 1: (missing)');
      if (s2 != null)
        outputBuffer.writeln('DOC 2:\n$s2');
      else
        outputBuffer.writeln('DOC 2: (missing)');
    }
  }

  File('debug_output.txt').writeAsStringSync(outputBuffer.toString());
  print('Debug output written to debug_output.txt');
}

void main(List<String> args) {
  if (args.length != 2) {
    print('Usage: dart debug_diff.dart <doc1> <doc2>');
    exit(1);
  }

  final f1 = File(args[0]);
  final f2 = File(args[1]);

  if (!f1.existsSync() || !f2.existsSync()) {
    print('Files not found');
    exit(1);
  }

  final tempDir = Directory.systemTemp.createTempSync('debug_diff_');
  final dir1 = Directory('${tempDir.path}/doc1');
  final dir2 = Directory('${tempDir.path}/doc2');

  try {
    _unzip(f1.path, dir1.path);
    _unzip(f2.path, dir2.path);

    _debugDocumentXml(dir1, dir2);
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

String _getNormalizedXmlString(XmlNode node) {
  final clone = node.copy();
  _normalizeNode(clone);
  return clone.toXmlString(pretty: true);
}

void _normalizeNode(XmlNode node) {
  if (node is XmlElement) {
    final toRemoveAttrs = <XmlAttribute>[];
    for (final attr in node.attributes) {
      final name = attr.name.qualified;
      if (name.startsWith('w:rsid') ||
          name.startsWith('w14:') ||
          (node.name.qualified == 'wp:docPr' && name == 'id')) {
        toRemoveAttrs.add(attr);
      }
    }
    for (final attr in toRemoveAttrs) {
      node.attributes.remove(attr);
    }

    final toRemoveChildren = <XmlNode>[];
    for (final child in node.children) {
      if (child is XmlElement) {
        final name = child.name.qualified;
        if (name == 'w:proofErr' ||
            name == 'w:lastRenderedPageBreak' ||
            name == 'w:noProof' ||
            name == 'w:lang' ||
            name == 'w:gramE' ||
            name == 'w:rFonts') {
          toRemoveChildren.add(child);
        } else {
          _normalizeNode(child);
          // Check if child became empty after normalization
          if ((name == 'w:rPr' || name == 'w:pPr') &&
              child.children.isEmpty &&
              child.attributes.isEmpty) {
            toRemoveChildren.add(child);
          }
        }
      } else {
        _normalizeNode(child);
      }
    }

    for (final child in toRemoveChildren) {
      node.children.remove(child);
    }
  }
}

void _unzip(String zipPath, String destPath) {
  final bytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    final filename = file.name;
    if (file.isFile) {
      final data = file.content as List<int>;
      File('$destPath/$filename')
        ..createSync(recursive: true)
        ..writeAsBytesSync(data);
    } else {
      Directory('$destPath/$filename').createSync(recursive: true);
    }
  }
}
