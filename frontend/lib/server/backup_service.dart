import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_http;
import 'package:archive/archive_io.dart';
import 'models.dart';

import 'package:crypto/crypto.dart';

Future<String> sha1hash(String filePath) async {
  print(filePath);

  try {
    final file = File(filePath);

    if (!file.existsSync()) {
      return "错误：文件 '$filePath' 不存在";
    }

    final stream = file.openRead();
    final digest = await sha1.bind(stream).first;
    return digest.toString();
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode == 13) {
      return "错误：没有权限读取文件 '$filePath'";
    }
    return "错误：${e.message}";
  } catch (e) {
    return "错误：$e";
  }
}

String _baseDir() {
  final app = Platform.environment['APPDATA'];
  if (app != null && app.isNotEmpty)
    return p.join(app, 'gitdocx_history_cache');
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) return p.join(home, '.gitdocx_history_cachex');
  return p.join(Directory.systemTemp.path, 'gitdocx_history_cache');
}

// 使用更加健壮的 Uri 构造方式，避免双斜杠和路径拼接问题
final Uri _backupBaseUri = Uri.parse('https://llinker.com/gitbackup');

// 共享 HttpClient 以复用连接，减少握手开销
// 针对 Windows 优化：禁用系统代理自动探测（这在某些网络下会导致数秒延迟）
final http.Client _sharedClient = () {
  final ioClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 60);
  
  // 针对 Windows 的进一步优化
  // 1. 禁用代理自动探测（WPAD），这在 Windows 上是常见的延迟来源
  ioClient.findProxy = null;
  
  // 2. 增加并发连接数
  ioClient.maxConnectionsPerHost = 10;
  
  // 3. 移除自定义 connectionFactory，因为它可能导致 HTTPS SNI 握手失败
  // 我们依靠 findProxy = null 和共享 Client 来解决大部分延迟问题
  
  return io_http.IOClient(ioClient);
}();

final String _tempDirName = p.join(_baseDir(), 'temp_backups');

// New checkout base directory
final String _checkoutBaseDir =
    p.join(Directory.systemTemp.path, 'gitbin_checkout');

String _getBackupDir(String repoName) {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  return p.join(p.dirname(scriptDir), _tempDirName, repoName);
}

Future<List<Map<String, dynamic>>> listBackupFailures(String username, String repoName) async {
  final url = _backupBaseUri.replace(
    path: '${_backupBaseUri.path}/api/failures/$username',
    queryParameters: {'repo': repoName},
  );
  
  print("${DateTime.now()}: [Failures] Start fetching from $url");
  final startTime = DateTime.now();
  try {
    // DNS 预热/诊断
    try {
      final dnsStart = DateTime.now();
      final addresses = await InternetAddress.lookup(url.host, type: InternetAddressType.IPv4);
      print("${DateTime.now()}: [Failures] DNS lookup (IPv4) for ${url.host} took ${DateTime.now().difference(dnsStart).inMilliseconds}ms (Found: ${addresses.map((a) => a.address).join(', ')})");
    } catch (e) {
      print("${DateTime.now()}: [Failures] DNS lookup failed: $e");
    }

    print("${DateTime.now()}: [Failures] Sending request...");
    final response = await _sharedClient.get(url).timeout(Duration(seconds: 15));
    final duration = DateTime.now().difference(startTime).inMilliseconds;
    print("${DateTime.now()}: [Failures] Response received: ${response.statusCode} (took ${duration}ms)");
    
    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(utf8.decode(response.bodyBytes));
      return list.cast<Map<String, dynamic>>();
    }
  } catch (e) {
    final duration = DateTime.now().difference(startTime).inMilliseconds;
    print('${DateTime.now()}: [Failures] Failed after ${duration}ms: $e');
  }
  return [];
}

Future<Map<String, dynamic>> listBackupCommits(
    String repoName, String AuthToken,
    {Function(double percent, int received, int total)? onProgress}) async {
  print("${DateTime.now()}: listBackupCommits start for $repoName");
  
  // Fix: If repoName is a full path, convert to hash key to match server logic
  String targetRepoName = repoName;

  if (p.isAbsolute(repoName) || repoName.contains(p.separator)) {
     print("==========================================================");
     print("${DateTime.now()}: Debug: resolving repoName: $repoName");
     
     // Method: Try to get remote URL directly from git config
     bool foundViaGit = false;
     if (await Directory(repoName).exists() || await File(repoName).exists()) {
        try {
           final res = await Process.run('git', ['remote', 'get-url', 'origin'], 
              workingDirectory: repoName);
           if (res.exitCode == 0) {
              final url = (res.stdout as String).trim();
              if (url.isNotEmpty) {
                 final uri = Uri.parse(url);
                 String lastSegment = uri.pathSegments.last;
                 targetRepoName = lastSegment.endsWith('.git') 
                    ? lastSegment.substring(0, lastSegment.length - 4) 
                    : lastSegment;
                 print("${DateTime.now()}: Debug: Found targetRepoName via git: $targetRepoName");
                 foundViaGit = true;
              }
           }
        } catch (e) {
           print("${DateTime.now()}: Debug: Failed to get git remote url: $e");
        }
     }

     if (!foundViaGit) {
        final norm = p.normalize(repoName).toLowerCase();
        targetRepoName = md5.convert(utf8.encode(norm)).toString();
        print("${DateTime.now()}: Debug: Fallback MD5: $targetRepoName");
     }
     print("==========================================================");
  }

  final dirPath = _getBackupDir(targetRepoName);
  final dir = Directory(dirPath);
  String LocalSha1 = "";
  if (await File('$dirPath.zip').exists()) {
    LocalSha1 = await sha1hash('$dirPath.zip');
  }

  // 使用 Uri 构造，确保不会出现 //
  final zipUrl = _backupBaseUri.replace(
    path: '${_backupBaseUri.path}/backups/$targetRepoName/download',
    queryParameters: {
      'token': AuthToken,
      'LocalSha1': LocalSha1,
    },
  );
  
  print("${DateTime.now()}: [Commits] URL: $zipUrl");
  
  bool cacheHit = false;
  String? chainViewUrl;

  try {
    print("${DateTime.now()}: [Commits] Sending request to server (using shared client)...");
    final startTime = DateTime.now();
    
    final request = http.Request('GET', zipUrl);
    // 使用超时控制整个发送过程
    final response = await _sharedClient.send(request).timeout(Duration(seconds: 30));
    final headerTime = DateTime.now().difference(startTime).inMilliseconds;
    print("${DateTime.now()}: [Commits] Received response headers (took ${headerTime}ms)");

    if (response.statusCode != 200) {
       final body = await response.stream.bytesToString().timeout(Duration(seconds: 5));
       print("${DateTime.now()}: Error response: $body");
       throw Exception('Failed to download backup: ${response.statusCode}');
    }

    chainViewUrl = response.headers['x-chain-view-url'];
    final ct = response.headers['content-type'] ?? '';
    print("${DateTime.now()}: Content-Type: $ct");

    if (ct.contains('application/json')) {
       final body = await response.stream.bytesToString().timeout(Duration(seconds: 10));
       final jsonData = jsonDecode(body);
       print("${DateTime.now()}: Debug,jsonData=$jsonData");
       if (jsonData["message"] == "success") {
         print("${DateTime.now()}: File up to date (Cache Hit)");
         cacheHit = true;
         if (jsonData.containsKey('chain_url')) {
           chainViewUrl = jsonData['chain_url'];
         }
       }
    } else {
       print("${DateTime.now()}: New file detected! Starting download...");
       cacheHit = false;
       if (await dir.exists()) await dir.delete(recursive: true);
       if (await File('$dirPath.zip').exists()) await File('$dirPath.zip').delete();

       if (!await dir.exists()) {
         final zipFile = File('$dirPath.zip');
         await zipFile.parent.create(recursive: true);
         final contentLength = response.contentLength;
         
         if (onProgress != null) onProgress(0.0, 0, contentLength ?? 0);

         int received = 0;
         final sink = zipFile.openWrite();
         try {
           await response.stream.timeout(Duration(minutes: 5)).listen(
             (List<int> chunk) {
               received += chunk.length;
               sink.add(chunk);
               if (onProgress != null) {
                 final percent = (contentLength != null && contentLength > 0) ? (received / contentLength * 100) : 0.0;
                 onProgress(percent, received, contentLength ?? 0);
               }
             },
             onDone: () => print('${DateTime.now()}: Download complete. ($received bytes)'),
             onError: (e) => throw e,
             cancelOnError: true,
           ).asFuture();
         } finally {
           await sink.close();
         }

         print('${DateTime.now()}: Unzipping $repoName...');
         final res = await Process.run('powershell', [
           '-Command', 'Expand-Archive -Path "${zipFile.path}" -DestinationPath "$dirPath" -Force'
         ]);
         if (res.exitCode != 0) throw Exception('Unzip failed: ${res.stderr}');
       }
    }
  } catch (e) {
    print('${DateTime.now()}: Error during backup sync: $e');
    if (!await File('$dirPath.zip').exists() && !await dir.exists()) throw e;
  }

  print('${DateTime.now()}: Pre-caching snapshots for $targetRepoName...');
  final effectiveRepoPath = await _findEffectiveRepoPath(targetRepoName);
  await _precacheSnapshots(targetRepoName, effectiveRepoPath);

  final commits = await _getCommitsFromDir(effectiveRepoPath, targetRepoName);
  print("${DateTime.now()}: listBackupCommits end for $repoName");
  return {
    'commits': commits,
    'cacheHit': cacheHit,
    'chainViewUrl': chainViewUrl
  };
}

Future<bool> retryBackupFailure(String failureId) async {
  final url = 'https://llinker.com/gitbackup/api/failures/$failureId/retry';
  try {
    final response = await http.post(Uri.parse(url));
    return response.statusCode == 200;
  } catch (e) {
    print('Failed to retry backup failure: $e');
    return false;
  }
}

class Semaphore {
  final int max;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  Semaphore(this.max);

  Future<void> acquire() async {
    if (_current < max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}

Future<void> _precacheSnapshots(String repoName, String repoPath) async {
  print("${DateTime.now()}: _precacheSnapshots start for $repoName");
  final checkoutRoot = Directory(p.join(_checkoutBaseDir, repoName));
  if (!await checkoutRoot.exists()) {
    await checkoutRoot.create(recursive: true);
  }

  // Enable longpaths to support deep nested paths in backup repos
  try {
    await Process.run('git', ['config', 'core.longpaths', 'true'],
        workingDirectory: repoPath);
  } catch (e) {
    print('${DateTime.now()}: Failed to enable longpaths: $e');
  }

  // Get all commit hashes
  final res = await Process.run('git', ['log', '--format=%H'],
      workingDirectory: repoPath);
  if (res.exitCode != 0) {
    throw Exception('Failed to get commits for precache: ${res.stderr}');
  }

  final commits = (res.stdout as String)
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  print('${DateTime.now()}: Found ${commits.length} commits in backup repo.');

  final semaphore = Semaphore(5); // Limit concurrency to 5
  final futures = <Future>[];

  for (final commitId in commits) {
    futures.add(semaphore.acquire().then((_) async {
      try {
        final targetDir = Directory(p.join(checkoutRoot.path, commitId));
        if (await targetDir.exists()) {
          // Repair logic: check if we have a dummy repo but actually have an inner repo
          if (await Directory(p.join(targetDir.path, '.git')).exists()) {
            bool hasInner = false;
            final subs = targetDir.listSync().whereType<Directory>();
            for (final s in subs) {
              if (p.basename(s.path) == '.git') continue;
              if (await File(p.join(s.path, 'HEAD')).exists() &&
                  await File(p.join(s.path, 'config')).exists() &&
                  await Directory(p.join(s.path, 'refs')).exists()) {
                hasInner = true;
                break;
              }
            }
            if (hasInner) {
              print("${DateTime.now()}: Repairing cache: Removing dummy .git folder for $commitId");
              try {
                await Directory(p.join(targetDir.path, '.git'))
                    .delete(recursive: true);
              } catch (e) {
                print("${DateTime.now()}: Failed to delete dummy .git: $e");
              }
            }
          }
          // Skip if already cached
          return;
        }

        print('${DateTime.now()}: Caching snapshot for $commitId...');
        await targetDir.create(recursive: true);

        // Use git archive to extract content without checking out
        // Create a temporary tar file
        final tempTar = File(p.join(targetDir.path, 'temp_archive.tar'));
        
        final archiveRes = await Process.run(
          'git',
          ['archive', '--format=tar', '--output=${tempTar.path}', commitId],
          workingDirectory: repoPath,
        );

        if (archiveRes.exitCode != 0) {
          print('${DateTime.now()}: Failed to archive $commitId: ${archiveRes.stderr}');
          // Clean up partial targetDir?
          // await targetDir.delete(recursive: true);
          return;
        }

        // Extract tar using archive package in a separate isolate to avoid blocking the UI thread
        try {
            final bytes = await tempTar.readAsBytes();
            
            // Define a helper function to extract tar
            final archive = await Isolate.run(() {
              return TarDecoder().decodeBytes(bytes);
            });

            for (final file in archive) {
                final filename = file.name;
                if (file.isFile) {
                    final data = file.content as List<int>;
                    final outFile = File(p.join(targetDir.path, filename));
                    await outFile.parent.create(recursive: true);
                    await outFile.writeAsBytes(data);
                } else {
                    await Directory(p.join(targetDir.path, filename)).create(recursive: true);
                }
            }
        } catch (e) {
            print('${DateTime.now()}: Error extracting tar for $commitId: $e');
        } finally {
            if (await tempTar.exists()) {
                await tempTar.delete();
            }
        }
        
        // Check if we have a bare repo in subdirectories
        bool hasBareRepo = false;
        final subs = targetDir.listSync().whereType<Directory>();
        for (final s in subs) {
          if (p.basename(s.path) == '.git') continue;
          if (await File(p.join(s.path, 'HEAD')).exists() && 
              await File(p.join(s.path, 'config')).exists() && 
              await Directory(p.join(s.path, 'refs')).exists()) {
            hasBareRepo = true;
            break;
          }
        }

        // Ensure targetDir is a valid git repo (so getGraph works correctly for comparison)
        // If the snapshot itself doesn't contain a .git folder (which it likely doesn't if it's just a file backup),
        // we create a dummy one.
        if (!hasBareRepo && !await Directory(p.join(targetDir.path, '.git')).exists()) {
            await Process.run('git', ['init'], workingDirectory: targetDir.path);
            await Process.run('git', ['config', 'user.email', 'backup@local'], workingDirectory: targetDir.path);
            await Process.run('git', ['config', 'user.name', 'BackupBot'], workingDirectory: targetDir.path);
            await Process.run('git', ['add', '.'], workingDirectory: targetDir.path);
            await Process.run('git', ['commit', '-m', 'Snapshot state'], workingDirectory: targetDir.path);
        }
      } catch (e, s) {
        print('${DateTime.now()}: Error processing snapshot $commitId: $e\n$s');
      } finally {
        semaphore.release();
      }
    }));
  }

  await Future.wait(futures);
  print("${DateTime.now()}: _precacheSnapshots end for $repoName");
}

Future<List<Map<String, dynamic>>> _getCommitsFromDir(
    String repoPath, String repoName) async {
  print("${DateTime.now()}: Execute _getCommitsFromDir with param repoPath=$repoPath");
  
  // Previously we checked for cached snapshots here, but now we rely on the backup repo's git history directly.
  
  final result = await Process.run(
    'git',
    [
      'log',
      '--pretty=format:%H|%P|%an|%ad|%s',
      '--date=iso',
      'master', // Assuming master branch of parent repo
    ],
    workingDirectory: repoPath,
    stdoutEncoding: utf8, // Explicitly use utf8 to prevent encoding issues on Windows
  );

  if (result.exitCode != 0) {
    // If git log failed and we didn't find snapshots above, it's a real error
    var stackTrace = StackTrace.current;
    print('${DateTime.now()}: 调用栈信息：');
    print(stackTrace);
    throw Exception('Git log failed and no snapshots found: ${result.stderr}');
  }

  final lines = (result.stdout as String).split('\n');
  final commits = <Map<String, dynamic>>[];
  // Robust regex: skip anything until the first digit of the timestamp
  final timeRegex = RegExp(r'snapshot time.*?(\d[\d.]+)');

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('|');
    if (parts.length < 5) continue;

    final id = parts[0];
    final parents = parts[1].split(' ').where((s) => s.isNotEmpty).toList();
    final author = parts[2];
    String date = parts[3];
    final subject = parts.sublist(4).join('|');

    // Parse snapshot time from subject if available
    final match = timeRegex.firstMatch(subject);
    if (match != null) {
      try {
        final unixTimestamp = double.parse(match.group(1)!);
        final dt = DateTime.fromMillisecondsSinceEpoch((unixTimestamp * 1000).toInt());
        date = dt.toLocal().toString();
      } catch (e) {
        print("${DateTime.now()}: Error parsing snapshot time: $e");
      }
    }

    commits.add({
      'id': id,
      'parents': parents,
      'refs': [],
      'author': author,
      'date': date,
      'subject': subject,
    });
    print("${DateTime.now()}: Found backup commit: $id, date: $date");
  }

  // Sort commits by date descending (newest first)
  commits.sort((a, b) {
    try {
      final da = DateTime.parse(a['date']);
      final db = DateTime.parse(b['date']);
      return db.compareTo(da);
    } catch (e) {
      return 0;
    }
  });

  print("${DateTime.now()}: _getCommitsFromDir end for $repoName");
  return commits;
}

Future<String> _findEffectiveRepoPath(String repoName) async {
  final repoDir = _getBackupDir(repoName);
  print("Searching for repo in: $repoDir");

  // 1. Check if repoDir itself is a git repo
  if (await Directory(p.join(repoDir, '.git')).exists()) {
    return repoDir;
  }

  // 2. Check if repoDir/<repoName>_parent is a git repo
  final parentDir = Directory(p.join(repoDir, '${repoName}_parent'));
  if (await parentDir.exists() && await Directory(p.join(parentDir.path, '.git')).exists()) {
    return parentDir.path;
  }

  // 3. Fallback: Check immediate subdirectories
  final dir = Directory(repoDir);
  if (await dir.exists()) {
      final subs = dir.listSync().whereType<Directory>();
      for(final sub in subs) {
          if (await Directory(p.join(sub.path, '.git')).exists()) {
              return sub.path;
          }
      }
  }

  throw Exception('Parent repository not found in $repoDir');
}

Future<String> resolveSnapshotGitPath(String repoName, String commitId) async {
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);

  if (!await snapshotDir.exists()) {
    throw Exception('Snapshot not found for $commitId');
  }

  String gitDir = snapshotPath;
  
  // First check for inner bare repo, as it is the most specific content
  bool foundInner = false;
  final subs = snapshotDir.listSync().whereType<Directory>();
  for (final s in subs) {
      if (p.basename(s.path) == '.git') continue;
      if (await File(p.join(s.path, 'HEAD')).exists() && 
          await File(p.join(s.path, 'config')).exists() && 
          await Directory(p.join(s.path, 'refs')).exists()) {
        gitDir = s.path;
        foundInner = true;
        break;
      }
  }

  if (!foundInner) {
      if (await Directory(p.join(snapshotPath, '.git')).exists()) {
        gitDir = p.join(snapshotPath, '.git');
      } else {
        // Check if it looks like a bare repo/embedded git dir
        if (!await File(p.join(snapshotPath, 'HEAD')).exists()) {
          // Maybe inside a subdir?
          for (final s in subs) {
            if (await Directory(p.join(s.path, '.git')).exists()) {
              gitDir = p.join(s.path, '.git');
              break;
            }
          }
        }
      }
  }
  return gitDir;
}

Future<Map<String, dynamic>> getBackupChildGraph(
    String repoName, String commitId) async {
  final gitDir = await resolveSnapshotGitPath(repoName, commitId);
  return (await _getGraphFromGitDir(gitDir)).toJson();
}

Future<String> getSnapshotPath(String repoName, String commitId) async {
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);
  if (!await snapshotDir.exists()) {
    // Try to ensure it exists? Or just throw
    throw Exception('Snapshot not found for $commitId');
  }
  return snapshotPath;
}

Future<GraphResponse> _getGraphFromGitDir(String gitDir, {int? limit}) async {
  // We can use git --git-dir=... log ...
  // branches
  final branches = await _getBranchesFromGitDir(gitDir);
  final chains =
      await _getBranchChainsFromGitDir(gitDir, branches, limit: limit);
  final current = await _getCurrentBranchFromGitDir(gitDir);
  print("gitDir=$gitDir");
  print("branches=$branches");
  print("current=$current");

  final logArgs = [
    '--git-dir=$gitDir',
    'log',
    '--branches',
    '--tags',
    '--date=iso',
    '--encoding=UTF-8',
    '--pretty=format:%H|%P|%d|%s|%an|%ad',
    '--topo-order',
  ];
  if (limit != null && limit > 0) {
    logArgs.add('--max-count=$limit');
  }

  final res =
      await Process.run('git', logArgs, stdoutEncoding: utf8);
  if (res.exitCode != 0) throw Exception('Git log failed: ${res.stderr}');

  final lines = LineSplitter.split(res.stdout as String).toList();
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

  return GraphResponse(
      commits: commits,
      branches: branches,
      chains: chains,
      currentBranch: current);
}

Future<List<Branch>> _getBranchesFromGitDir(String gitDir) async {
  final res = await Process.run('git', [
    '--git-dir=$gitDir',
    'for-each-ref',
    '--format=%(refname:short)|%(objectname)',
    'refs/heads',
  ]);
  final lines = LineSplitter.split(res.stdout as String).toList();
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

Future<GraphResponse> getBackupGraph(String repoName, String commitId) async {
  final gitDir = await resolveSnapshotGitPath(repoName, commitId);
  return _getGraphFromGitDir(gitDir);
}

Future<Map<String, List<String>>> _getBranchChainsFromGitDir(
    String gitDir, List<Branch> branches,
    {int? limit}) async {
  final result = <String, List<String>>{};
  for (final b in branches) {
    final args = [
      '--git-dir=$gitDir',
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
    final res = await Process.run('git', args);
    final lines = LineSplitter.split(res.stdout as String).toList();
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

Future<String?> _getCurrentBranchFromGitDir(String gitDir) async {
  // For bare repo, HEAD might point to a branch
  try {
    final res = await Process.run('git',
        ['--git-dir=$gitDir', 'symbolic-ref', '--short', 'HEAD']);
    if (res.exitCode == 0) return (res.stdout as String).trim();
  } catch (_) {}
  return null;
}

// Copied from git_service.dart
List<String> _parseRefs(String decoration) {
  final s = decoration.trim();
  if (s.isEmpty) return <String>[];
  final start = s.indexOf('(');
  final end = s.lastIndexOf(')');
  if (start < 0 || end < 0 || end <= start) return <String>[];
  final inner = s.substring(start + 1, end);
  final items = inner.split(',');
  final refs = <String>{};
  for (var i in items) {
    final t = i.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('origin/')) continue;
    final cleaned = t
        .replaceAll(RegExp(r'^HEAD ->\s*'), '')
        .replaceAll(RegExp(r'^tag:\s*'), '');
    refs.add(cleaned);
  }
  return refs.toList();
}

Future<List<int>> previewBackupChildDoc(
    String repoName, String commitId) async {
  // Use cached snapshot
  final snapshotPath = p.join(_checkoutBaseDir, repoName, commitId);
  final snapshotDir = Directory(snapshotPath);

  if (!await snapshotDir.exists()) {
    throw Exception('Snapshot not found for $commitId');
  }

  // Find docx in snapshot (it's just a folder now)
  // Recursively search for docx
  final files = snapshotDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => p.extension(f.path).toLowerCase() == '.docx')
      .toList();

  if (files.isEmpty) {
    throw Exception('No docx file found in snapshot');
  }

  final docxPath = files.first.path;

  // Convert
  final tmp = await Directory.systemTemp.createTemp('backup_preview_');
  try {
    // Copy docx to temp
    final inPath = p.join(tmp.path, 'temp.docx');
    await File(docxPath).copy(inPath);

    final scriptPath = p.fromUri(Platform.script);
    final repoRoot = p.dirname(p.dirname(p.dirname(scriptPath)));
    final psScript = p.join(repoRoot, 'frontend', 'lib', 'docx2pdf.ps1');
    final pdfPath = p.join(tmp.path, 'temp.pdf');

    final result = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      psScript,
      '-InputPath',
      inPath,
      '-OutputPath',
      pdfPath
    ]);

    if (result.exitCode != 0) {
      throw Exception('Conversion failed: ${result.stderr}');
    }

    if (!await File(pdfPath).exists()) {
      throw Exception('PDF not generated');
    }

    return await File(pdfPath).readAsBytes();
  } finally {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  }
}
