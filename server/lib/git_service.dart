import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'models.dart';

final Map<String, GraphResponse> _graphCache = <String, GraphResponse>{};

void clearCache() {
  _graphCache.clear();
}

Future<List<String>> _runGit(List<String> args, String repoPath) async {
  final fullArgs = [
    '-c',
    'i18n.logOutputEncoding=UTF-8',
    '-c',
    'core.quotepath=false',
    '-C',
    repoPath,
    ...args,
  ];
  final res = await Process.run(
    'git',
    fullArgs,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (res.exitCode != 0) {
    throw Exception(res.stderr is String ? res.stderr : 'git error');
  }
  final out =
      res.stdout is String ? res.stdout as String : utf8.decode(res.stdout);
  return LineSplitter.split(out).toList();
}

Future<List<Branch>> getBranches(String repoPath) async {
  final lines = await _runGit([
    'for-each-ref',
    '--format=%(refname:short)|%(objectname)',
    'refs/heads',
  ], repoPath);
  final result = <Branch>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length >= 2) {
      result.add(Branch(name: parts[0], head: parts[1]));
    }
  }
  return result;
}

Future<GraphResponse> getGraph(String repoPath, {int? limit}) async {
  final key = '${repoPath}|${limit ?? 0}';
  final cached = _graphCache[key];
  if (cached != null) {
    return cached;
  }
  final branches = await getBranches(repoPath);
  final chains = await getBranchChains(repoPath, branches, limit: limit);
  final logArgs = [
    'log',
    '--all',
    '--date=iso',
    '--encoding=UTF-8',
    '--pretty=format:%H|%P|%d|%s|%an|%ad',
    '--topo-order',
  ];
  if (limit != null && limit > 0) {
    logArgs.add('--max-count=$limit');
  }
  final lines = await _runGit(logArgs, repoPath);
  final commits = <CommitNode>[];
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final parts = l.split('|');
    if (parts.length < 6) continue;
    final id = parts[0];
    final parents = parts[1].trim().isEmpty
        ? <String>[]
        : parts[1].trim().split(RegExp(r'\s+'));
    final dec = parts[2];
    final refs = _parseRefs(dec);
    final subject = parts[3];
    final author = parts[4];
    final date = parts[5];
    commits.add(
      CommitNode(
        id: id,
        parents: parents,
        refs: refs,
        author: author,
        date: date,
        subject: subject,
      ),
    );
  }
  final resp =
      GraphResponse(commits: commits, branches: branches, chains: chains);
  _graphCache[key] = resp;
  return resp;
}

List<String> _parseRefs(String decoration) {
  final s = decoration.trim();
  if (s.isEmpty) return <String>[];
  final start = s.indexOf('(');
  final end = s.lastIndexOf(')');
  if (start < 0 || end < 0 || end <= start) return <String>[];
  final inner = s.substring(start + 1, end);
  final items = inner.split(',');
  final refs = <String>[];
  for (var i in items) {
    final t = i.trim();
    if (t.isEmpty) continue;
    final cleaned = t
        .replaceAll(RegExp(r'^HEAD ->\s*'), '')
        .replaceAll(RegExp(r'^tag:\s*'), '')
        .replaceAll(RegExp(r'^origin/'), 'origin/');
    refs.add(cleaned);
  }
  return refs;
}

Future<Map<String, List<String>>> getBranchChains(
    String repoPath, List<Branch> branches,
    {int? limit}) async {
  final result = <String, List<String>>{};
  for (final b in branches) {
    final args = [
      'log',
      '--topo-order',
      '--date=iso',
      '--encoding=UTF-8',
      '--pretty=format:%H',
      b.name,
    ];
    if (limit != null && limit > 0) {
      args.add('--max-count=$limit');
    }
    final lines = await _runGit(args, repoPath);
    final ids = <String>[];
    for (final l in lines) {
      final s = l.trim();
      if (s.isEmpty) continue;
      ids.add(s);
    }
    result[b.name] = ids;
  }
  return result;
}

String _baseDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty) return p.join(app, 'gitdocx');
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) return p.join(home, '.gitdocx');
  return p.join(Directory.systemTemp.path, 'gitdocx');
}

File _trackingFile(String name) {
  final dir = p.normalize(p.join(_baseDir(), name));
  return File(p.join(dir, 'tracking.json'));
}

Future<Map<String, dynamic>> _readTracking(String name) async {
  final f = _trackingFile(name);
  if (!f.existsSync()) return <String, dynamic>{};
  final s = await f.readAsString();
  try {
    return jsonDecode(s) as Map<String, dynamic>;
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<void> _writeTracking(String name, Map<String, dynamic> data) async {
  final dir = Directory(p.dirname(_trackingFile(name).path));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final f = _trackingFile(name);
  await f.writeAsString(jsonEncode(data));
}

String _projectDir(String name) {
  return p.normalize(p.join(_baseDir(), name));
}

String? _findRepoDocx(String projDir) {
  final d = Directory(projDir);
  if (!d.existsSync()) return null;
  final ents = d.listSync(recursive: false);
  for (final e in ents) {
    if (e is File && e.path.toLowerCase().endsWith('.docx')) {
      return p.normalize(e.path);
    }
  }
  return null;
}

final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

Future<Map<String, dynamic>> createTrackingProject(
    String name, String? docxPath) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final gitDir = Directory(p.join(projDir, '.git'));
  if (!gitDir.existsSync()) {
    await _runGit(['init'], projDir);
  }
  String? repoDocxPath;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    final src = File(docxPath);
    if (src.existsSync()) {
      repoDocxPath = p.normalize(p.join(projDir, p.basename(docxPath)));
      await src.copy(repoDocxPath);
    }
  }
  final tracking = await _readTracking(name);
  tracking['name'] = name;
  if (docxPath != null && docxPath.trim().isNotEmpty) {
    tracking['docxPath'] = _sanitizeFsPath(docxPath);
  }
  if (repoDocxPath != null) {
    tracking['repoDocxPath'] = repoDocxPath;
  }
  await _writeTracking(name, tracking);
  await _startWatcher(name);
  return {
    'name': name,
    'repoPath': projDir,
  };
}

Future<Map<String, dynamic>> openTrackingProject(String name) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }
  final tracking = await _readTracking(name);
  await _startWatcher(name);
  return {
    'name': name,
    'repoPath': projDir,
    'docxPath': tracking['docxPath'],
  };
}

Future<Map<String, dynamic>> updateTrackingProject(String name,
    {String? newDocxPath}) async {
  final projDir = _projectDir(name);
  final dir = Directory(projDir);
  if (!dir.existsSync()) {
    throw Exception('project not found');
  }
  var tracking = await _readTracking(name);
  String? sourcePath = tracking['docxPath'] as String?;
  if (newDocxPath != null && newDocxPath.trim().isNotEmpty) {
    sourcePath = _sanitizeFsPath(newDocxPath);
    tracking['docxPath'] = sourcePath;
  }
  if (sourcePath == null ||
      sourcePath.trim().isEmpty ||
      !File(sourcePath).existsSync()) {
    return {'needDocx': true, 'repoPath': projDir};
  }
  String? repoDocxPath = tracking['repoDocxPath'] as String?;
  if (repoDocxPath == null || repoDocxPath.trim().isEmpty) {
    repoDocxPath =
        _findRepoDocx(projDir) ?? p.join(projDir, p.basename(sourcePath));
    tracking['repoDocxPath'] = repoDocxPath;
  }
  await _writeTracking(name, tracking);
  final src = File(sourcePath);
  if (!src.existsSync()) {
    return {'needDocx': true, 'repoPath': projDir};
  }
  await src.copy(repoDocxPath);
  final status = await _runGit(['status', '--porcelain'], projDir);
  bool changed = status.isNotEmpty;
  if (changed) {
    await _runGit(['add', '-A'], projDir);
    final msg =
        'Update docx ${p.basename(repoDocxPath)} ${DateTime.now().toIso8601String()}';
    await _runGit([
      '-c',
      'user.name=gitdocx',
      '-c',
      'user.email=gitdocx@example.com',
      'commit',
      '-m',
      msg,
    ], projDir);
  }
  return {
    'updated': changed,
    'repoPath': projDir,
  };
}

String _sanitizeFsPath(String raw) {
  var t = raw.trim();
  if ((t.startsWith('"') && t.endsWith('"')) ||
      (t.startsWith('\'') && t.endsWith('\''))) {
    t = t.substring(1, t.length - 1);
  }
  if (t.startsWith('file://')) {
    try {
      final uri = Uri.parse(t);
      t = uri.toFilePath(windows: true);
    } catch (_) {}
  }
  return p.normalize(t);
}

Future<void> _startWatcher(String name) async {
  final tracking = await _readTracking(name);
  final docx = tracking['docxPath'] as String?;
  if (docx == null || docx.trim().isEmpty) return;
  final f = File(docx);
  if (!f.existsSync()) return;
  final sub = _watchers[name];
  if (sub != null) return;
  final s = f.watch(events: FileSystemEvent.modify);
  final subscription = s.listen((_) async {
    try {
      await updateTrackingProject(name);
    } catch (_) {}
  });
  _watchers[name] = subscription;
}

Future<void> initTrackingService() async {
  final base = Directory(_baseDir());
  if (!base.existsSync()) return;
  final ents = base.listSync().whereType<Directory>().toList();
  for (final d in ents) {
    final name = p.basename(d.path);
    await _startWatcher(name);
  }
}
