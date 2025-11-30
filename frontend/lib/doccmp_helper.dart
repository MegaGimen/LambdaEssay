import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

void main(List<String> args) {
  if (args.length < 2) {
    print('Usage: dart doccmp_helper.dart <file1.docx> <file2.docx>');
    return;
  }

  final file1 = File(args[0]);
  final file2 = File(args[1]);

  if (!file1.existsSync() || !file2.existsSync()) {
    print('Error: Files not found.');
    return;
  }

  compareDocx(file1.absolute.path, file2.absolute.path);
}

void compareDocx(String path1, String path2) {
  final tempDir1 = Directory.systemTemp.createTempSync('docx_diff_1_');
  final tempDir2 = Directory.systemTemp.createTempSync('docx_diff_2_');

  try {
    // 1. Unzip
    print('Unzipping $path1 to ${tempDir1.path}...');
    _unzip(path1, tempDir1.path);

    print('Unzipping $path2 to ${tempDir2.path}...');
    _unzip(path2, tempDir2.path);

    // 2. Compare document.xml intelligently
    _processDocumentXml(tempDir1, tempDir2);

    // 3. Zip results
    // Note: For other files, we currently keep them as is in tempDir1.

    _safeZip(tempDir1.path, '1_diff.docx');
    _safeZip(tempDir2.path, '2_diff.docx');

    print('Done.');
  } finally {
    // Cleanup
    if (tempDir1.existsSync()) tempDir1.deleteSync(recursive: true);
    if (tempDir2.existsSync()) tempDir2.deleteSync(recursive: true);
  }
}

void _safeZip(String srcDir, String targetPath) {
  try {
    print('Creating $targetPath...');
    _zip(srcDir, targetPath);
  } catch (e) {
    print('Error creating $targetPath: $e');
    final altPath = targetPath.replaceAll('.docx', '_new.docx');
    print('Trying alternate path: $altPath...');
    try {
      _zip(srcDir, altPath);
      print('Successfully created $altPath');
    } catch (e2) {
      print('Failed to create output file: $e2');
    }
  }
}

void _processDocumentXml(Directory dir1, Directory dir2) {
  final f1 = File('${dir1.path}/word/document.xml');
  final f2 = File('${dir2.path}/word/document.xml');

  if (!f1.existsSync() || !f2.existsSync()) {
    print('Warning: document.xml not found in one of the files.');
    return;
  }

  final content1 = f1.readAsStringSync();
  final content2 = f2.readAsStringSync();

  try {
    final doc1 = XmlDocument.parse(content1);
    final doc2 = XmlDocument.parse(content2);

    final body1 = doc1.findAllElements('w:body').first;
    final body2 = doc2.findAllElements('w:body').first;

    // We treat children of body as the unit of comparison (paragraphs, tables, etc.)
    // We need to filter out sectPr which usually comes last
    final children1 = body1.children.where((c) => c is XmlElement).toList();
    final children2 = body2.children.where((c) => c is XmlElement).toList();

    final mergedChildren = _mergeXmlNodes(children1, children2);

    // Clear body1 and add merged children
    // We need to keep sectPr if it exists and wasn't in the merge list (it should be)
    // But to be safe, let's just replace all children.
    // Note: XmlNode.replace is tricky if we are iterating.
    // Easier to create a new body content.

    // However, we need to be careful about namespaces.
    // We will construct a list of nodes to set as children.

    // Update doc1
    body1.children.clear();
    for (final node in mergedChildren) {
      // We need to clone the node to avoid parenting issues if it came from doc2
      body1.children.add(node.copy());
    }

    // Update doc2
    // We want doc2 to also have the merged content
    body2.children.clear();
    for (final node in mergedChildren) {
      body2.children.add(node.copy());
    }

    f1.writeAsStringSync(doc1.toXmlString());
    f2.writeAsStringSync(doc2.toXmlString());
  } catch (e, st) {
    print('Error parsing/merging XML: $e\n$st');
  }
}

List<XmlNode> _mergeXmlNodes(List<XmlNode> nodes1, List<XmlNode> nodes2) {
  // Use normalized strings for comparison to ignore rsid and other noise
  final strs1 = nodes1.map((n) => _getNormalizedXmlString(n)).toList();
  final strs2 = nodes2.map((n) => _getNormalizedXmlString(n)).toList();

  final changes = _computeDiff(strs1, strs2);
  final merged = <XmlNode>[];

  int idx1 = 0;
  int idx2 = 0;

  int i = 0;
  while (i < changes.length) {
    final c = changes[i];
    if (c.operation == 0) {
      // Equal
      merged.add(nodes1[idx1]);
      idx1++;
      idx2++;
      i++;
    } else {
      // Change block
      final deletions = <XmlNode>[];
      final insertions = <XmlNode>[];

      // Collect consecutive changes
      while (i < changes.length && changes[i].operation != 0) {
        if (changes[i].operation == -1) {
          // Delete
          deletions.add(nodes1[idx1]);
          idx1++;
        } else {
          // Insert
          insertions.add(nodes2[idx2]);
          idx2++;
        }
        i++;
      }

      // Generate Conflict Markers
      if (deletions.isNotEmpty) {
        merged
            .add(_createMarkerParagraph('<<<<<<< DOCUMENT 1', 'FF0000')); // Red
        merged.addAll(deletions);
      }

      if (deletions.isNotEmpty && insertions.isNotEmpty) {
        merged.add(_createMarkerParagraph('=======', '0000FF')); // Blue
      } else if (deletions.isNotEmpty) {
        merged.add(_createMarkerParagraph('=======', '0000FF'));
      } else if (insertions.isNotEmpty) {
        merged.add(_createMarkerParagraph('<<<<<<< DOCUMENT 1', 'FF0000'));
        merged.add(_createMarkerParagraph('=======', '0000FF'));
      }

      if (insertions.isNotEmpty) {
        merged.addAll(insertions);
      }

      merged
          .add(_createMarkerParagraph('>>>>>>> DOCUMENT 2', '008000')); // Green
    }
  }

  return merged;
}

String _getNormalizedXmlString(XmlNode node) {
  // Clone the node to avoid modifying the original
  final clone = node.copy();
  _normalizeNode(clone);
  return clone.toXmlString();
}

void _normalizeNode(XmlNode node) {
  if (node is XmlElement) {
    // 1. Remove ignored attributes
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

    // 2. Remove ignored children elements and recurse
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

XmlNode _createMarkerParagraph(String text, String colorHex) {
  // Construct a valid w:p element
  // <w:p>
  //   <w:r>
  //     <w:rPr>
  //       <w:color w:val="colorHex"/>
  //       <w:b/>
  //     </w:rPr>
  //     <w:t>text</w:t>
  //   </w:r>
  // </w:p>

  final builder = XmlBuilder();
  builder.element('w:p', nest: () {
    builder.element('w:r', nest: () {
      builder.element('w:rPr', nest: () {
        builder.element('w:color', attributes: {'w:val': colorHex});
        builder.element('w:b'); // Bold
      });
      builder.element('w:t', nest: () {
        builder.text(text);
      });
    });
  });
  return builder.buildDocument().rootElement;
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

void _zip(String srcDir, String zipPath) {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  encoder.addDirectory(Directory(srcDir), includeDirName: false);
  encoder.close();
}

class _DiffChange {
  final int operation; // 0: equal, -1: delete, 1: insert
  final String text;
  _DiffChange(this.operation, this.text);
}

List<_DiffChange> _computeDiff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final max = n + m;

  final v = List<int>.filled(2 * max + 1, 0);
  final trace = <List<int>>[];

  for (var d = 0; d <= max; d++) {
    final vCopy = List<int>.from(v);
    trace.add(vCopy);

    for (var k = -d; k <= d; k += 2) {
      var x;
      if (k == -d || (k != d && v[max + k - 1] < v[max + k + 1])) {
        x = v[max + k + 1];
      } else {
        x = v[max + k - 1] + 1;
      }

      var y = x - k;

      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }

      v[max + k] = x;

      if (x >= n && y >= m) {
        return _buildScript(a, b, trace, n, m, max);
      }
    }
  }
  return [];
}

List<_DiffChange> _buildScript(List<String> a, List<String> b,
    List<List<int>> trace, int n, int m, int max) {
  var x = n;
  var y = m;
  final result = <_DiffChange>[];

  for (var d = trace.length - 1; d >= 0; d--) {
    final v = trace[d];
    final k = x - y;

    if (d == 0) {
      while (x > 0 && y > 0) {
        result.add(_DiffChange(0, a[x - 1]));
        x--;
        y--;
      }
      break;
    }

    final prevK = (k == -d || (k != d && v[max + k - 1] < v[max + k + 1]))
        ? k + 1
        : k - 1;

    final prevX = v[max + prevK];
    final prevY = prevX - prevK;

    while (x > prevX && y > prevY) {
      result.add(_DiffChange(0, a[x - 1]));
      x--;
      y--;
    }

    if (d > 0) {
      if (x == prevX) {
        result.add(_DiffChange(1, b[y - 1])); // Insert
        y--;
      } else if (y == prevY) {
        result.add(_DiffChange(-1, a[x - 1])); // Delete
        x--;
      }
    }
  }

  return result.reversed.toList();
}
