import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'visualize.dart';

void main() {
  runApp(const GitGraphApp());
}

class GitGraphApp extends StatelessWidget {
  const GitGraphApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Graph',
      theme: ThemeData.light(),
      home: const GraphPage(),
    );
  }
}

class CommitNode {
  final String id;
  final List<String> parents;
  final List<String> refs;
  final String author;
  final String date;
  final String subject;
  CommitNode({
    required this.id,
    required this.parents,
    required this.refs,
    required this.author,
    required this.date,
    required this.subject,
  });
  factory CommitNode.fromJson(Map<String, dynamic> j) => CommitNode(
        id: j['id'],
        parents: (j['parents'] as List).cast<String>(),
        refs: (j['refs'] as List).cast<String>(),
        author: j['author'],
        date: j['date'],
        subject: j['subject'],
      );
}

class Branch {
  final String name;
  final String head;
  Branch({required this.name, required this.head});
  factory Branch.fromJson(Map<String, dynamic> j) =>
      Branch(name: j['name'], head: j['head']);
}

class EdgeInfo {
  final String child;
  final String parent;
  final List<String> branches;
  EdgeInfo({required this.child, required this.parent, required this.branches});
}

class GraphData {
  final List<CommitNode> commits;
  final List<Branch> branches;
  final Map<String, List<String>> chains;
  final String? currentBranch;
  GraphData({
    required this.commits,
    required this.branches,
    required this.chains,
    this.currentBranch,
  });
  factory GraphData.fromJson(Map<String, dynamic> j) => GraphData(
        commits: ((j['commits'] as List).map(
          (e) => CommitNode.fromJson(e as Map<String, dynamic>),
        )).toList(),
        branches: ((j['branches'] as List).map(
          (e) => Branch.fromJson(e as Map<String, dynamic>),
        )).toList(),
        chains: (j['chains'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).cast<String>()),
        ),
        currentBranch: j['currentBranch'],
      );
}

class WorkingState {
  final bool changed;
  final String? baseId;
  WorkingState({required this.changed, this.baseId});
}

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final TextEditingController pathCtrl = TextEditingController();
  final TextEditingController limitCtrl = TextEditingController(text: '500');
  final TextEditingController docxPathCtrl = TextEditingController();
  GraphData? data;
  String? error;
  bool loading = false;
  String? currentProjectName;
  WorkingState? working;

  final TextEditingController userCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController verifyCodeCtrl = TextEditingController();
  bool _isRegisterMode = false;

  String? _username;
  String? _token;

  static const String baseUrl = 'http://localhost:8080';

  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  Future<void> _checkLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('git_username');
    final password = prefs.getString('git_password');

    // 不再从 SharedPreferences 读取 token
    // final token = prefs.getString('git_token');

    setState(() {
      _username = username;
      // _token = token;
    });

    if (username != null && password != null) {
      // Refresh tokens automatically
      try {
        final resp = await _postJson('$baseUrl/create_user', {
          'username': username,
          'password': password,
        });

        final tokens = resp['tokens'] as List?;
        if (tokens != null && tokens.isNotEmpty) {
          // 取第一个 token 的 sha1 当作 token (authKey)
          final firstToken = tokens[0];
          String? newToken;
          if (firstToken is Map) {
            newToken = firstToken['sha1'];
          }

          if (newToken != null) {
            setState(() {
              _token = newToken;
            });
            print("AuthKey refreshed automatically: $_token");
          }
        }
      } catch (e) {
        print("Failed to refresh tokens: $e");
        // If refresh fails (e.g. password changed or network error),
        // maybe we should not logout automatically to let user work offline if needed,
        // but usually auth error means we should logout.
        // For now just log error.
      }
    }
  }

  Future<bool> _ensureToken() async {
    if (_token != null) return true;
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('git_username');
    final password = prefs.getString('git_password');
    if (username != null && password != null) {
      // Try to get token
      try {
        final resp = await _postJson('$baseUrl/create_user', {
          'username': username,
          'password': password,
        });
        final tokens = resp['tokens'] as List?;
        if (tokens != null && tokens.isNotEmpty) {
          final firstToken = tokens[0];
          if (firstToken is Map) {
            setState(() {
              _token = firstToken['sha1'];
              _username = username; // Ensure username is set
            });
            return true;
          }
        }
      } catch (e) {
        print("ensureToken failed: $e");
      }
    }
    return false;
  }

  Future<void> _sendCode() async {
    final email = emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => error = '请输入邮箱');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await _postJson('$baseUrl/request_code', {'email': email});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('验证码已发送，请检查邮箱')),
      );
    } catch (e) {
      setState(() => error = '发送验证码失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _doRegister() async {
    final email = emailCtrl.text.trim();
    final username = userCtrl.text.trim();
    final password = passCtrl.text.trim();
    final code = verifyCodeCtrl.text.trim();

    if (email.isEmpty || username.isEmpty || password.isEmpty || code.isEmpty) {
      setState(() => error = '请填写完整注册信息');
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      // 1. Register
      await _postJson('$baseUrl/register', {
        'email': email,
        'username': username,
        'password': password,
        'verification_code': code,
      });

      // 2. Create Gitea User & Get Token
      await _createGiteaUserAndSetToken(username, password);
    } catch (e) {
      setState(() => error = '注册失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _doLogin() async {
    final u = userCtrl.text.trim();
    final p = passCtrl.text.trim();
    if (u.isEmpty || p.isEmpty) {
      setState(() => error = '请输入用户名/邮箱和密码');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final resp = await _postJson('$baseUrl/login', {
        'username': u,
        'password': p,
      });

      // The login response contains tokens.
      // { "success": true, "userid": "...", "username": "...", "tokens": [], ... }

      final tokens = resp['tokens'] as List?;
      print("doLogin");
      print(tokens);
      String? token;

      if (tokens != null && tokens.isNotEmpty) {
        // Use the first token? Or find one?
        // Just pick the first one for now.
        // Tokens structure: [{ "remark": "...", "sha1": "..." }]
        final firstToken = tokens[0];
        if (firstToken is Map) {
          token = firstToken['sha1'];
        }
      }

      if (token != null) {
        // Save directly
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('git_username', resp['username'] ?? u);
        await prefs.setString(
            'git_password', p); // Save password for auto-refresh
        // await prefs.setString('git_token', token); // Don't save token
        // if (tokens != null) {
        //   await prefs.setString('git_tokens_list', jsonEncode(tokens));
        // }

        setState(() {
          _username = resp['username'] ?? u;
          _token = token;
          loading = false;
        });
      } else {
        // No token found, try to create/generate one
        await _createGiteaUserAndSetToken(u, p);
        // loading = false is handled in _createGiteaUserAndSetToken
      }
    } catch (e) {
      setState(() {
        error = '登录失败: $e';
        loading = false;
      });
    }
  }

  Future<void> _createGiteaUserAndSetToken(
      String username, String password) async {
    try {
      final resp = await _postJson('$baseUrl/create_user', {
        'username': username,
        'password': password,
      });

      // { "tokens": [ { "remark": "...", "sha1": "..." } ], "source": "..." }
      final tokens = resp['tokens'] as List;
      print("_createGiteaUserAndSetToken");
      print(tokens);
      if (tokens.isEmpty) throw Exception('无法获取Token');

      final t = tokens[0];
      final token = t['sha1'];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('git_username', username);
      await prefs.setString(
          'git_password', password); // Save password for auto-refresh
      // await prefs.setString('git_token', token); // Don't save token
      // await prefs.setString('git_tokens_list', jsonEncode(tokens)); // Don't save

      setState(() {
        _username = username;
        _token = token;
        loading = false;
      });
    } catch (e) {
      // Don't handle loading = false here, let caller handle or throw
      throw Exception('创建用户/获取Token失败: $e');
    }
  }

  Future<void> _doLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('git_username');
    await prefs.remove('git_password');
    await prefs.remove('git_token'); // Clean up legacy
    await prefs.remove('git_tokens_list'); // Clean up legacy
    setState(() {
      _username = null;
      _token = null;
      userCtrl.clear();
      passCtrl.clear();
    });
  }

  Future<void> _showShareDialog() async {
    if (!await _ensureToken() || currentProjectName == null) {
      setState(() => error = '请先登录并打开一个项目');
      return;
    }

    final userCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('分享仓库'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('输入要分享的用户名（对方将获得写权限）'),
              const SizedBox(height: 8),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('分享'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final targetUser = userCtrl.text.trim();
      if (targetUser.isEmpty) return;

      setState(() {
        loading = true;
        error = null;
      });

      try {
        await _postJson('$baseUrl/share', {
          'owner': _username,
          'repo': currentProjectName,
          'username': targetUser,
          'token': _token,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已成功分享给 $targetUser')),
        );
      } catch (e) {
        setState(() => error = '分享失败: $e');
      } finally {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _onPush({bool force = false}) async {
    if (!await _ensureToken()) {
      setState(() => error = '请先登录');
      return;
    }
    final repoPath = pathCtrl.text.trim();
    if (repoPath.isEmpty) {
      setState(() => error = '请输入本地仓库路径');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await _postJson('http://localhost:8080/push', {
        'repoPath': repoPath,
        'username': _username,
        'token': _token,
        'force': force,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('推送成功')));
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('non-fast-forward') || msg.contains('fetch first')) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('推送被拒绝'),
            content: const Text('远程分支比本地分支新，或本地分支历史与远程不一致（可能因为回滚）。\n'
                '是否强制推送？（这将覆盖远程分支的更改，可能导致他人工作丢失）'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('强制推送'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _onPush(force: true);
          return;
        }
      }
      setState(() => error = '推送失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _onPull() async {
    if (!await _ensureToken()) {
      setState(() => error = '请先登录');
      return;
    }

    setState(() => loading = true);
    List<String> projects = [];
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/remote/list'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': _token}),
      );
      if (resp.statusCode != 200) {
        throw Exception(resp.body);
      }
      final body = jsonDecode(resp.body);
      if (body is List) {
        projects = body.cast<String>();
      }
    } catch (e) {
      setState(() {
        loading = false;
        error = '获取远程列表失败: $e';
      });
      return;
    }
    setState(() => loading = false);

    String? selected = projects.isNotEmpty ? projects.first : null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('拉取远程仓库'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('选择要拉取的远程仓库'),
                const SizedBox(height: 8),
                projects.isEmpty
                    ? const Text('未找到任何远程仓库')
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: selected,
                        items: projects
                            .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(p),
                                ))
                            .toList(),
                        onChanged: (v) {
                          setState(() => selected = v);
                        },
                      ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed:
                  selected == null ? null : () => Navigator.pop(context, true),
              child: const Text('拉取'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || selected == null) return;
    final repoName = selected!;

    setState(() {
      loading = true;
      error = null;
    });
    try {
      final resp = await _postJson('http://localhost:8080/pull', {
        'repoName': repoName,
        'username': _username,
        'token': _token,
      });

      final status = resp['status'] as String?;
      final path = resp['path'] as String?;

      // Auto open repo if path is available
      if (path != null && path.isNotEmpty) {
        setState(() {
          pathCtrl.text = path;
        });
        await _load();
      }

      if (status == 'error') {
        final errorType = resp['errorType'];
        final message = resp['message'] ?? 'Unknown error';

        if (errorType == 'ahead' || errorType == 'uncommitted') {
          final bool isAhead = errorType == 'ahead';
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('无法拉取'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                if (isAhead)
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _onPush();
                    },
                    child: const Text('立即推送'),
                  ),
              ],
            ),
          );
        } else {
          setState(() => error = '拉取失败: $message');
        }
        return;
      }

      final isFresh = resp['isFresh'] == true;

      setState(() {
        // If fresh clone, user needs to set up tracking document
        if (isFresh) {
          currentProjectName = repoName;
        }
      });

      if (isFresh) {
        // Ask for docx path
        final docxCtrl = TextEditingController();
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('设置追踪文档'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('这是一个新的克隆，请选择要追踪的Word文档(.docx)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: docxCtrl,
                    decoration: const InputDecoration(
                      labelText: 'docx文件路径 c:\\path\\to\\file.docx',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (ok == true) {
          final docx = docxCtrl.text.trim();
          if (docx.isNotEmpty) {
            try {
              await _postJson('http://localhost:8080/track/update', {
                'name': repoName,
                'newDocxPath': docx,
              });
              setState(() {
                docxPathCtrl.text = docx;
              });
            } catch (e) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('设置文档失败: $e')));
            }
          }
        }
      }

      // Reload again to update graph if needed (e.g. fresh clone or new commits)
      await _load();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('拉取成功')));
    } catch (e) {
      setState(() => error = '拉取失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String url,
    Map<String, dynamic> body,
  ) async {
    final resp = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode == 204) {
      // No Content, return empty map
      return {};
    }
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      // Allow 201 Created as well
      throw Exception(resp.body);
    }
    if (resp.body.isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> _load() async {
    final path = pathCtrl.text.trim();
    final limit = int.tryParse(limitCtrl.text.trim());
    if (path.isEmpty) {
      setState(() => error = '请输入本地仓库路径');
      return;
    }
    setState(() {
      loading = true;
      error = null;
      data = null;
    });

    // Try fetch tracking info
    try {
      final info = await _postJson('http://localhost:8080/track/info', {
        'repoPath': path,
      });
      if (info.isNotEmpty) {
        setState(() {
          currentProjectName = info['name'];
          docxPathCtrl.text = info['docxPath'] ?? '';
        });
      } else {
        setState(() {
          currentProjectName = null;
          docxPathCtrl.clear();
        });
      }
    } catch (_) {
      // Ignore if not tracked or error
    }

    try {
      await http.post(
        Uri.parse('http://localhost:8080/reset'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
      );
      final resp = await http.post(
        Uri.parse('http://localhost:8080/graph'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoPath': path, 'limit': limit}),
      );
      if (resp.statusCode != 200) {
        setState(() {
          error = '后端错误: ${resp.body}';
          loading = false;
        });
        return;
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final gd = GraphData.fromJson(j);
      setState(() {
        data = gd;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  Future<void> _onCreateTrackProject() async {
    final nameCtrl = TextEditingController();
    final docxCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建追踪项目'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '项目名称'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: docxCtrl,
                decoration: const InputDecoration(
                  labelText: 'docx文件路径 c:\\path\\to\\file.docx',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final docx = docxCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => error = '请输入项目名称');
      return;
    }
    try {
      final resp = await _postJson('http://localhost:8080/track/create', {
        'name': name,
        'docxPath': docx.isEmpty ? null : docx,
      });
      final repoPath = resp['repoPath'] as String;
      setState(() {
        currentProjectName = name;
        pathCtrl.text = repoPath;
        docxPathCtrl.text = docx;
      });
      final up = await _postJson('http://localhost:8080/track/update', {
        'name': name,
      });
      setState(() {
        working = WorkingState(
          changed: up['workingChanged'] == true,
          baseId: up['head'] as String?,
        );
      });
      await _load();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<List<String>> _fetchProjectList() async {
    try {
      final resp =
          await http.get(Uri.parse('http://localhost:8080/track/list'));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        return (body['projects'] as List).cast<String>();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _onOpenTrackProject() async {
    setState(() => loading = true);
    final projects = await _fetchProjectList();
    setState(() => loading = false);

    String? selected = projects.isNotEmpty ? projects.first : null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('打开追踪项目'),
          content: SizedBox(
            width: 360,
            child: projects.isEmpty
                ? const Text('没有找到任何项目 (appdata/gitdocx)')
                : DropdownButton<String>(
                    isExpanded: true,
                    value: selected,
                    items: projects
                        .map((p) => DropdownMenuItem(
                              value: p,
                              child: Text(p),
                            ))
                        .toList(),
                    onChanged: (v) {
                      setState(() => selected = v);
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed:
                  selected == null ? null : () => Navigator.pop(context, true),
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || selected == null) return;
    final name = selected!;
    try {
      final resp = await _postJson('http://localhost:8080/track/open', {
        'name': name,
      });
      final repoPath = resp['repoPath'] as String;
      final docxPath = resp['docxPath'] as String?;
      setState(() {
        currentProjectName = name;
        pathCtrl.text = repoPath;
        docxPathCtrl.text = docxPath ?? '';
      });
      final up = await _postJson('http://localhost:8080/track/update', {
        'name': name,
      });
      setState(() {
        working = WorkingState(
          changed: up['workingChanged'] == true,
          baseId: up['head'] as String?,
        );
      });
      await _load();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> _onUpdateRepo() async {
    String? name = currentProjectName;
    if (name == null || name.isEmpty) {
      setState(() => loading = true);
      final projects = await _fetchProjectList();
      setState(() => loading = false);

      String? selected = projects.isNotEmpty ? projects.first : null;

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('更新git仓库'),
            content: SizedBox(
              width: 360,
              child: projects.isEmpty
                  ? const Text('没有找到任何项目')
                  : DropdownButton<String>(
                      isExpanded: true,
                      value: selected,
                      items: projects
                          .map((p) => DropdownMenuItem(
                                value: p,
                                child: Text(p),
                              ))
                          .toList(),
                      onChanged: (v) {
                        setState(() => selected = v);
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      );
      if (ok == true && selected != null) {
        name = selected;
        setState(() => currentProjectName = name);
      }
    }
    if (name == null || name.isEmpty) return;
    try {
      final resp = await _postJson('http://localhost:8080/track/update', {
        'name': name,
      });
      final needDocx = resp['needDocx'] == true;
      if (needDocx) {
        String? docx = docxPathCtrl.text.trim();
        bool askUser = docx.isEmpty;

        if (askUser) {
          final docxCtrl = TextEditingController();
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('选择docx文件路径'),
              content: SizedBox(
                width: 420,
                child: TextField(
                  controller: docxCtrl,
                  decoration: const InputDecoration(
                    labelText: 'docx文件路径 c:\\path\\to\\file.docx',
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
          if (ok == true) {
            docx = docxCtrl.text.trim();
          } else {
            docx = null;
          }
        }

        if (docx != null && docx.isNotEmpty) {
          final up = await _postJson('http://localhost:8080/track/update', {
            'name': name,
            'newDocxPath': docx,
          });
          setState(() {
            docxPathCtrl.text = docx!;
            working = WorkingState(
              changed: up['workingChanged'] == true,
              baseId: up['head'] as String?,
            );
          });
        }
      } else {
        setState(() {
          working = WorkingState(
            changed: resp['workingChanged'] == true,
            baseId: resp['head'] as String?,
          );
        });
      }
      await _load();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> _onChangeDocxPath() async {
    if (currentProjectName == null) return;
    final name = currentProjectName!;
    final docxCtrl = TextEditingController(text: docxPathCtrl.text);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('修改Docx路径: $name'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: docxCtrl,
            decoration: const InputDecoration(
              labelText: 'c:\\path\\to\\file.docx',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final newPath = docxCtrl.text.trim();
      if (newPath.isEmpty) return;

      try {
        final up = await _postJson('http://localhost:8080/track/update', {
          'name': name,
          'newDocxPath': newPath,
        });
        setState(() {
          docxPathCtrl.text = newPath;
          working = WorkingState(
            changed: up['workingChanged'] == true,
            baseId: up['head'] as String?,
          );
        });
        await _load();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('路径已更新')));
      } catch (e) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Git Graph 可视化')),
      body: Column(
        children: [
          if (_username == null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: _isRegisterMode
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: emailCtrl,
                                  decoration:
                                      const InputDecoration(labelText: '邮箱'))),
                          const SizedBox(width: 8),
                          ElevatedButton(
                              onPressed: loading ? null : _sendCode,
                              child: const Text('发送验证码')),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TextField(
                                  controller: verifyCodeCtrl,
                                  decoration:
                                      const InputDecoration(labelText: '验证码'))),
                        ]),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: userCtrl,
                                  decoration:
                                      const InputDecoration(labelText: '用户名'))),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TextField(
                                  controller: passCtrl,
                                  obscureText: true,
                                  decoration:
                                      const InputDecoration(labelText: '密码'))),
                          const SizedBox(width: 8),
                          ElevatedButton(
                              onPressed: loading ? null : _doRegister,
                              child: const Text('注册')),
                          const SizedBox(width: 8),
                          TextButton(
                              onPressed: () =>
                                  setState(() => _isRegisterMode = false),
                              child: const Text('返回登录')),
                        ]),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                            child: TextField(
                                controller: userCtrl,
                                decoration: const InputDecoration(
                                    labelText: '用户名/邮箱'))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: TextField(
                                controller: passCtrl,
                                obscureText: true,
                                decoration:
                                    const InputDecoration(labelText: '密码'))),
                        const SizedBox(width: 8),
                        ElevatedButton(
                            onPressed: loading ? null : _doLogin,
                            child: const Text('登录')),
                        const SizedBox(width: 8),
                        TextButton(
                            onPressed: () =>
                                setState(() => _isRegisterMode = true),
                            child: const Text('去注册')),
                      ],
                    ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Text('当前用户: $_username'),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: _showShareDialog, child: const Text('分享仓库')),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: loading ? null : _doLogout,
                    child: const Text('登出'))
              ]),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: loading ? null : _onCreateTrackProject,
                  child: const Text('新建追踪项目'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _onOpenTrackProject,
                  child: const Text('打开追踪项目'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _onUpdateRepo,
                  child: const Text('更新git仓库'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _onPush,
                  child: const Text('推送'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _onPull,
                  child: const Text('拉取'),
                ),
                const SizedBox(width: 8),
                if (currentProjectName != null)
                  Text(
                    ' 当前项目: $currentProjectName ',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
          if (currentProjectName != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  const Text('追踪文档: '),
                  Expanded(
                    child: TextField(
                      controller: docxPathCtrl,
                      readOnly: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _onChangeDocxPath,
                    icon: const Icon(Icons.edit),
                    tooltip: '修改Docx路径',
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: limitCtrl,
                    decoration: const InputDecoration(labelText: '最近提交数'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: loading ? null : _load,
                  child: const Text('加载'),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: data == null
                ? const Center(child: Text('输入路径并点击加载'))
                : _GraphView(
                    data: data!,
                    working: (data!.commits.isEmpty && working != null)
                        ? WorkingState(changed: true, baseId: working!.baseId)
                        : working,
                    repoPath: pathCtrl.text.trim(),
                    projectName: currentProjectName,
                    onRefresh: _load,
                    onUpdate: _onUpdateRepo,
                  ),
          ),
        ],
      ),
    );
  }
}

class _GraphView extends StatefulWidget {
  final GraphData data;
  final WorkingState? working;
  final String repoPath;
  final String? projectName;
  final VoidCallback? onRefresh;
  final Future<void> Function()? onUpdate;
  const _GraphView({
    required this.data,
    this.working,
    required this.repoPath,
    this.projectName,
    this.onRefresh,
    this.onUpdate,
  });
  @override
  State<_GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<_GraphView> {
  final TransformationController _tc = TransformationController();
  CommitNode? _hovered;
  Offset? _hoverPos;
  bool _rightPanActive = false;
  Offset? _rightPanLast;
  DateTime? _rightPanStart;
  Map<String, Color>? _branchColors;
  Map<String, List<String>>? _pairBranches;
  Size? _canvasSize;
  double _laneWidth = 120;
  double _rowHeight = 160;
  static const Duration _rightPanDelay = Duration(milliseconds: 200);
  final Set<String> _selectedNodes = {};
  bool _comparing = false;

  void _resetView() {
    setState(() {
      _tc.value = Matrix4.identity();
      _hovered = null;
      _hoverPos = null;
      _hoverEdge = null;
      _selectedNodes.clear();
    });
  }

  @override
  void didUpdateWidget(covariant _GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _branchColors = null;
      _pairBranches = null;
      _canvasSize = null;
      _hovered = null;
      _hoverPos = null;
      _hoverEdge = null;
      _tc.value = Matrix4.identity();
      _rightPanActive = false;
      _rightPanLast = null;
      _rightPanStart = null;
      _selectedNodes.clear();
      _comparing = false;
    }
  }

  Future<void> _onCompare() async {
    if (_selectedNodes.length != 2) return;
    if (_comparing) return;
    setState(() => _comparing = true);
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );

      final nodes = _selectedNodes.toList();
      final commits = widget.data.commits;
      int idx1 = commits.indexWhere((c) => c.id == nodes[0]);
      int idx2 = commits.indexWhere((c) => c.id == nodes[1]);

      String oldC = nodes[0];
      String newC = nodes[1];

      if (idx1 != -1 && idx2 != -1) {
        if (idx1 < idx2) {
          newC = nodes[0];
          oldC = nodes[1];
        } else {
          newC = nodes[1];
          oldC = nodes[0];
        }
      }

      final resp = await http.post(
        Uri.parse('http://localhost:8080/compare'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoPath': widget.repoPath,
          'commit1': oldC,
          'commit2': newC,
        }),
      );

      // Pop loading dialog
      if (mounted) Navigator.pop(context);

      if (resp.statusCode != 200) {
        throw Exception(resp.body);
      }
      final pdfBytes = resp.bodyBytes;
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VisualizeDocxPage(
            initialBytes: pdfBytes,
            title: '${newC.substring(0, 7)} vs ${oldC.substring(0, 7)}',
            onBack: () => Navigator.pop(context),
          ),
        ),
      );
    } catch (e) {
      // Ensure loading dialog is closed if error occurs
      if (mounted && _comparing) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('对比失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  Future<void> _onCommit() async {
    final authorCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('提交更改'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: authorCtrl,
                decoration: const InputDecoration(labelText: '作者姓名'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: msgCtrl,
                decoration: const InputDecoration(
                  labelText: '备注信息 (Commit Message)',
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                final resp = await http.post(
                  Uri.parse('http://localhost:8080/compare_working'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'repoPath': widget.repoPath}),
                );
                if (resp.statusCode != 200) throw Exception(resp.body);
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => VisualizeDocxPage(
                      initialBytes: resp.bodyBytes,
                      title: 'Working Copy Diff',
                      onBack: () => Navigator.pop(context),
                    ),
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('预览失败: $e')));
              }
            },
            child: const Text('预览差异'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final author = authorCtrl.text.trim();
    final msg = msgCtrl.text.trim();
    if (author.isEmpty || msg.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写完整信息')));
      return;
    }
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/commit'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoPath': widget.repoPath,
          'author': author,
          'message': msg,
        }),
      );
      if (resp.statusCode != 200) throw Exception(resp.body);
      if (widget.onUpdate != null) {
        await widget.onUpdate!();
      } else {
        widget.onRefresh?.call();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提交成功')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('提交失败: $e')));
    }
  }

  Future<void> _onCreateBranch() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建分支'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('输入新分支名称，创建后将自动切换到该分支。'),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '分支名称'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/branch/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoPath': widget.repoPath, 'branchName': name}),
      );
      if (resp.statusCode != 200) throw Exception(resp.body);
      if (widget.onUpdate != null) {
        await widget.onUpdate!();
      } else {
        widget.onRefresh?.call();
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败: $e')));
    }
  }

  Future<void> _doSwitchBranch(String name) async {
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/branch/switch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'projectName': widget.projectName ?? '',
          'branchName': name,
        }),
      );
      if (resp.statusCode != 200) throw Exception(resp.body);

      // Force update repo status after switch (to check diff against new branch)
      if (widget.onUpdate != null) {
        await widget.onUpdate!();
      } else {
        widget.onRefresh?.call();
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已切换到分支: $name')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切换失败: $e')));
      }
    }
  }

  Future<void> _onSwitchBranch() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('切换分支'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '目标分支名称'),
              ),
              const SizedBox(height: 8),
              const Text(
                '提示：双击图表中的分支节点或右侧列表可快速切换。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    await _doSwitchBranch(name);
  }

  void _showNodeActionDialog(CommitNode node) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('操作: ${node.id.substring(0, 7)}'),
        content: Text('提交信息: ${node.subject}'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _previewVersion(node);
            },
            child: const Text('预览这个版本'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _rollbackVersion(node);
            },
            child: const Text('回退到这个版本 (仅文件)'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _resetBranch(node);
            },
            child: const Text('回退分支到此 (危险)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我点错了'),
          ),
        ],
      ),
    );
  }

  Future<void> _previewVersion(CommitNode node) async {
    if (_comparing) return;
    setState(() => _comparing = true);
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );

      final resp = await http.post(
        Uri.parse('http://localhost:8080/preview'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoPath': widget.repoPath,
          'commitId': node.id,
        }),
      );

      // Pop loading dialog
      if (mounted) Navigator.pop(context);

      if (resp.statusCode != 200) {
        throw Exception('预览失败: ${resp.body}');
      }
      final bytes = resp.bodyBytes;
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VisualizeDocxPage(
            initialBytes: bytes,
            title: '预览: ${node.id.substring(0, 7)}',
          ),
        ),
      );
    } catch (e) {
      // Ensure loading dialog is closed if error occurs
      if (mounted && _comparing) Navigator.pop(context);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  Future<void> _rollbackVersion(CommitNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认回退'),
        content: Text('确定要将工作区文档回退到版本 ${node.id.substring(0, 7)} 吗？\n'
            '当前未提交的更改可能会丢失。\n'
            '请确保 Word 文档已关闭。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在回退...')));

    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/rollback'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'projectName': widget.projectName ?? '',
          'commitId': node.id,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception('回退失败: ${resp.body}');
      }

      if (widget.onRefresh != null) {
        widget.onRefresh!();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回退成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _resetBranch(CommitNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('危险：重置分支'),
        content: Text('确定要将当前分支重置到版本 ${node.id.substring(0, 7)} 吗？\n'
            '此操作将【永久删除】该版本之后的所有提交记录！\n'
            '当前工作区的文档也将被回退到该版本。\n'
            '请务必确保 Word 文档已关闭。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在重置分支...')));

    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/reset_branch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'projectName': widget.projectName ?? '',
          'commitId': node.id,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception('重置失败: ${resp.body}');
      }

      if (widget.onRefresh != null) {
        widget.onRefresh!();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分支重置成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    _branchColors ??= _assignBranchColors(widget.data.branches);
    _pairBranches ??= _buildPairBranches(widget.data);
    _canvasSize ??= _computeCanvasSize(widget.data);
    return Stack(
      children: [
        MouseRegion(
          onHover: (d) {
            final scene = _toScene(d.localPosition);
            final hit = _hitTest(scene, widget.data);
            EdgeInfo? ehit;
            if (hit == null) {
              ehit = _hitEdge(scene, widget.data);
            }
            setState(() {
              _hovered = hit;
              _hoverPos = d.localPosition;
              _hoverEdge = ehit;
            });
          },
          onExit: (_) {
            setState(() {
              _hovered = null;
              _hoverPos = null;
              _hoverEdge = null;
            });
          },
          child: Listener(
            onPointerDown: (e) {
              if (e.buttons & kSecondaryMouseButton != 0) {
                _rightPanStart = DateTime.now();
                _rightPanLast = e.localPosition;
                _rightPanActive = false;
              }
            },
            onPointerMove: (e) {
              if (e.buttons & kSecondaryMouseButton != 0 &&
                  _rightPanLast != null) {
                final now = DateTime.now();
                if (!_rightPanActive &&
                    _rightPanStart != null &&
                    now.difference(_rightPanStart!) >= _rightPanDelay) {
                  _rightPanActive = true;
                }
                if (_rightPanActive) {
                  final delta = e.localPosition - _rightPanLast!;
                  final m = _tc.value.clone();
                  m.translate(delta.dx, delta.dy);
                  _tc.value = m;
                  _rightPanLast = e.localPosition;
                }
              }
            },
            onPointerUp: (e) {
              _rightPanActive = false;
              _rightPanLast = null;
              _rightPanStart = null;
            },
            child: GestureDetector(
              onTapUp: (d) {
                final scene = _toScene(d.localPosition);
                final hit = _hitTest(scene, widget.data);
                if (hit != null) {
                  setState(() {
                    if (_selectedNodes.contains(hit.id)) {
                      _selectedNodes.remove(hit.id);
                    } else {
                      if (_selectedNodes.length >= 2) {
                        _selectedNodes.clear();
                        _selectedNodes.add(hit.id);
                      } else {
                        _selectedNodes.add(hit.id);
                      }
                    }
                  });
                }
              },
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 0.2,
                maxScale: 4,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(2000),
                child: GestureDetector(
                  onDoubleTap: () {},
                  onDoubleTapDown: (d) {
                    final hit = _hitTest(d.localPosition, widget.data);
                    if (hit != null) {
                      final branches =
                          widget.data.branches.map((b) => b.name).toSet();
                      final targets =
                          hit.refs.where((r) => branches.contains(r)).toList();
                      if (targets.isNotEmpty) {
                        final current = widget.data.currentBranch;
                        final others =
                            targets.where((t) => t != current).toList();
                        if (others.length == 1) {
                          _doSwitchBranch(others.first);
                        } else if (others.length > 1) {
                          showDialog(
                            context: context,
                            builder: (_) => SimpleDialog(
                              title: const Text('选择分支'),
                              children: others
                                  .map((b) => SimpleDialogOption(
                                        onPressed: () {
                                          Navigator.pop(context);
                                          _doSwitchBranch(b);
                                        },
                                        child: Text(b),
                                      ))
                                  .toList(),
                            ),
                          );
                        } else {
                          if (targets.contains(current)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已经是当前分支')),
                            );
                          }
                        }
                      } else {
                        _showNodeActionDialog(hit);
                      }
                    } else {
                      final edgeHit = _hitEdge(d.localPosition, widget.data);
                      if (edgeHit != null && edgeHit.branches.isNotEmpty) {
                        final current = widget.data.currentBranch;
                        final others = edgeHit.branches
                            .where((b) => b != current)
                            .toList();
                        if (others.isEmpty) {
                          if (edgeHit.branches.contains(current)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已经是当前分支')),
                            );
                          }
                          return;
                        }
                        if (others.length == 1) {
                          _doSwitchBranch(others.first);
                        } else {
                          showDialog(
                            context: context,
                            builder: (_) => SimpleDialog(
                              title: const Text('选择分支'),
                              children: others
                                  .map((b) => SimpleDialogOption(
                                        onPressed: () {
                                          Navigator.pop(context);
                                          _doSwitchBranch(b);
                                        },
                                        child: Text(b),
                                      ))
                                  .toList(),
                            ),
                          );
                        }
                      }
                    }
                  },
                  child: SizedBox(
                    width: _canvasSize!.width,
                    height: _canvasSize!.height,
                    child: CustomPaint(
                      painter: GraphPainter(
                        widget.data,
                        _branchColors!,
                        _hoverEdgeKey(),
                        _laneWidth,
                        _rowHeight,
                        working: widget.working,
                        selectedNodes: _selectedNodes,
                      ),
                      size: _canvasSize!,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 16,
          left: 16,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '当前分支: ${widget.data.currentBranch ?? "Unknown"}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.working?.changed == true)
                        ElevatedButton.icon(
                          onPressed: _onCommit,
                          icon: const Icon(Icons.upload),
                          label: const Text('提交更改'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      if (widget.working?.changed == true)
                        const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _onCreateBranch,
                        icon: const Icon(Icons.add),
                        label: const Text('新建分支'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _onSwitchBranch,
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('切换分支'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          top: 80,
          child: Material(
            elevation: 2,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFDFDFD),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(color: Color(0x22000000), blurRadius: 4),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _resetView,
                        icon: const Icon(Icons.home),
                        label: const Text('返回主视角'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '间距调整',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('节点间距'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 180,
                        child: Slider(
                          min: 40,
                          max: 160,
                          divisions: 24,
                          value: _rowHeight,
                          label: _rowHeight.round().toString(),
                          onChanged: (v) {
                            setState(() {
                              _rowHeight = v;
                              _canvasSize = _computeCanvasSize(widget.data);
                            });
                          },
                        ),
                      ),
                      Text(_rowHeight.round().toString()),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('分支间距'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 180,
                        child: Slider(
                          min: 60,
                          max: 200,
                          divisions: 28,
                          value: _laneWidth,
                          label: _laneWidth.round().toString(),
                          onChanged: (v) {
                            setState(() {
                              _laneWidth = v;
                              _canvasSize = _computeCanvasSize(widget.data);
                            });
                          },
                        ),
                      ),
                      Text(_laneWidth.round().toString()),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '分支图例',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  for (final b in widget.data.branches)
                    InkWell(
                      onDoubleTap: () => _doSwitchBranch(b.name),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _branchColors![b.name]!,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              b.name,
                              style: TextStyle(
                                fontWeight: b.name == widget.data.currentBranch
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: b.name == widget.data.currentBranch
                                    ? Colors.blue[900]
                                    : Colors.black,
                              ),
                            ),
                            if (b.name == widget.data.currentBranch)
                              const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.check_circle,
                                  size: 14,
                                  color: Colors.green,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_hasUnknownEdges())
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xFF9E9E9E),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          SizedBox(width: 6),
                          Text('其它'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_hovered != null && _hoverPos != null)
          Positioned(
            left: _hoverPos!.dx + 12,
            top: _hoverPos!.dy + 12,
            child: Material(
              elevation: 2,
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 6),
                  ],
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.black, fontSize: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('提交信息: ${_hovered!.subject}'),
                      const SizedBox(height: 4),
                      Text('作者: ${_hovered!.author}'),
                      Text('时间: ${_hovered!.date}'),
                      const SizedBox(height: 4),
                      Text('父节点的提交的 ID: ${_hovered!.parents.join(', ')}'),
                      Text('提交的 ID: ${_hovered!.id}'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_hoverEdge != null && _hoverPos != null && _hovered == null)
          Positioned(
            left: _hoverPos!.dx + 12,
            top: _hoverPos!.dy + 12,
            child: Material(
              elevation: 2,
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 6),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_hoverEdge!.child.substring(0, 7)} → ${_hoverEdge!.parent.substring(0, 7)}',
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _hoverEdge!.branches
                          .map(
                            (b) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: (_branchColors?[b] ??
                                        const Color(0xFF9E9E9E))
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _branchColors?[b] ??
                                      const Color(0xFF9E9E9E),
                                ),
                              ),
                              child: Text(
                                b,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_selectedNodes.length == 2)
          Positioned(
            bottom: 32,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton.icon(
                onPressed: _comparing ? null : _onCompare,
                icon: _comparing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.compare_arrows),
                label: Text(_comparing ? '对比中...' : '一键比较差异'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }

  EdgeInfo? _hoverEdge;

  Offset _toScene(Offset p) {
    final inv = _tc.value.clone()..invert();
    return MatrixUtils.transformPoint(inv, p);
  }

  Size _computeCanvasSize(GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    var maxLane = -1;
    for (final v in laneOf.values) {
      if (v > maxLane) maxLane = v;
    }
    if (maxLane < 0) maxLane = 0;
    var w = (maxLane + 1) * laneWidth + 400;
    if (widget.working?.changed == true) {
      w += 340;
    }
    final h = commits.length * rowHeight + 400;
    return Size(w.toDouble(), h.toDouble());
  }

  Map<String, Color> _assignBranchColors(List<Branch> branches) {
    final palette = GraphPainter.lanePalette;
    final map = <String, Color>{};
    for (var i = 0; i < branches.length; i++) {
      map[branches[i].name] = palette[i % palette.length];
    }
    return map;
  }

  Map<String, List<String>> _buildPairBranches(GraphData data) {
    final map = <String, List<String>>{};
    for (final entry in data.chains.entries) {
      final b = entry.key;
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        final key = '$child|$parent';
        final list = map[key] ??= <String>[];
        if (!list.contains(b)) list.add(b);
      }
    }
    return map;
  }

  String? _hoverEdgeKey() {
    final e = _hoverEdge;
    if (e == null) return null;
    return '${e.child}|${e.parent}';
  }

  bool _hasUnknownEdges() {
    final names = widget.data.branches.map((b) => b.name).toSet();
    final byId = {for (final c in widget.data.commits) c.id: c};
    bool unknown = false;
    for (final c in widget.data.commits) {
      String? bn;
      // direct ref
      for (final r in c.refs) {
        if (names.contains(r)) {
          bn = r;
          break;
        }
        if (r.startsWith('origin/')) {
          final short = r.substring('origin/'.length);
          if (names.contains(short)) {
            bn = short;
            break;
          }
        }
      }
      // walk first-parents up to 100 steps
      var cur = c;
      var steps = 0;
      while (bn == null && cur.parents.isNotEmpty && steps < 100) {
        final p = byId[cur.parents.first];
        if (p == null) break;
        for (final r in p.refs) {
          if (names.contains(r)) {
            bn = r;
            break;
          }
          if (r.startsWith('origin/')) {
            final short = r.substring('origin/'.length);
            if (names.contains(short)) {
              bn = short;
              break;
            }
          }
        }
        cur = p;
        steps++;
      }
      if (bn == null) {
        unknown = true;
        break;
      }
    }
    return unknown;
  }

  CommitNode? _hitTest(Offset sceneP, GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    final rowOf = <String, int>{};
    for (var i = 0; i < commits.length; i++) {
      rowOf[commits[i].id] = i;
    }
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;
      final dx = sceneP.dx - x;
      final dy = sceneP.dy - y;
      if ((dx * dx + dy * dy) <=
          (GraphPainter.nodeRadius * GraphPainter.nodeRadius * 4)) {
        return c;
      }
    }
    return null;
  }

  Map<String, int> _branchLane(List<Branch> branches) {
    final ordered = List<Branch>.from(branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    final map = <String, int>{};
    for (var i = 0; i < ordered.length; i++) {
      map[ordered[i].name] = i;
    }
    return map;
  }

  Map<String, int> _laneOfByBranches(GraphData data) {
    final laneOf = <String, int>{};
    final branchLane = _branchLane(data.branches);
    final orderedNames = branchLane.keys.toList()
      ..sort((a, b) {
        int pa = a == 'master' ? 0 : 1;
        int pb = b == 'master' ? 0 : 1;
        if (pa != pb) return pa - pb;
        return a.compareTo(b);
      });
    for (final name in orderedNames) {
      final lane = branchLane[name]!;
      final ids = data.chains[name] ?? const <String>[];
      for (final id in ids) {
        laneOf[id] ??= lane;
      }
    }
    for (final c in data.commits) {
      if (laneOf[c.id] != null) continue;
      int? lane;
      for (final p in c.parents) {
        final lp = laneOf[p];
        if (lp != null) {
          lane = lp;
          break;
        }
      }
      final laneVal = lane ?? branchLane.length;
      laneOf[c.id] = laneVal;
    }
    return laneOf;
  }

  EdgeInfo? _hitEdge(Offset sceneP, GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    final rowOf = <String, int>{};
    for (var i = 0; i < commits.length; i++) {
      rowOf[commits[i].id] = i;
    }
    if (_pairBranches == null) return null;
    double best = double.infinity;
    EdgeInfo? bestInfo;
    for (final entry in _pairBranches!.entries) {
      final key = entry.key;
      final sp = key.split('|');
      if (sp.length != 2) continue;
      final child = sp[0];
      final parent = sp[1];
      if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;
      final rowC = rowOf[child]!;
      final laneC = laneOf[child]!;
      final x = laneC * laneWidth + laneWidth / 2;
      final y = rowC * rowHeight + rowHeight / 2;
      final rowP = rowOf[parent]!;
      final laneP = laneOf[parent]!;
      final px = laneP * laneWidth + laneWidth / 2;
      final py = rowP * rowHeight + rowHeight / 2;
      final dLane = (laneC - laneP).abs();
      var bendBase = (dLane * 8.0).clamp(8.0, 24.0);
      bendBase += _obstacleCount(child, parent, laneOf, rowOf) * 16.0;
      final dir = laneC <= laneP ? 1.0 : -1.0;
      final c1 = Offset(x + dir * bendBase, (y + py) / 2);
      final c2 = Offset(px - dir * bendBase, (y + py) / 2);
      final d = _distToCubic(sceneP, Offset(x, y), c1, c2, Offset(px, py));
      if (d < best) {
        best = d;
        bestInfo = EdgeInfo(
          child: child,
          parent: parent,
          branches: entry.value,
        );
      }
    }
    if (bestInfo != null && best <= 8.0) return bestInfo;
    return null;
  }

  double _distToCubic(Offset p, Offset a, Offset c1, Offset c2, Offset b) {
    const steps = 24;
    Offset prev = a;
    double minD = double.infinity;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final pt = _cubicPoint(a, c1, c2, b, t);
      final d = _distPointToSegment(p, prev, pt);
      if (d < minD) minD = d;
      prev = pt;
    }
    return minD;
  }

  Offset _cubicPoint(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final mt = 1 - t;
    final x = mt * mt * mt * a.dx +
        3 * mt * mt * t * c1.dx +
        3 * mt * t * t * c2.dx +
        t * t * t * b.dx;
    final y = mt * mt * mt * a.dy +
        3 * mt * mt * t * c1.dy +
        3 * mt * t * t * c2.dy +
        t * t * t * b.dy;
    return Offset(x, y);
  }

  double _distPointToSegment(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final apx = p.dx - a.dx;
    final apy = p.dy - a.dy;
    final ab2 = abx * abx + aby * aby;
    double t = ab2 == 0 ? 0 : (apx * abx + apy * aby) / ab2;
    if (t < 0)
      t = 0;
    else if (t > 1) t = 1;
    final cx = a.dx + t * abx;
    final cy = a.dy + t * aby;
    final dx = p.dx - cx;
    final dy = p.dy - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  int _obstacleCount(
    String child,
    String parent,
    Map<String, int> laneOf,
    Map<String, int> rowOf,
  ) {
    final rc = rowOf[child]!;
    final rp = rowOf[parent]!;
    final lc = laneOf[child]!;
    final lp = laneOf[parent]!;
    final rmin = math.min(rc, rp);
    final rmax = math.max(rc, rp);
    final lmin = math.min(lc, lp);
    final lmax = math.max(lc, lp);
    var cnt = 0;
    for (final e in rowOf.entries) {
      final id = e.key;
      if (id == child || id == parent) continue;
      final r = e.value;
      if (r <= rmin || r >= rmax) continue;
      final l = laneOf[id];
      if (l == null) continue;
      if (l >= lmin && l <= lmax) cnt++;
    }
    return cnt;
  }
}

class GraphPainter extends CustomPainter {
  final GraphData data;
  final Map<String, Color> branchColors;
  final String? hoverPairKey;
  final double laneWidth;
  final double rowHeight;
  final WorkingState? working;
  final Set<String> selectedNodes;
  static const double nodeRadius = 6;
  GraphPainter(
    this.data,
    this.branchColors,
    this.hoverPairKey,
    this.laneWidth,
    this.rowHeight, {
    this.working,
    required this.selectedNodes,
  });
  static const List<Color> lanePalette = [
    Color(0xFF1976D2),
    Color(0xFF2E7D32),
    Color(0xFF8E24AA),
    Color(0xFFD81B60),
    Color(0xFF00838F),
    Color(0xFF5D4037),
    Color(0xFF3949AB),
    Color(0xFFF9A825),
    Color(0xFF6D4C41),
    Color(0xFF1E88E5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final commits = data.commits;
    final laneOf = _laneOfByBranches({for (final c in commits) c.id: c});
    final rowOf = <String, int>{};
    final paintNode = Paint()..color = const Color(0xFF1976D2);
    final paintBorder = Paint()
      ..color = const Color(0xFF1976D2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final paintEdge = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final byId = {for (final c in commits) c.id: c};
    final colorMemo = _computeBranchColors(byId);
    // 构造来自分支链的父->子关系，以及对每个边对的出现次数
    final children = <String, List<String>>{}; // parent -> [child]
    final pairCount = <String, int>{};
    for (final entry in data.chains.entries) {
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        (children[parent] ??= <String>[]).add(child);
        final key = '$child|$parent';
        pairCount[key] = (pairCount[key] ?? 0) + 1;
      }
    }

    for (var i = 0; i < commits.length; i++) {
      final c = commits[i];
      rowOf[c.id] = i;
    }

    // 绘制节点
    String? currentHeadId;
    if (data.currentBranch != null) {
      for (final b in data.branches) {
        if (b.name == data.currentBranch) {
          currentHeadId = b.head;
          break;
        }
      }
    }

    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2;
      final y = row * rowHeight + rowHeight / 2;
      final childIds = children[c.id] ?? const <String>[];
      final childColors =
          childIds.map((id) => _colorOfCommit(id, colorMemo)).toSet();
      final isSplit = childIds.length >= 2 && childColors.length >= 2;
      final r = isSplit ? nodeRadius * 1.6 : nodeRadius;

      if (c.id == currentHeadId) {
        final paintCurHead = Paint()
          ..color = Colors.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;
        canvas.drawCircle(Offset(x, y), r + 5, paintCurHead);
      }

      canvas.drawCircle(Offset(x, y), r, paintNode);
      if (isSplit) {
        canvas.drawCircle(Offset(x, y), r, paintBorder);
      }
      if (selectedNodes.contains(c.id)) {
        final paintSel = Paint()
          ..color = Colors.redAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;
        canvas.drawCircle(Offset(x, y), r + 4, paintSel);
      }
    }

    // 绘制来自分支链的边，避免父列表造成的重边
    final pairDrawn = <String, int>{};
    for (final entry in data.chains.entries) {
      final bname = entry.key;
      final bcolor = branchColors[bname] ?? const Color(0xFF9E9E9E);
      final ids = entry.value;
      for (var i = 0; i + 1 < ids.length; i++) {
        final child = ids[i];
        final parent = ids[i + 1];
        if (!rowOf.containsKey(child) || !rowOf.containsKey(parent)) continue;
        final rowC = rowOf[child]!;
        final laneC = laneOf[child]!;
        final x = laneC * laneWidth + laneWidth / 2;
        final y = rowC * rowHeight + rowHeight / 2;
        final rowP = rowOf[parent]!;
        final laneP = laneOf[parent]!;
        final px = laneP * laneWidth + laneWidth / 2;
        final py = rowP * rowHeight + rowHeight / 2;
        final key = '$child|$parent';
        final total = pairCount[key] ?? 1;
        final done = pairDrawn[key] ?? 0;
        pairDrawn[key] = done + 1;
        // 将并行边按顺序左右分开，靠得很近
        final midY = (y + py) / 2;
        final dLane = (laneC - laneP).abs();
        var bendBase = (dLane * 8.0).clamp(8.0, 24.0);
        bendBase += _obstacleCount(child, parent, laneOf, rowOf) * 16.0;
        final dir = laneC <= laneP ? 1.0 : -1.0;
        final spread = (done - (total - 1) / 2.0) * 3.0; // -..0..+
        final path = Path();
        path.moveTo(x, y);
        path.cubicTo(
          x + dir * (bendBase + spread),
          midY,
          px - dir * (bendBase + spread),
          midY,
          px,
          py,
        );
        paintEdge.color = bcolor;
        bool isCurrent = data.currentBranch == bname;
        bool isHover = hoverPairKey != null && hoverPairKey == key;

        paintEdge.strokeWidth = isCurrent ? 4.0 : (isHover ? 3.0 : 2.0);

        if (isCurrent) {
          // Draw a glow/shadow for current branch
          final paintGlow = Paint()
            ..color = bcolor.withValues(alpha: 0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8.0
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
          canvas.drawPath(path, paintGlow);
        }

        canvas.drawPath(path, paintEdge);
      }
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final c in commits) {
      final row = rowOf[c.id]!;
      final lane = laneOf[c.id]!;
      final x = lane * laneWidth + laneWidth / 2 + 10;
      final y = row * rowHeight + rowHeight / 2;
      String msg = c.subject;
      if (msg.length > 10) {
        msg = '${msg.substring(0, 10)}...';
      }

      textPainter.text = TextSpan(
        style: const TextStyle(color: Colors.black, fontSize: 12),
        children: [
          TextSpan(text: '提交id：${c.id.substring(0, 7)}'),
          if (c.refs.isNotEmpty)
            TextSpan(
                text: ' [${c.refs.first}]',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          const TextSpan(text: '\n'),
          TextSpan(text: '提交信息：$msg'),
        ],
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x, y - textPainter.height / 2));
    }

    // 边框分区与当前状态
    int maxLane = -1;
    for (final v in laneOf.values) {
      if (v > maxLane) maxLane = v;
    }
    if (maxLane < 0) maxLane = 0;
    final graphWidth = (maxLane + 1) * laneWidth;
    final graphHeight = commits.length * rowHeight;
    final borderPaint = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Rect.fromLTWH(0, 0, graphWidth, graphHeight), borderPaint);

    if (working?.changed == true) {
      final overlayMargin = 40.0;
      final overlayWidth = 240.0;
      final overlayX = graphWidth + overlayMargin;

      // Fix for empty project: ensure staging area has height
      double overlayHeight = graphHeight;
      if (commits.isEmpty) {
        overlayHeight = rowHeight;
      }

      canvas.drawRect(
        Rect.fromLTWH(overlayX, 0, overlayWidth, overlayHeight),
        borderPaint,
      );
      final baseId = working?.baseId;
      int row = 0;
      if (baseId != null && rowOf.containsKey(baseId)) {
        row = rowOf[baseId]!;
      }
      final cx = overlayX + overlayWidth / 2;
      final cy = row * rowHeight + rowHeight / 2;
      final paintCur = Paint()..color = const Color(0xFFD81B60);
      canvas.drawCircle(Offset(cx, cy), nodeRadius * 1.6, paintCur);
      final labelSpan = TextSpan(
        text: '当前状态',
        style: const TextStyle(color: Colors.black, fontSize: 12),
      );
      textPainter.text = labelSpan;
      textPainter.layout();
      textPainter.paint(canvas, Offset(cx + 10, cy - 8));
    }
  }

  int _obstacleCount(
    String child,
    String parent,
    Map<String, int> laneOf,
    Map<String, int> rowOf,
  ) {
    final rc = rowOf[child]!;
    final rp = rowOf[parent]!;
    final lc = laneOf[child]!;
    final lp = laneOf[parent]!;
    final rmin = math.min(rc, rp);
    final rmax = math.max(rc, rp);
    final lmin = math.min(lc, lp);
    final lmax = math.max(lc, lp);
    var cnt = 0;
    for (final e in rowOf.entries) {
      final id = e.key;
      if (id == child || id == parent) continue;
      final r = e.value;
      if (r <= rmin || r >= rmax) continue;
      final l = laneOf[id];
      if (l == null) continue;
      if (l >= lmin && l <= lmax) cnt++;
    }
    return cnt;
  }

  Color _colorOfCommit(String id, Map<String, Color> memo) {
    return memo[id] ?? const Color(0xFF9E9E9E);
  }

  Map<String, Color> _computeBranchColors(Map<String, CommitNode> byId) {
    final memo = <String, Color>{};
    // Branch priority: master first, then others by name
    final ordered = List<Branch>.from(data.branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    int idx = 0;
    for (final b in ordered) {
      final color =
          branchColors[b.name] ?? lanePalette[idx % lanePalette.length];
      idx++;
      var cur = byId[b.head];
      while (cur != null && memo[cur.id] == null) {
        memo[cur.id] = color;
        if (cur.parents.isEmpty) break;
        final next = byId[cur.parents.first];
        cur = next;
      }
    }
    return memo;
  }

  Map<String, int> _branchLane(List<Branch> branches) {
    final ordered = List<Branch>.from(branches);
    ordered.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;
      return a.name.compareTo(b.name);
    });
    final map = <String, int>{};
    for (var i = 0; i < ordered.length; i++) {
      map[ordered[i].name] = i;
    }
    return map;
  }

  Map<String, int> _laneOfByBranches(Map<String, CommitNode> byId) {
    final laneOf = <String, int>{};
    final branchLane = _branchLane(data.branches);
    final orderedNames = branchLane.keys.toList()
      ..sort((a, b) {
        int pa = a == 'master' ? 0 : 1;
        int pb = b == 'master' ? 0 : 1;
        if (pa != pb) return pa - pb;
        return a.compareTo(b);
      });
    for (final name in orderedNames) {
      final lane = branchLane[name]!;
      final ids = data.chains[name] ?? const <String>[];
      for (final id in ids) {
        laneOf[id] ??= lane;
      }
    }
    for (final c in byId.values) {
      if (laneOf[c.id] != null) continue;
      int? lane;
      for (final p in c.parents) {
        final lp = laneOf[p];
        if (lp != null) {
          lane = lp;
          break;
        }
      }
      final laneVal = lane ?? branchLane.length;
      laneOf[c.id] = laneVal;
    }
    return laneOf;
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}
