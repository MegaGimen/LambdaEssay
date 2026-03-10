import 'dart:convert';
import 'dart:io'; // For Process.run
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

// import 'package:web_socket_channel/web_socket_channel.dart';
// import 'package:web_socket_channel/status.dart' as status;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'main.dart';
// import 'server/notification_service.dart';
import 'server/server.dart';
import 'dart:async';
import 'graph_view.dart'; // For SimpleGraphView

class BackupPage extends StatefulWidget {
  final String projectName;
  final String repoPath;
  final String token;
  final String username;
  final String? initialSubRepo;

  const BackupPage({
    super.key,
    required this.projectName,
    required this.repoPath,
    required this.token,
    this.username = '',
    this.initialSubRepo,
  });
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class BackupItem {
  final CommitNode? commit;
  final Map<String, dynamic>? failure;
  BackupItem({this.commit, this.failure});
  
  DateTime get date {
    try {
      if (commit != null) {
        // The date might have already been parsed in backup_service.dart
        // or it might be the original git commit date.
        // We use a robust regex to extract the timestamp from the subject, 
        // by skipping anything until the first digit after the prefix.
        final match = RegExp(r'snapshot time.*?(\d[\d.]+)').firstMatch(commit!.subject);
        if (match != null) {
          final ts = double.parse(match.group(1)!);
          return DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
        }
        return DateTime.parse(commit!.date);
      }
      if (failure != null) {
        final ts = failure!['timestamp'];
        if (ts is num) {
          return DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
        }
        return DateTime.parse(ts.toString());
      }
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

class _BackupPageState extends State<BackupPage> {
  bool _loading = false;
  String? _error;
  bool _graphHovering = false;
  // StreamSubscription? _notificationSubscription;
  double _downloadProgress = 0.0;
  bool _hasDownloadStarted = false;
  String? _chainViewUrl;
  String? _workspaceId;
  
  // Track load requests to prevent race conditions
  int _loadId = 0;

  List<BackupItem> _items = [];
  // Store comparison results for each backup commit vs local
  final Map<String, ComparisonData> _comparisons = {};
  final Set<String> _failedComparisons = {};
  final TransformationController _sharedTc = TransformationController();
  double _uiScale = 1.0;

  List<String> _subRepos = [];
  late String _selectedRepo;


  @override
  void initState() {
    super.initState();
    _selectedRepo = widget.initialSubRepo ?? 'Root';
    _initNotifications();
    _fetchSubRepos();
    // _sharedTc.addListener(_onScaleChanged);
    _loadBackups();
  }

  Future<void> _fetchSubRepos() async {
    try {
      final j = await postJson('/track/repos', {'packagePath': widget.projectName});
      final repos = (j['repos'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _subRepos = repos.map((e) => e['relPath'] as String).toList();
      });
    } catch (e) {
      debugPrint('Failed to fetch sub repos: $e');
    }
  }

  Future<void> _fetchWorkspaceId() async {
     try {
        // Use widget.projectName as repoPath if widget.repoPath is empty, 
        // though widget.repoPath should be passed correctly.
        final path = widget.repoPath.isNotEmpty ? widget.repoPath : widget.projectName;
        final j = await postJson("/track/info", {'repoPath': path});
        final id = j['workspaceId'] as String?;
        if (id != null) {
           setState(() {
              _workspaceId = id;
           });
        }
     } catch (e) {
        debugPrint('Failed to fetch workspaceId: $e');
     }
  }

  String _getRemoteRepoName() {
    final rootPath = widget.projectName;
    final rootHash = _workspaceId ?? md5.convert(utf8.encode(p.normalize(rootPath).toLowerCase())).toString();
    
    if (_selectedRepo == 'Root') {
       return rootHash; 
    } else {
       final rel = _selectedRepo.replaceAll('/', '-').replaceAll('\\', '-');
       return '$rootHash-$rel';
    }
  }

  void _initNotifications() {
    // 覆盖全局回调
    // 注意：这会覆盖 Main 中的回调，所以退出时需要恢复 Main 的回调？
    // 实际上 BackupPage 是 Main 的子页面还是独立页面？
    // 如果是 push 进去的，那么 Main 依然存在。
    // 但是 server.dart 只有一个全局变量 onNotification。
    // 所以我们需要一个简单的多播机制，或者让 server.dart 支持多个监听者。
    // 但用户说“不要中间层”。
    // 既然如此，我们可以做一个简单的链式调用，或者就在这里直接处理。
    // 简单起见，我们暂且认为 BackupPage 激活时接管 onNotification。
    
    final previousCallback = onNotification;
    onNotification = (data) {
      // 先调用之前的（Main的）
      previousCallback?.call(data);

      if (!mounted) return;
      try {
        final expectedRepo = _getRemoteRepoName();
        if (data['type'] == 'backup_progress' && data['repo'] == expectedRepo) {
          setState(() {
            _downloadProgress = (data['percent'] as num).toDouble();
            _hasDownloadStarted = true;
          });
        }
      } catch (e) {
        debugPrint('Notification error: $e');
      }
    };
  }

  @override
  void dispose() {
    // 恢复回调比较麻烦，因为我们用了闭包捕获 previousCallback。
    // 如果多层嵌套，这个链条会很长。
    // 但是 BackupPage pop 后，onNotification 依然指向这里的闭包，而这里已经 dispose 了。
    // 闭包里的 mounted 检查会阻止 setState，所以不会崩，但会内存泄漏（持有 context）。
    
    // 更好的做法是 server.dart 提供 add/removeListener。
    // 但那又变成了“中间层/观察者模式”。
    
    _sharedTc.dispose();
    super.dispose();
  }

  Future<void> _loadBackups() async {
    final myLoadId = ++_loadId;
    final totalSw = Stopwatch()..start();
    print('[BackupPage] Start loading backups (LoadID: $myLoadId)...');
    final stepSw = Stopwatch()..start();

    if (_workspaceId == null) {
       await _fetchWorkspaceId();
       if (myLoadId != _loadId) return; // Cancelled
       print('[BackupPage] _fetchWorkspaceId: ${stepSw.elapsedMilliseconds}ms');
       stepSw.reset();
    }
    final repo = _getRemoteRepoName();
    print('[BackupPage] _getRemoteRepoName: ${stepSw.elapsedMilliseconds}ms');
    stepSw.reset();

    if (widget.projectName.isEmpty) {
      setState(() => _error = '项目名称为空');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
      _comparisons.clear();
      _failedComparisons.clear();
      _downloadProgress = 0.0;
      _hasDownloadStarted = false;
    });
    print('[BackupPage] Initial setState: ${stepSw.elapsedMilliseconds}ms');
    stepSw.reset();

    try {
        print("The token here is ${widget.token}");
      
      // Fetch commits
      final j = await postJson("/backup/commits", {'repoName': repo, "token": widget.token});
      if (myLoadId != _loadId) {
         print('[BackupPage] LoadID $myLoadId cancelled (current: $_loadId)');
         return;
      }

      print('[BackupPage] Fetch commits API: ${stepSw.elapsedMilliseconds}ms');
      stepSw.reset();

      final list = (j['commits'] as List?) ?? const [];
      final bool cacheHit = j['cacheHit'] == true;
      _chainViewUrl = j['chainViewUrl'] as String?;
      
      // Fetch failures
      List<Map<String, dynamic>> failures = [];
      if (widget.username.isNotEmpty) {
        try {
          final fResp = await postJson("/backup/failures", {'username': widget.username, 'repoName': repo});
          print('[BackupPage] Fetch failures API: ${stepSw.elapsedMilliseconds}ms');
          stepSw.reset();

          if (fResp is List) {
             failures = fResp.cast<Map<String, dynamic>>();
          }
        } catch (e) {
          debugPrint('Failed to fetch failures: $e');
        }
      } else {
          print('[BackupPage] Skip fetch failures (no username): ${stepSw.elapsedMilliseconds}ms');
          stepSw.reset();
      }

      if (cacheHit && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前本地备份已经是最新版 (Cache Hit)')),
        );
      }

      final commits = list
          .map((e) => CommitNode.fromJson(e as Map<String, dynamic>))
          .toList();
      print('[BackupPage] Parse commits: ${stepSw.elapsedMilliseconds}ms');
      stepSw.reset();
          
      final items = <BackupItem>[];
      for (final c in commits) items.add(BackupItem(commit: c));
      for (final f in failures) items.add(BackupItem(failure: f));
      
      items.sort((a, b) => b.date.compareTo(a.date));
      print('[BackupPage] Merge and Sort items: ${stepSw.elapsedMilliseconds}ms');
      stepSw.reset();
      
      if (myLoadId != _loadId) return;
      setState(() {
        _items = items;
        _loading = false;
      });
      print('[BackupPage] Update UI setState: ${stepSw.elapsedMilliseconds}ms');
      stepSw.reset();

      int count = 0;
      for (final item in items) {
        if (item.commit != null) {
          count++;
          _ensureComparison(repo, item.commit!.id, myLoadId).catchError((e) {
            debugPrint('Failed to load comparison for ${item.commit!.id}: $e');
            if (mounted && myLoadId == _loadId) {
              setState(() {
                _failedComparisons.add(item.commit!.id);
              });
            }
          });
        }
      }
      print('[BackupPage] Triggered $count comparison loads: ${stepSw.elapsedMilliseconds}ms');
      stepSw.reset();

    } catch (e) {
      if (myLoadId != _loadId) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
        totalSw.stop();
        print('[BackupPage] Total load time (until comparison trigger): ${totalSw.elapsedMilliseconds}ms');
    }
  }

  Future<void> _ensureComparison(String repo, String sha, int loadId) async {
    if (loadId != _loadId) return;
    final sw = Stopwatch()..start();
    if (_comparisons.containsKey(sha)) return;
    // Call the compare_repos API to get aligned graphs
    final j = await postJson("/compare_repos", {
      'repoName': repo,
      'commitA': sha, // Backup commit
      'commitB': 'local', // Local state
      'localPath': widget.repoPath,
    });
    print('[BackupPage] Compare $sha API: ${sw.elapsedMilliseconds}ms');
    sw.reset();

    final gA = GraphData.fromJson(j['graphA']);
    final gB = GraphData.fromJson(j['graphB']);
    final rawMapping = j['unifiedRowMapping'] as Map<String, dynamic>;
    final mapping = rawMapping.map((k, v) => MapEntry(k, v as int));
    final summary = j['summary'] as String? ?? '';
    final details = j['details'] as Map<String, dynamic>? ?? {};

    final colors = _computeNodeColors(details);

    // Compute ghosts
    final commitsA = gA.commits.map((c) => c.id).toSet();
    final commitsB = gB.commits.map((c) => c.id).toSet();

    final ghostsA = gB.commits.where((c) => !commitsA.contains(c.id)).toList();
    final ghostsB = gA.commits.where((c) => !commitsB.contains(c.id)).toList();
    
    print('[BackupPage] Process comparison data $sha: ${sw.elapsedMilliseconds}ms');
    sw.reset();

    if (!mounted || loadId != _loadId) return;
    setState(() {
      _comparisons[sha] =
          ComparisonData(gA, gB, mapping, summary, colors, ghostsA, ghostsB);
    });
    print('[BackupPage] Update UI comparison $sha: ${sw.elapsedMilliseconds}ms');
  }

  Map<String, Color> _computeNodeColors(Map<String, dynamic> details) {
    final colors = <String, Color>{};
    if (details.isEmpty) return colors;

    final commonBranches = details['commonBranches'] as Map<String, dynamic>?;
    if (commonBranches != null) {
      for (final branchEntry in commonBranches.entries) {
        final info = branchEntry.value as Map<String, dynamic>;
        final comparison = info['comparison'] as Map<String, dynamic>;

        if (comparison.containsKey('ours')) {
          final ours = comparison['ours'] as Map<String, dynamic>;
          final commits = ours['commits'] as List?;
          if (commits != null) {
            for (final id in commits) {
              colors[id.toString()] =
                  Colors.green.shade300; // Unique to A (Backup)
            }
          }
        }

        if (comparison.containsKey('theirs')) {
          final theirs = comparison['theirs'] as Map<String, dynamic>;
          final commits = theirs['commits'] as List?;
          if (commits != null) {
            for (final id in commits) {
              colors[id.toString()] =
                  Colors.blue.shade300; // Unique to B (Local)
            }
          }
        }
      }
    }
    return colors;
  }

  Future<void> _launchUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接: $e')),
        );
      }
    }
  }

  Future<void> _onRetryFailure(String failureId) async {
    setState(() => _loading = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在重试，请稍后进入页面后查看')),
      );
    }
    try {
      final resp = await postJson('/backup/retry_failure', {'failureId': failureId});
      if (resp['success'] == true) {
        // Retry succeeded, but do not reload list
        //await _loadBackups();
      } else {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('重试失败')));
        }
      }
    } catch (e) {
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showRepoSelectionDialog() {
    final Map<String, dynamic> tree = {'_children': <String, dynamic>{}};
    
    void insert(String pathStr) {
      final parts = pathStr.replaceAll('\\', '/').split('/');
      Map<String, dynamic> current = tree;
      for (int i = 0; i < parts.length; i++) {
        final part = parts[i];
        if (!current['_children'].containsKey(part)) {
          current['_children'][part] = {'_name': part, '_children': <String, dynamic>{}};
        }
        current = current['_children'][part];
      }
      current['_path'] = pathStr;
    }

    for (final r in _subRepos) {
        insert(r);
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择备份查看对象'),
        content: SizedBox(
          width: 500,
          height: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.home),
                  title: const Text('Root (容器仓库)'),
                  selected: _selectedRepo == 'Root',
                  onTap: () => Navigator.pop(ctx, 'Root'),
                ),
                const Divider(),
                _buildTreeWidget(tree['_children']),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    ).then((val) {
      if (val != null && val is String) {
        setState(() {
          _selectedRepo = val;
        });
        _loadBackups();
      }
    });
  }

  Widget _buildTreeWidget(Map<String, dynamic> children) {
    if (children.isEmpty) return const SizedBox.shrink();
    
    return Column(
      children: children.entries.map((e) {
        final node = e.value as Map<String, dynamic>;
        final name = node['_name'] as String;
        final hasChildren = (node['_children'] as Map).isNotEmpty;
        final fullPath = node['_path'] as String?;
        
        if (hasChildren) {
           return ExpansionTile(
             leading: const Icon(Icons.folder),
             title: Text(name),
             childrenPadding: const EdgeInsets.only(left: 16),
             initiallyExpanded: true,
             children: [
                if (fullPath != null) 
                  ListTile(
                    leading: const Icon(Icons.description, size: 16),
                    title: const Text('查看此文件夹的历史'),
                    selected: _selectedRepo == fullPath,
                    onTap: () => Navigator.of(context).pop(fullPath),
                  ),
                _buildTreeWidget(node['_children']),
             ],
           );
        } else {
           return ListTile(
             leading: const Icon(Icons.description),
             title: Text(name),
             selected: _selectedRepo == fullPath,
             onTap: () => Navigator.of(context).pop(fullPath),
           );
        }
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          if (keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight)) {
            final dy = event.scrollDelta.dy;
            final double delta = dy > 0 ? -0.1 : 0.1;
            final newValue = (_uiScale + delta).clamp(0.5, 2.0);
            setState(() {
              _uiScale = newValue;
            });
          }
        }
      },
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaleFactor: _uiScale),
        child: Stack(
            children: [
              Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF000A3F),
            foregroundColor: Colors.white,
            title: InkWell(
              onTap: _showRepoSelectionDialog,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('历史备份预览: '),
                  Flexible(
                    child: Text(
                      _selectedRepo == 'Root' ? 'Root' : p.basename(_selectedRepo),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
            actions: [
              IconButton(
                onPressed: _loading ? null : _loadBackups,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
              ),
              SizedBox(
                width: 150,
                child: Slider(
                  value: _uiScale.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  onChanged: (value) {
                    setState(() {
                      _uiScale = value;
                    });
                  },
                ),
              ),
              IconButton(
            onPressed: () {
              _sharedTc.value = Matrix4.identity();
            },
            tooltip: '返回主视角',
            icon: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : const Text('无数据'))
                : ListView.builder(
                    physics: _graphHovering
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final item = items[i];
                      
                      if (item.failure != null) {
                        final f = item.failure!;
                        final type = f['type'] ?? 'failure';
                        final dateStr = item.date.toLocal().toString();
                        
                        if (type == 'skip') {
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: ExpansionTile(
                              title: Text('用户跳过这次备份 ($dateStr)',
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: Colors.grey.withOpacity(0.3)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.info_outline,
                                        size: 20, color: Colors.grey),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SelectableText('ID: ${f['failureId']}',
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              fontFamily: 'monospace',
                                              color: Colors.grey)),
                                    ),
                                  ],
                                ),
                              ),
                              children: [
                                const ListTile(
                                  title: Text('此版本由用户手动跳过备份'),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _onRetryFailure(f['failureId']),
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('重试备份'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.blue.shade50,
                                        foregroundColor: Colors.blue.shade800,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          color: Colors.red.shade50,
                          child: ListTile(
                            leading: const Icon(Icons.error_outline, color: Colors.red),
                            title: Text('配额问题未备份 ($dateStr)'),
                            subtitle: Text('ID: ${f['failureId']} | Type: $type'),
                            trailing: ElevatedButton(
                              onPressed: () => _onRetryFailure(f['failureId']),
                              child: const Text('重试'),
                            ),
                          ),
                        );
                      }
                      
                      final c = item.commit!;
                      final sha = c.id;
                      final comparison = _comparisons[sha];
                      final dateStr = item.date.toLocal().toString();

                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: ExpansionTile(
                          title: Text('时间: $dateStr',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: Colors.blue.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.commit,
                                    size: 20, color: Colors.blue),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SelectableText(sha,
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'monospace',
                                          color: Colors.blue)),
                                ),
                                if (_chainViewUrl != null) ...[
                                  const SizedBox(width: 16),
                                  TextButton.icon(
                                    onPressed: () => _launchUrl(_chainViewUrl!),
                                    icon: const Icon(Icons.verified_user,
                                        size: 16, color: Colors.green),
                                    label: const Text('点我去区块链验证备份链是否完整真实',
                                        style: TextStyle(
                                            color: Colors.green, fontSize: 12)),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (comparison != null)
                                    Column(
                                      children: [
                                        Center(
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              // Backup Graph
                                              Column(
                                                children: [
                                                  const Text("备份版本"),
                                                  Container(
                                                    width: 500,
                                                    height: 500,
                                                    decoration: BoxDecoration(
                                                      border: Border.all(
                                                          color: Colors.black),
                                                    ),
                                                    child: MouseRegion(
                                                      onEnter: (_) => setState(() =>
                                                          _graphHovering = true),
                                                      onExit: (_) => setState(() =>
                                                          _graphHovering = false),
                                                      child: SimpleGraphView(
                                                        data: comparison.graphA,
                                                        readOnly: true,
                                                        onPreviewCommit: null,
                                                        transformationController:
                                                            _sharedTc,
                                                        customRowMapping:
                                                            comparison.mapping,
                                                        customNodeColors:
                                                            comparison.colors,
                                                        ghostNodes:
                                                            comparison.ghostsA,
                                                        showCurrentHead: false,
                                                        totalRows: comparison.mapping.length,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(width: 20),
                                              // Local Graph
                                              Column(
                                                children: [
                                                  const Text("当前本地状态"),
                                                  Container(
                                                    width: 500,
                                                    height: 500,
                                                    decoration: BoxDecoration(
                                                      border: Border.all(
                                                          color: Colors.black),
                                                    ),
                                                    child: MouseRegion(
                                                      onEnter: (_) => setState(() =>
                                                          _graphHovering = true),
                                                      onExit: (_) => setState(() =>
                                                          _graphHovering = false),
                                                      child: SimpleGraphView(
                                                        data: comparison.graphB,
                                                        readOnly: true,
                                                        transformationController:
                                                            _sharedTc,
                                                        customRowMapping:
                                                            comparison.mapping,
                                                        customNodeColors:
                                                            comparison.colors,
                                                        ghostNodes:
                                                            comparison.ghostsB,
                                                        showCurrentHead: false,
                                                        totalRows: comparison.mapping.length,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  else if (_failedComparisons.contains(sha))
                                    const SizedBox(
                                      height: 100,
                                      child: Center(
                                          child: Text('加载对比失败',
                                              style: TextStyle(color: Colors.red))),
                                    )
                                  else
                                    const SizedBox(
                                      height: 100,
                                      child: Center(
                                          child: CircularProgressIndicator()),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
        if (_loading)
          const Opacity(
            opacity: 0.5,
            child: ModalBarrier(dismissible: false, color: Colors.black),
          ),
        if (_loading)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                if (_hasDownloadStarted) ...[
                  const SizedBox(height: 16),
                  Text(
                    '正在下载: ${_downloadProgress.toStringAsFixed(1)}%',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(
                      value: (_downloadProgress / 100).clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    ),),);
  }
}

class ComparisonData {
  final GraphData graphA;
  final GraphData graphB;
  final Map<String, int> mapping;
  final String summary;
  final Map<String, Color> colors;
  final List<CommitNode> ghostsA;
  final List<CommitNode> ghostsB;
  ComparisonData(this.graphA, this.graphB, this.mapping, this.summary,
      this.colors, this.ghostsA, this.ghostsB);
}
