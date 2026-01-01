import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';
import 'visualize.dart';
import 'backup.dart';
import 'pull_preview.dart';
import 'graph_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    if (await _checkDuplicateInstance()) {
      runApp(const DuplicateErrorApp());
      return;
    }
  }

  _exposeAlivePort();
  runApp(MaterialApp(
    title: 'LambdaEssay Launcher',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF000A3F)),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000A3F),
        foregroundColor: Colors.white,
      ),
      useMaterial3: true,
    ),
    home: const BootstrapApp(),
  ));
}

Future<void> _notifyStartup() async {
  int retry = 0;
  const maxRetry = 8964;
  while (retry < maxRetry) {
    try {
      print("Notify warden (attempt ${retry + 1})");
      final resp = await http.get(Uri.parse('http://localhost:3040/'));
      if (resp.statusCode == 200) {
        print('Notify warden success: ${resp.statusCode} ${resp.body}');
        final resp2 = await http.get(Uri.parse('http://localhost:3040/'));
        if (resp2.statusCode == 200) {
          print(
              'Second Notify warden success: ${resp2.statusCode} ${resp2.body}');
          return;
        }
        print('Notify warden response: ${resp.statusCode}, retrying...');
        return;
      }
    } catch (e) {
      print('Notify warden error: $e, retrying...');
    }
    retry++;
    await Future.delayed(const Duration(seconds: 1));
  }
  print('Failed to notify startup after $maxRetry attempts');
}

Future<void> _exposeAlivePort() async {
  try {
    // 监听端口仅证明前端存活，不处理实际业务
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 9527);
    print('Alive check port listening on 9527');
    server.listen((HttpRequest request) {
      request.response
        ..statusCode = 200
        ..write('Frontend is alive')
        ..close();
    });
  } catch (e) {
    print('Failed to expose alive port: $e');
  }
}

Future<bool> _checkDuplicateInstance() async {
  try {
    final result = await Process.run('tasklist',
        ['/FO', 'CSV', '/NH', '/FI', 'IMAGENAME eq LambdaEssay.exe']);

    if (result.exitCode != 0) return false;

    final output = result.stdout.toString();
    if (output.contains('No tasks are running')) return false;

    final lines = output.trim().split('\n');
    final currentPid = pid;

    for (var line in lines) {
      final parts = line.split(',');
      if (parts.length >= 2) {
        final pidStr = parts[1].replaceAll('"', '');
        final pId = int.tryParse(pidStr);
        if (pId != null && pId != currentPid) {
          return true;
        }
      }
    }
    return false;
  } catch (e) {
    print('Error checking process: $e');
    return false;
  }
}

class DuplicateErrorApp extends StatelessWidget {
  const DuplicateErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  '已在运行',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text(
                  '检测到 LambdaEssay.exe 正在运行。\n请先关闭已有实例。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => exit(0),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('退出'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key});

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  bool _serverReady = false;
  String _statusMessage = '正在初始化...';
  bool _hasError = false;

  Future<void> _showErrorDialog(String path) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动失败'),
        content: Text('找不到文件:\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      setState(() {
        _statusMessage = '正在启动服务器...';
        _hasError = false;
      });
      if (!kDebugMode) {
        // 1. 获取AppData路径并构建目标目录
        final appData = Platform.environment['APPDATA'];
        if (appData == null) {
          throw Exception('无法找到APPDATA环境变量');
        }
        final rootDir = Directory(p.join(appData, 'gitbin-otherfiles'));
        final binDir = Directory(p.join(rootDir.path, 'bin'));

        // 2. 检查资源并更新
        await _ensureResources(rootDir, binDir);

        // 3. 启动进程
        final serverPath = p.join(binDir.path, 'server.exe');
        final wardenPath = p.join(binDir.path, 'warden.exe');
        final comPath = p.join(binDir.path, 'COM.exe');

        // 验证文件是否存在，如果不存在则强制重试一次
        bool missingFiles = !await File(serverPath).exists() ||
            !await File(wardenPath).exists() ||
            !await File(comPath).exists();

        if (missingFiles) {
          setState(() {
            _statusMessage = '检测到文件缺失，正在重新下载...';
          });
          // 删除目录以触发重新下载
          if (await rootDir.exists()) {
            await rootDir.delete(recursive: true);
          }
          // 再次尝试获取资源
          await _ensureResources(rootDir, binDir);
        }

        if (await File(serverPath).exists()) {
          await Process.start(serverPath, [], mode: ProcessStartMode.detached);
        } else {
          await _showErrorDialog(serverPath);
          return; // 如果仍然失败，终止后续操作
        }
        if (await File(wardenPath).exists()) {
          await Process.start(
              wardenPath, ['--monitor_port', '9527', '--terminal_port', '8080'],
              mode: ProcessStartMode.detached);
        } else {
          await _showErrorDialog(wardenPath);
          return;
        }

        if (await File(comPath).exists()) {
          await Process.start(comPath, [], mode: ProcessStartMode.detached);
        } else {
          await _showErrorDialog(comPath);
          return;
        }
      } // 轮询健康检查接口
      const healthUrl = 'http://localhost:8080/health';
      bool ready = false;
      int retryCount = 0;

      while (!ready) {
        try {
          setState(() {
            _statusMessage = '正在连接服务器... (尝试 ${retryCount + 1})';
          });

          final response = await http.get(Uri.parse(healthUrl));
          if (response.statusCode == 200) {
            final body = jsonDecode(response.body);
            if (body['status'] == 'ok') {
              ready = true;
            }
          }
        } catch (e) {
          // 连接失败，等待重试
        }

        if (!ready) {
          retryCount++;
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      if (mounted) {
        setState(() {
          _serverReady = true;
        });
        // Server 准备就绪，发送启动通知
        if(!kDebugMode)
          _notifyStartup();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '启动失败: $e';
          _hasError = true;
        });
      }
    }
  }

  Future<void> _ensureResources(Directory rootDir, Directory binDir) async {
    try {
      setState(() => _statusMessage = '正在检查资源配置...');
      final configResp =
          await http.get(Uri.parse('https://llinker.com/configfile/'));
      if (configResp.statusCode != 200) throw Exception('无法获取配置文件');

      final config = jsonDecode(configResp.body);
      final zipUrl = config['bin_zip_path'];
      final expectedHash = config['bin_zip_hash'].toString().toLowerCase();

      final zipName = p.basename(Uri.parse(zipUrl).path);
      final localZip = File(p.join(rootDir.path, zipName));

      bool needDownload = false;

      if (await binDir.exists()) {
        // 如果bin存在，检查zip的hash
        if (await localZip.exists()) {
          final bytes = await localZip.readAsBytes();
          final digest = sha256.convert(bytes).toString().toLowerCase();
          if (digest != expectedHash) {
            needDownload = true;
            // hash不同，删除整个目录
            await rootDir.delete(recursive: true);
          }
        } else {
          // zip不存在，视为异常，重新下载
          needDownload = true;
          await rootDir.delete(recursive: true);
        }
      } else {
        // bin不存在
        needDownload = true;
        if (await rootDir.exists()) {
          await rootDir.delete(recursive: true);
        }
      }

      if (needDownload) {
        await rootDir.create(recursive: true);
        // Zip包中已经包含了bin文件夹，所以解压到rootDir即可
        await _downloadAndUnzip(zipUrl, localZip, rootDir);
      }
    } catch (e) {
      // 这里的错误会由调用者捕获
      rethrow;
    }
  }

  Future<void> _downloadAndUnzip(
      String url, File targetFile, Directory extractDir) async {
    final progressNotifier = ValueNotifier<double>(0.0);

    // 显示下载进度对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在下载必要组件...'),
          content: ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, value, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 10),
                  Text('${(value * 100).toStringAsFixed(1)}%'),
                ],
              );
            },
          ),
        ),
      ),
    );

    try {
      final request =
          await http.Client().send(http.Request('GET', Uri.parse(url)));
      final contentLength = request.contentLength ?? 0;
      int received = 0;

      final sink = targetFile.openWrite();
      await request.stream.listen(
        (chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            progressNotifier.value = received / contentLength;
          }
        },
        onDone: () async {
          await sink.close();
        },
        onError: (e) {
          sink.close();
          throw e;
        },
      ).asFuture();

      if (!mounted) return;
      // 关闭下载对话框
      Navigator.of(context).pop();

      // 显示解压对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('正在解压...'),
              ],
            ),
          ),
        ),
      );

      // 解压
      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
      }

      final bytes = await targetFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        final filename = file.name;
        final outputPath = p.join(extractDir.path, filename);
        if (file.isFile) {
          final data = file.content as List<int>;
          final outputFile = File(outputPath);
          // 确保父目录存在
          await outputFile.parent.create(recursive: true);
          await outputFile.writeAsBytes(data, flush: true);
        } else {
          await Directory(outputPath).create(recursive: true);
        }
      }

      if (!mounted) return;
      // 关闭解压对话框
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        // 尝试关闭对话框
        Navigator.of(context).pop();
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_serverReady) {
      return const GitGraphApp();
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_hasError) const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(_statusMessage),
            if (_hasError)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: ElevatedButton(
                  onPressed: _startServer,
                  child: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GitGraphApp extends StatelessWidget {
  const GitGraphApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LambdaEssay',
      theme: ThemeData.light(),
      home: const GraphPage(),
    );
  }
}

class GraphPage extends StatefulWidget {
  const GraphPage({super.key});
  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> with TickerProviderStateMixin {
  final TextEditingController pathCtrl = TextEditingController();
  final TextEditingController limitCtrl = TextEditingController(text: '500');
  final TextEditingController docxPathCtrl = TextEditingController();
  GraphData? data;
  GraphData? remoteData; // New: Remote graph data
  bool showRemotePreview = true; // New: Toggle for remote preview
  Map<String, int>? localRowMapping;
  Map<String, int>? remoteRowMapping;
  int? totalRows;
  final TransformationController _sharedController = TransformationController();
  late AnimationController _sidebarFlashCtrl;

  @override
  void dispose() {
    _channel?.sink.close();
    _sidebarFlashCtrl.dispose();
    _sharedController.dispose();
    pathCtrl.dispose();
    limitCtrl.dispose();
    docxPathCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    emailCtrl.dispose();
    verifyCodeCtrl.dispose();
    super.dispose();
  }

  bool loading = false;
  String? error;
  String? currentProjectName;
  WorkingState? working;
  List<String> identicalCommitIds = [];

  final TextEditingController userCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController verifyCodeCtrl = TextEditingController();
  bool _isRegisterMode = false;

  String? _username;
  String? _token;

  double _uiScale = 1.0;

  static const String baseUrl = 'http://localhost:8080';

  WebSocketChannel? _channel;

  @override
  void initState() {
    super.initState();
    _checkLogin();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    if (!mounted) return;
    try {
      _channel =
          WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws/client'));
      _channel!.stream.listen((message) {
        if (!mounted) return;
        try {
          final data = jsonDecode(message);
          if (data['type'] == 'loading_status') {
            setState(() {
              loading = data['loading'] == true;
            });
          } else if (data['type'] == 'repo_updated') {
            print("Received repo update notification");
            if (currentProjectName != null) {
              _onUpdateRepoAction().whenComplete(() {
                if (mounted) {
                  setState(() {
                    loading = false;
                  });
                }
              });
            }
          }
        } catch (e) {
          print("WebSocket message error: $e");
        }
      }, onError: (e) {
        print("WebSocket connection error: $e");
        if (mounted)
          Future.delayed(const Duration(seconds: 5), _connectWebSocket);
      }, onDone: () {
        print("WebSocket connection closed");
        if (mounted)
          Future.delayed(const Duration(seconds: 5), _connectWebSocket);
      });
    } catch (e) {
      print("WebSocket connection failed: $e");
      if (mounted)
        Future.delayed(const Duration(seconds: 5), _connectWebSocket);
    }
    _sidebarFlashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  // void _onScaleChanged() { ... } // Removed

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
            // print("AuthKey refreshed automatically: $_token");
          }
        }
      } catch (e) {
        // print("Failed to refresh tokens: $e");
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
        // print("ensureToken failed: $e");
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
      // print("doLogin");
      // print(tokens);
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
      // print("_createGiteaUserAndSetToken");
      // print(tokens);
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
        title: const Text('分享追踪项目'),
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
      if (showRemotePreview) {
        await _triggerGitFetch(repoPath);
      }
      await _load();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('non-fast-forward') || msg.contains('fetch first')) {
        if (!mounted) return;
        await _showPushRejectedDialog(msg);
        return;
      }
      setState(() => error = '推送失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _showPushRejectedDialog(String message) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('推送被拒绝'),
        content: Text('远程分支包含您本地没有的更改。\n\n'
            '$message\n\n'
            '推荐使用“解决冲突”来保留双方更改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'force'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('强制推送 (覆盖远程)'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'resolve'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('把差异作为一个新的commit (推荐)'),
          ),
        ],
      ),
    );

    if (choice == 'force') {
      // Proceed with existing force push logic (3 confirmations)
      // We can just recall _onPush(force: true) but that skips the 3 confirmations?
      // No, _onPush(force: true) executes directly.
      // But the requirement was "if rejected, user has 2 choices".
      // The user also mentioned "Force push" logic exists.
      // Let's reuse the triple confirmation by just returning 'force' to caller?
      // But caller is _onPush which is async.
      // Let's implement the sub-dialogs here.
      await _confirmForcePush();
    } else if (choice == 'resolve') {
      await _showResolveConflictDialog(isPush: true);
    }
  }

  Future<void> _confirmForcePush() async {
    // 第一重确认
    final ok1 = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('危险操作确认'),
        content: const Text('您选择了强制推送。\n'
            '此操作将【永久覆盖】远程仓库的历史记录，无法撤销！\n'
            '建议您先尝试“解决冲突”选项。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我确定要覆盖'),
          ),
        ],
      ),
    );
    if (ok1 != true) return;

    // 第二重确认
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('最后一次确认'),
        content: const Text('请再次确认：\n'
            '您是否清楚这会导致远程仓库的提交丢失？\n'
            '如果这是多人协作项目，请务必通知其他成员！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('执行强制推送'),
          ),
        ],
      ),
    );

    if (ok2 == true) {
      await _onPush(force: true);
    }
  }

  Future<void> _showResolveConflictDialog({required bool isPush}) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择解决方式'),
        content: const Text('请选择如何处理本地与远程的差异：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () async {
              if (currentProjectName == null ||
                  _username == null ||
                  _token == null) return;
              final ok = await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => PullPreviewPage(
                            repoName: currentProjectName!,
                            username: _username!,
                            token: _token!,
                            type: 'fork',
                          )));
              if (ok == true && ctx.mounted) Navigator.pop(ctx, 'fork');
            },
            child: const Text('分叉 (Fork)'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (currentProjectName == null ||
                  _username == null ||
                  _token == null) return;
              final ok = await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => PullPreviewPage(
                            repoName: currentProjectName!,
                            username: _username!,
                            token: _token!,
                            type: 'rebase',
                          )));
              if (ok == true && ctx.mounted) Navigator.pop(ctx, 'rebase');
            },
            child: const Text('在远程提交后附着 (Rebase)'),
          ),
          if (!isPush)
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                if (currentProjectName == null ||
                    _username == null ||
                    _token == null) return;
                final ok = await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => PullPreviewPage(
                              repoName: currentProjectName!,
                              username: _username!,
                              token: _token!,
                              type: 'force',
                            )));
                if (ok == true && ctx.mounted) Navigator.pop(ctx, 'force');
              },
              child: const Text('强制覆盖 (Force Overwrite)'),
            ),
          const SizedBox(height: 16),
          TextButton.icon(
            icon: const Icon(Icons.compare_arrows),
            label: const Text('预览冲突差异 (Preview Differences)'),
            onPressed: () async {
              if (currentProjectName == null ||
                  _username == null ||
                  _token == null) return;
              // Use 'force' preview type which shows side-by-side comparison
              // This is effectively what "preview conflict" means (mine vs theirs)
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => PullPreviewPage(
                            repoName: currentProjectName!,
                            username: _username!,
                            token: _token!,
                            type: 'force',
                          )));
            },
          ),
        ],
      ),
    );

    if (choice == 'rebase') {
      await _doRebasePull(isPush: isPush);
    } else if (choice == 'fork') {
      await _doForkLocal(isPush: isPush);
    } else if (choice == 'force') {
      await _doForcePull();
    }
  }

  Future<void> _doForcePull() async {
    setState(() => loading = true);
    try {
      final resp = await _postJson('http://localhost:8080/pull', {
        'repoName': currentProjectName,
        'username': _username,
        'token': _token,
        'force': true,
      });

      final isFresh = resp['isFresh'] == true;
      if (currentProjectName != null) {
        await _checkAndSetupTracking(currentProjectName!, isFresh);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('强制拉取成功')),
        );
      }
      await _load();
      await _onUpdateRepo();
    } catch (e) {
      setState(() => error = '强制拉取失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _doRebasePull({required bool isPush}) async {
    setState(() => loading = true);
    try {
      // Rebase pull
      await _postJson('http://localhost:8080/pull_rebase', {
        'repoName': currentProjectName,
        'username': _username,
        'token': _token,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('附着成功 (Rebase Success)')),
        );
      }

      // If this was triggered by Push, we should try to push again?
      // User said "attach local... then push".
      if (isPush) {
        // Push again (normal push, should succeed now if no conflict)
        await _onPush();
      } else {
        // Just reload
        await _load();
        await _onUpdateRepoAction(forcePull: false, opIdentical: false);
      }
    } catch (e) {
      setState(() => error = '附着失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _doForkLocal({required bool isPush}) async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('分叉分支'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请输入新分支名称 (将包含您的本地修改)'),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '新分支名称'),
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
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    final newBranch = nameCtrl.text.trim();
    if (newBranch.isEmpty) return;

    setState(() => loading = true);
    try {
      await _postJson('http://localhost:8080/fork_local', {
        'repoName': currentProjectName,
        'newBranch': newBranch,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已分叉到 $newBranch')),
        );
      }

      // Reload to reflect branch switch
      await _load();
      await _onUpdateRepoAction(forcePull: false,opIdentical: false);

      // If Push, push the NEW branch
      if (isPush) {
        // We are now on newBranch. Push it.
        await _onPush();
      }
    } catch (e) {
      setState(() => error = '分叉失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _checkAndSetupTracking(String repoName, bool isFresh) async {
    setState(() {
      if (isFresh) {
        currentProjectName = repoName;
      }
    });

    if (isFresh) {
      final docxCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('设置追踪文档'),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('这是一个新的克隆（或已被重置），请重新设置要追踪的Word文档(.docx)或解包文件夹'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: docxCtrl,
                          decoration: const InputDecoration(
                            labelText: 'docx文件路径或解包文件夹路径',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.insert_drive_file),
                        tooltip: '选择文件',
                        onPressed: () async {
                          FilePickerResult? result =
                              await FilePicker.platform.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['docx'],
                          );
                          if (result != null &&
                              result.files.single.path != null) {
                            docxCtrl.text = result.files.single.path!;
                          }
                        },
                      ),
                    ],
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
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('设置文档失败: $e')));
            }
          }
        }
      }
    }
  }

  Future<void> _onPull() async {
    if (!await _ensureToken()) {
      setState(() => error = '请先登录');
      return;
    }

    // 直接使用当前打开的项目名称，不再让用户选择
    if (currentProjectName == null || currentProjectName!.isEmpty) {
      setState(() => error = '当前未打开任何项目，无法拉取');
      return;
    }
    final repoName = currentProjectName!;

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
          if (isAhead) {
            // Show resolve options for Ahead/Diverged
            await _showResolveConflictDialog(isPush: false);
          } else {
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
                ],
              ),
            );
          }
        } else {
          setState(() => error = '拉取失败，位于onPull: $message');
        }
        return;
      }

      final isFresh = resp['isFresh'] == true;

      await _checkAndSetupTracking(repoName, isFresh);

      // Reload again to update graph if needed (e.g. fresh clone or new commits)
      await _load();
      // Force repo update after pull to sync semantic changes
      await _onUpdateRepo();

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('拉取成功')));
    } catch (e) {
      setState(() => error = '拉取失败，什么玩意: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _onUpdateRepo() async {
    final name = currentProjectName;
    if (name == null || name.isEmpty) return;

    try {
      final resp = await _postJson('http://localhost:8080/track/update', {
        'name': name,
      });
      final needDocx = resp['needDocx'] == true;

      if (!needDocx) {
        final workingChanged = resp['workingChanged'] == true;
        final repoPath = resp['repoPath'] as String;
        final head = resp['head'] as String?;

        // Now load graph
        final data = await _loadGraph(repoPath);

        setState(() {
          pathCtrl.text = repoPath;
          working = WorkingState(
            changed: workingChanged,
            baseId: head,
          );
          this.data = data;
          error = null;
        });
      }
    } catch (e) {
      print('Auto-update failed: $e');
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

  Future<GraphData> _loadGraph(String repoPath) async {
    final limit = int.tryParse(limitCtrl.text.trim());
    // Reset cache on server first? Not strictly needed but good for consistency
    await http.post(
      Uri.parse('http://localhost:8080/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
    );
    final resp = await http.post(
      Uri.parse('http://localhost:8080/graph'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'repoPath': repoPath, 'limit': limit}),
    );
    if (resp.statusCode != 200) {
      throw Exception('后端错误: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return GraphData.fromJson(j);
  }

  Future<GraphData> _fetchRemoteGraph(String repoPath) async {
    final limit = int.tryParse(limitCtrl.text.trim());
    final resp = await http.post(
      Uri.parse('http://localhost:8080/remote_graph'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'repoPath': repoPath,
        'limit': limit,
        'remoteNames': [], // Empty list requests all remotes
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('Remote graph fetch error: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return GraphData.fromJson(j);
  }

  Future<void> _triggerGitFetch(String repoPath) async {
    try {
      await http.post(
        Uri.parse('http://localhost:8080/fetch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'repoPath': repoPath}),
      );
    } catch (e) {
      print('Fetch failed: $e');
    }
  }

  Future<void> _load() async {
    final path = pathCtrl.text.trim();
    if (path.isEmpty) {
      setState(() => error = '请输入本地仓库路径');
      return;
    }
    setState(() {
      loading = true;
      error = null;
      data = null;
      remoteData = null;
      localRowMapping = null;
      remoteRowMapping = null;
      totalRows = null;
      // showRemotePreview = false; // Preserve user choice
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
      final gd = await _loadGraph(path);
      GraphData? rd;
      if (showRemotePreview) {
        try {
          await _triggerGitFetch(path);
          rd = await _fetchRemoteGraph(path);
        } catch (e) {
          print('Remote graph fetch failed: $e');
        }
      }

      setState(() {
        data = gd;
        remoteData = rd;
        loading = false;
      });

      if (rd != null) {
        _calculateRowMappings();
      }
    } catch (e) {
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  void _calculateRowMappings() {
    if (data == null || remoteData == null) return;

    final localIds = data!.commits.map((c) => c.id).toSet();
    final remoteIds = remoteData!.commits.map((c) => c.id).toSet();

    final allCommits = <String, CommitNode>{};
    for (final c in data!.commits) allCommits[c.id] = c;
    for (final c in remoteData!.commits) allCommits[c.id] = c;

    final sorted = allCommits.values.toList();
    sorted.sort((a, b) {
      final d = b.date.compareTo(a.date);
      if (d != 0) return d;
      return b.id.compareTo(a.id);
    });

    final localMap = <String, int>{};
    final remoteMap = <String, int>{};

    for (int i = 0; i < sorted.length; i++) {
      final c = sorted[i];
      if (localIds.contains(c.id)) {
        localMap[c.id] = i;
      }
      if (remoteIds.contains(c.id)) {
        remoteMap[c.id] = i;
      }
    }

    setState(() {
      localRowMapping = localMap;
      remoteRowMapping = remoteMap;
      totalRows = sorted.length;
    });
  }

  Future<void> _onCreateTrackProject() async {
    final nameCtrl = TextEditingController();
    final docxCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('新建追踪项目'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '项目名称'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: docxCtrl,
                        decoration: const InputDecoration(
                          labelText: 'docx文件路径或解包文件夹',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.insert_drive_file),
                      tooltip: '选择文件',
                      onPressed: () async {
                        FilePickerResult? result =
                            await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['docx'],
                        );
                        if (result != null &&
                            result.files.single.path != null) {
                          docxCtrl.text = result.files.single.path!;
                        }
                      },
                    ),
                  ],
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
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final docx = docxCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => error = '请输入项目名称');
      return;
    }
    if (name == 'cache' || name == 'preview') {
      setState(() => error = '项目名称不能为 "cache" 或 "preview" (保留名称)');
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
        final list = (body['projects'] as List).cast<String>();
        return list.where((p) => p != 'cache' && p != 'preview').toList();
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
        builder: (context, innerSetState) => AlertDialog(
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
                      innerSetState(() => selected = v);
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
                  : () {
                      // 立即设置loading，防止UI延迟
                      setState(() => loading = true);
                      Navigator.pop(context, true);
                    },
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || selected == null) return;
    final name = selected!;

    // 立即显示加载遮罩
    setState(() => loading = true);

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
      // Auto update after opening/selecting repo to sync latest status
      await _onUpdateRepoAction(forcePull: true,opIdentical: false);
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _findIdentical() async {
    if (currentProjectName == null) return;

    // 1. Update Repo
    await _onUpdateRepoAction();

    setState(() {
      loading = true;
      identicalCommitIds = []; // Reset
    });

    try {
      final resp = await _postJson('$baseUrl/track/find_identical', {
        'name': currentProjectName,
      });
      final commitIds = (resp['commitIds'] as List?)?.cast<String>() ?? [];
      setState(() {
        identicalCommitIds = commitIds;
      });

      if (mounted) {
        if (commitIds.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('找到 ${commitIds.length} 个相同版本')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到完全相同的版本')),
          );
        }
      }
    } catch (e) {
      setState(() => error = '查找失败: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  bool _isUpdatingRepo = false;

  Future<void> _onUpdateRepoAction({bool forcePull = false, bool opIdentical=true}) async {
    final sw = Stopwatch()..start();
    if (_isUpdatingRepo) return;
    _isUpdatingRepo = true;
    setState(() => loading = true);
    try {
      print("Updating repo...");
      String? name = currentProjectName;
      if (name == null || name.isEmpty) {
        // We are already loading, so no need to set loading=true again
        final projects = await _fetchProjectList();
        // Do not set loading=false here, we want to keep it loading until the end
        // setState(() => loading = false);

        String? selected = projects.isNotEmpty ? projects.first : null;

        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('如果文档没同步就点我'),
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

      // Auto pull logic when opening/updating repo to ensure freshness
      // Changed to silent fetch only as per user request
      if (forcePull) {
        try {
          // Only fetch if we have username/token
          if (_username != null &&
              _token != null &&
              _username!.isNotEmpty &&
              _token!.isNotEmpty) {
            print('Silent fetching for $name...');
            final swFetch = Stopwatch()..start();
            try {
              // Check status performs git fetch internally
              await _postJson('http://localhost:8080/check_pull_status', {
                'repoName': name,
                'username': _username,
                'token': _token,
              });
              // Intentionally ignore the result - just fetch silently
            } catch (e) {
              print('Silent fetch failed: $e');
            }
            print('[Perf][Frontend][UpdateRepo][Fetch] ${swFetch.elapsedMilliseconds}ms');
            swFetch.stop();
          }
        } catch (e) {
          // Ignore outer errors
        }
      }

      try {
        final swUpdate = Stopwatch()..start();
        final resp = await _postJson('http://localhost:8080/track/update', {
          'name': name,
          'opIdentical':opIdentical
        });
        print('[Perf][Frontend][UpdateRepo][TrackUpdate] ${swUpdate.elapsedMilliseconds}ms');
        swUpdate.reset();
        
        final needDocx = resp['needDocx'] == true;
        if (needDocx) {
          String? docx = docxPathCtrl.text.trim();
          bool askUser = docx.isEmpty;

          if (askUser) {
            final docxCtrl = TextEditingController();
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => StatefulBuilder(
                builder: (context, setState) => AlertDialog(
                  title: const Text('选择docx文件路径'),
                  content: SizedBox(
                    width: 500,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: docxCtrl,
                            decoration: const InputDecoration(
                              labelText: 'docx文件路径或解包文件夹',
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.insert_drive_file),
                          tooltip: '选择文件',
                          onPressed: () async {
                            FilePickerResult? result =
                                await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['docx'],
                            );
                            if (result != null &&
                                result.files.single.path != null) {
                              docxCtrl.text = result.files.single.path!;
                            }
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
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确定'),
                    ),
                  ],
                ),
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
        print('[Perf][Frontend][UpdateRepo][SetState] ${swUpdate.elapsedMilliseconds}ms');
        swUpdate.reset();
        
        await _load();
        print('[Perf][Frontend][UpdateRepo][LoadGraph] ${swUpdate.elapsedMilliseconds}ms');
        swUpdate.stop();
      } catch (e) {
        setState(() => error = e.toString());
      }
    } finally {
      _isUpdatingRepo = false;
      if (mounted) setState(() => loading = false);
      sw.stop();
      print('[Perf][Frontend][UpdateRepo][Total] ${sw.elapsedMilliseconds}ms');
    }
  }

  Future<void> _performMerge(String targetBranch) async {
    // Step 1: Warning
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('合并分支/提交'),
        content: Text(
            '您即将把 ${targetBranch.length > 7 ? targetBranch.substring(0, 7) : targetBranch} 合并到当前分支。\n\n'
            '1. 请务必先【关闭 Word 文档】。\n'
            '2. 系统将自动生成差异文档。\n'
            '3. 您需要手动编辑差异文档以解决冲突。\n\n'
            '是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始合并'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;

    // Step 2: Prepare Merge
    setState(() => loading = true);

    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/prepare_merge'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoName': currentProjectName ?? '',
          'targetBranch': targetBranch,
        }),
      );

      setState(() => loading = false);

      if (resp.statusCode != 200) {
        throw Exception('准备合并失败: ${resp.body}');
      }

      // Step 3 & 4: User Review Loop
      bool confirmed = false;
      while (!confirmed) {
        // Step 3: User Review
        final confirm = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('处理合并冲突'),
            content: const Text('差异文档已生成并替换了您的追踪文件。\n\n'
                '请现在打开 Word 文档：\n'
                '1. 查看“修订”内容。\n'
                '2. 接受或拒绝更改以解决冲突。\n'
                '3. 保存并关闭文档。\n\n'
                '完成后，点击“确认合并完成”。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消合并 (还原文件)'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认合并完成'),
              ),
            ],
          ),
        );

        if (confirm != true) {
          // Restore logic if cancelled in Step 3
          setState(() => loading = true);
          await http.post(
            Uri.parse('http://localhost:8080/restore_docx'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'repoName': currentProjectName ?? ''}),
          );
          setState(() => loading = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('合并已取消，文档已还原')),
            );
          }
          return;
        }

        // Step 4: Double Confirmation
        final doubleCheck = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('最后确认'),
            content: const Text('您确定已经处理完所有冲突并保存了吗？\n'
                '即将生成合并提交。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('我还要再看看'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定执行'),
              ),
            ],
          ),
        );

        if (doubleCheck == true) {
          confirmed = true;
        }
        // If doubleCheck is false, loop back to Step 3
      }

      if (!mounted) return;
      setState(() => loading = true);

      // Step 5: Auto Update Repo (Sync)
      // await _onUpdateRepoAction(forcePull: false);

      // Step 6: Complete Merge
      final resp2 = await http.post(
        Uri.parse('http://localhost:8080/complete_merge'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoName': currentProjectName ?? '',
          'targetBranch': targetBranch,
        }),
      );

      // Don't turn off loading here to prevent flickering
      // setState(() => loading = false);

      if (resp2.statusCode != 200) {
        throw Exception('完成合并失败: ${resp2.body}');
      }

      // Force clear cache on server
      await http.post(Uri.parse('http://localhost:8080/reset'));

      // Step 7: Update repo
      // Add delay
      //await Future.delayed(const Duration(milliseconds: 1000));
      if (mounted) {
        print("Auto-updating after merge...");
        await _onUpdateRepoAction(forcePull: false,opIdentical: false);
        // Ensure loading is off if _onUpdateRepoAction didn't do it (e.g. early return)
        if (mounted && loading) {
          setState(() => loading = false);
        }
      }
      // Reload graph
      // await _load();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('合并成功！')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _onChangeDocxPath() async {
    if (currentProjectName == null) return;
    final name = currentProjectName!;
    final docxCtrl = TextEditingController(text: docxPathCtrl.text);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('修改Docx路径: $name'),
          content: SizedBox(
            width: 500,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: docxCtrl,
                    decoration: const InputDecoration(
                      labelText: 'c:\\path\\to\\file.docx',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.insert_drive_file),
                  tooltip: '选择文件',
                  onPressed: () async {
                    FilePickerResult? result =
                        await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['docx'],
                    );
                    if (result != null && result.files.single.path != null) {
                      docxCtrl.text = result.files.single.path!;
                    }
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
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
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
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: const Text('LambdaEssay')),
          body: Column(
            children: [
              MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(_uiScale)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                                            decoration: const InputDecoration(
                                                labelText: '邮箱'))),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                        onPressed: loading ? null : _sendCode,
                                        child: const Text('发送验证码')),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: TextField(
                                            controller: verifyCodeCtrl,
                                            decoration: const InputDecoration(
                                                labelText: '验证码'))),
                                  ]),
                                  const SizedBox(height: 8),
                                  Row(children: [
                                    Expanded(
                                        child: TextField(
                                            controller: userCtrl,
                                            decoration: const InputDecoration(
                                                labelText: '用户名'))),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: TextField(
                                            controller: passCtrl,
                                            obscureText: true,
                                            decoration: const InputDecoration(
                                                labelText: '密码'))),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                        onPressed: loading ? null : _doRegister,
                                        child: const Text('注册')),
                                    const SizedBox(width: 8),
                                    TextButton(
                                        onPressed: () => setState(
                                            () => _isRegisterMode = false),
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
                                          decoration: const InputDecoration(
                                              labelText: '密码'))),
                                  const SizedBox(width: 8),
                                  ElevatedButton(
                                      onPressed: loading ? null : _doLogin,
                                      child: const Text('登录')),
                                  const SizedBox(width: 8),
                                  TextButton(
                                      onPressed: () => setState(
                                          () => _isRegisterMode = true),
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
                              onPressed: _showShareDialog,
                              child: const Text('分享仓库')),
                          const SizedBox(width: 8),
                          ElevatedButton(
                              onPressed: loading ? null : _doLogout,
                              child: const Text('登出'))
                        ]),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          const Text('整体缩放: '),
                          SizedBox(
                            width: 200,
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
                          Text(_uiScale.toStringAsFixed(1)),
                          const SizedBox(width: 16),
                          IconButton(
                            onPressed: () {
                              _sharedController.value = Matrix4.identity();
                            },
                            tooltip: '重置视图',
                            icon: const Icon(Icons.center_focus_strong),
                          ),
                        ],
                      ),
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
                            onPressed: loading ? null: () => _onUpdateRepoAction(opIdentical: false),
                            child: const Text('如果文档没同步就点我'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: loading ? null : _onPush,
                            child: const Text('推送本地追踪项目到远程'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: loading ? null : _onPull,
                            child: const Text('从远程拉取追踪项目到本地'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: loading
                                ? null
                                : () {
                                    setState(() {
                                      showRemotePreview = !showRemotePreview;
                                    });
                                    if (showRemotePreview) {
                                      _load();
                                    } else {
                                      setState(() {
                                        remoteData = null;
                                        localRowMapping = null;
                                        remoteRowMapping = null;
                                        totalRows = null;
                                      });
                                    }
                                  },
                            icon: Icon(showRemotePreview
                                ? Icons.visibility_off
                                : Icons.visibility),
                            label: Text(showRemotePreview ? '隐藏远程' : '显示远程'),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            const Text('追踪文档的路径: '),
                            Expanded(
                              child: TextField(
                                controller: docxPathCtrl,
                                readOnly: true,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding:
                                      EdgeInsets.symmetric(horizontal: 8),
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
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(error!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: data == null
                    ? const Center(child: Text('输入路径并点击加载'))
                    : (showRemotePreview && remoteData != null)
                        ? Row(
                            children: [
                              Expanded(
                                flex: 1,
                                child: Container(
                                  decoration: const BoxDecoration(
                                    border: Border(
                                        right: BorderSide(color: Colors.grey)),
                                  ),
                                  child: Column(
                                    children: [
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(8.0),
                                        color: Colors.grey.shade200,
                                        child: const Text(
                                          '远程文档跟踪',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      Expanded(
                                        child: _GraphView(
                                          data: remoteData!,
                                          repoPath: pathCtrl.text.trim(),
                                          projectName: currentProjectName,
                                          token: _token,
                                          readOnly: true,
                                          primaryBranchName: 'origin/master',
                                          customRowMapping: remoteRowMapping,
                                          totalRows: totalRows,
                                          transformationController:
                                              _sharedController,
                                          uiScale: _uiScale,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Column(
                                  children: [
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(8.0),
                                      color: Colors.grey.shade200,
                                      child: const Text(
                                        '本地文档跟踪',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    Expanded(
                                      child: _GraphView(
                                        data: data!,
                                        working: (data!.commits.isEmpty &&
                                                working != null)
                                            ? WorkingState(
                                                changed: true,
                                                baseId: working!.baseId)
                                            : working,
                                        repoPath: pathCtrl.text.trim(),
                                        projectName: currentProjectName,
                                        token: _token,
                                        onRefresh: _load,
                                        onUpdate: _onUpdateRepoAction,
                                        onMerge: _performMerge,
                                        onFindIdentical: _findIdentical,
                                        identicalCommitIds: identicalCommitIds,
                                        onLoading: (v) =>
                                            setState(() => loading = v),
                                        transformationController:
                                            _sharedController,
                                        uiScale: _uiScale,
                                        customRowMapping: localRowMapping,
                                        totalRows: totalRows,
                                        primaryBranchName: 'master',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : _GraphView(
                            data: data!,
                            working: (data!.commits.isEmpty && working != null)
                                ? WorkingState(
                                    changed: true, baseId: working!.baseId)
                                : working,
                            repoPath: pathCtrl.text.trim(),
                            projectName: currentProjectName,
                            token: _token,
                            onRefresh: _load,
                            onUpdate: _onUpdateRepoAction,
                            onMerge: _performMerge,
                            onFindIdentical: _findIdentical,
                            identicalCommitIds: identicalCommitIds,
                            onLoading: (v) => setState(() => loading = v),
                            transformationController: _sharedController,
                            uiScale: _uiScale,
                            primaryBranchName: 'master',
                          ),
              ),
            ],
          ),
        ),
        if (loading)
          const Opacity(
            opacity: 0.3,
            child: ModalBarrier(dismissible: false, color: Colors.black),
          ),
        if (loading) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _GraphView extends StatefulWidget {
  final GraphData data;
  final WorkingState? working;
  final String repoPath;
  final String? projectName;
  final String? token;
  final VoidCallback? onRefresh;
  final Future<void> Function({bool forcePull, bool opIdentical})? onUpdate;
  final Future<void> Function(String)? onMerge;
  final Future<void> Function()? onFindIdentical;
  final List<String>? identicalCommitIds;
  final Function(bool)? onLoading;
  final TransformationController? transformationController;
  final double uiScale;
  final bool readOnly; // New
  final String primaryBranchName; // New
  final Map<String, int>? customRowMapping; // New
  final int? totalRows; // New

  const _GraphView({
    required this.data,
    this.working,
    required this.repoPath,
    this.projectName,
    this.token,
    this.onRefresh,
    this.onUpdate,
    this.onMerge,
    this.onFindIdentical,
    this.identicalCommitIds,
    this.onLoading,
    this.transformationController,
    this.uiScale = 1.0,
    this.readOnly = false,
    this.primaryBranchName = 'master',
    this.customRowMapping,
    this.totalRows,
  });
  @override
  State<_GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<_GraphView>
    with SingleTickerProviderStateMixin {
  late TransformationController _tc;
  late AnimationController _graphFlashCtrl;
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

  @override
  void initState() {
    super.initState();
    _tc = widget.transformationController ?? TransformationController();
    _graphFlashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _graphFlashCtrl.dispose();
    if (widget.transformationController == null) {
      _tc.dispose();
    }
    super.dispose();
  }

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

    // Notify parent to lock UI
    widget.onLoading?.call(true);
    setState(() => _comparing = true);

    try {
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

      if (resp.statusCode != 200) {
        throw Exception(resp.body);
      }
      final pdfBytes = resp.bodyBytes;
      if (!mounted) return;

      // Unlock UI before navigation
      widget.onLoading?.call(false);

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
      widget.onLoading?.call(false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('对比失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _comparing = false);
      // Ensure unlocked in case we didn't unlock before
      widget.onLoading?.call(false);
    }
  }

  Future<void> _onCommit() async {
    final authorCtrl = TextEditingController();
    final msgCtrl = TextEditingController();

    // Dialog state
    bool isPreviewing = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('提交更改'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: authorCtrl,
                    decoration: const InputDecoration(labelText: '作者姓名'),
                    enabled: !isPreviewing,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: msgCtrl,
                    decoration: const InputDecoration(
                      labelText: '备注信息 (Commit Message)',
                    ),
                    maxLines: 3,
                    enabled: !isPreviewing,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isPreviewing
                    ? null
                    : () async {
                        setState(() => isPreviewing = true);
                        widget.onLoading?.call(true);
                        try {
                          final resp = await http.post(
                            Uri.parse('http://localhost:8080/compare_working'),
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({'repoPath': widget.repoPath}),
                          );
                          if (resp.statusCode != 200) {
                            throw Exception(resp.body);
                          }
                          if (!mounted) return;

                          // Push and wait for return to keep buttons disabled
                          await Navigator.push(
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
                        } finally {
                          if (context.mounted) {
                            setState(() => isPreviewing = false);
                          }
                          widget.onLoading?.call(false);
                        }
                      },
                child: isPreviewing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('预览差异'),
              ),
              TextButton(
                onPressed:
                    isPreviewing ? null : () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed:
                    isPreviewing ? null : () => Navigator.pop(context, true),
                child: const Text('提交'),
              ),
            ],
          );
        },
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

    widget.onLoading?.call(true);
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
      // Use onUpdate which should map to _onUpdateRepo in parent
      if (widget.onUpdate != null) {
        await widget.onUpdate!(opIdentical:false);
      } else {
        // Fallback if onUpdate not provided (should not happen in main usage)
        if (widget.onRefresh != null) widget.onRefresh!();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提交成功')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('提交失败: $e')));
      }
    } finally {
      widget.onLoading?.call(false);
    }
  }

  Future<void> _onCreateBranch() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;

    widget.onLoading?.call(true);
    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/branch/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoPath': widget.repoPath,
          'branchName': Branch.encodeName(name)
        }),
      );
      if (resp.statusCode != 200) throw Exception(resp.body);

      if (!mounted) return;
      if (widget.onUpdate != null) {
        await widget.onUpdate!(forcePull: false);
      } else {
        if (widget.onRefresh != null) widget.onRefresh!();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建失败: $e')));
      }
    } finally {
      widget.onLoading?.call(false);
    }
  }

  Future<void> _doSwitchBranch(String name) async {
    final sw = Stopwatch()..start();
    widget.onLoading?.call(true);
    try {
      final swStep = Stopwatch()..start();
      final resp = await http.post(
        Uri.parse('http://localhost:8080/branch/switch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'projectName': widget.projectName ?? '',
          'branchName': name,
        }),
      );
      print('[Perf][Frontend][SwitchBranch][Request] ${swStep.elapsedMilliseconds}ms');
      swStep.reset();
      
      if (resp.statusCode != 200) throw Exception(resp.body);

      // Force update repo status after switch (to check diff against new branch)
      if (widget.onUpdate != null) {
        await widget.onUpdate!(forcePull: false,opIdentical: false);
      } else {
        if (widget.onRefresh != null) widget.onRefresh!();
      }
      print('[Perf][Frontend][SwitchBranch][UpdateUI] ${swStep.elapsedMilliseconds}ms');
      swStep.stop();

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
    } finally {
      widget.onLoading?.call(false);
      sw.stop();
      print('[Perf][Frontend][SwitchBranch][Total] ${sw.elapsedMilliseconds}ms');
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
    await _doSwitchBranch(Branch.encodeName(name));
  }

  void _showNodeActionDialog(CommitNode node) {
    final allBranches = widget.data.branches.map((b) => b.name).toSet();
    final targets = node.refs.where((r) => allBranches.contains(r)).toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('操作: ${node.id.substring(0, 7)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('提交信息: ${node.subject}'),
            if (targets.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('以此提交为头的分支:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                children: targets
                    .map((b) => ActionChip(
                          label: Text(b),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _doSwitchBranch(b);
                          },
                          avatar: const Icon(Icons.swap_horiz, size: 16),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
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
              _mergeToCurrent(node);
            },
            child: const Text('合并到当前分支 (Word)'),
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
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _previewVersion(CommitNode node) async {
    if (_comparing) return;

    widget.onLoading?.call(true);
    setState(() => _comparing = true);

    try {
      final resp = await http.post(
        Uri.parse('http://localhost:8080/preview'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repoPath': widget.repoPath,
          'commitId': node.id,
        }),
      );

      if (resp.statusCode != 200) {
        throw Exception('预览失败: ${resp.body}');
      }
      final bytes = resp.bodyBytes;
      if (!mounted) return;

      widget.onLoading?.call(false);

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
      widget.onLoading?.call(false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _comparing = false);
      widget.onLoading?.call(false);
    }
  }

  Future<void> _rollbackVersion(CommitNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认回退'),
        content: Text('确定要将工作区文档回退到版本 ${node.id.substring(0, 7)} 吗？\n'
            '当前未提交的更改可能会丢失。\n'
            '请确保 Word 文档的插件已经加载。'),
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

    widget.onLoading?.call(true);

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
      if (widget.onUpdate != null) {
        await widget.onUpdate!(forcePull: false,opIdentical:false);
      } else {
        if (widget.onRefresh != null) widget.onRefresh!();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回退成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      widget.onLoading?.call(false);
    }
  }

  Future<void> _resetBranch(CommitNode node) async {
    final currentBranch = widget.data.currentBranch ?? '未知分支';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('危险：重置分支'),
        content: RichText(
          text: TextSpan(
            style: const TextStyle(color: Colors.black, fontSize: 14),
            children: [
              const TextSpan(text: '确定要将当前分支 '),
              TextSpan(
                text: currentBranch,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              TextSpan(
                  text: ' 重置到版本 ${node.id.substring(0, 7)} 吗？\n\n'
                      '此操作将【永久删除】该版本之后的所有提交记录！\n'
                      '请注意：此操作仅重置Git仓库状态，【不会】修改您外部追踪的Word文档。\n'
                      '若要回退文档内容，请使用"回退到这个版本 (仅文件)"功能。'),
            ],
          ),
        ),
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

    widget.onLoading?.call(true);

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

      if (widget.onUpdate != null) {
        await widget.onUpdate!(forcePull: false,opIdentical: false);
      } else {
        if (widget.onRefresh != null) widget.onRefresh!();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分支重置成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      widget.onLoading?.call(false);
    }
  }

  Future<void> _onMergeButton() async {
    final current = widget.data.currentBranch;
    final others = widget.data.branches
        .where((b) => b.name != current)
        .map((b) => b.name)
        .toList();

    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有其他分支可合并')),
      );
      return;
    }

    String? selected = others.first;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('合并分支'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择要合并到当前分支的目标分支：'),
              const SizedBox(height: 8),
              DropdownButton<String>(
                isExpanded: true,
                value: selected,
                items: others
                    .map((b) => DropdownMenuItem(
                          value: b,
                          child: Text(b),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => selected = v),
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
              child: const Text('合并'),
            ),
          ],
        ),
      ),
    );

    if (ok == true && selected != null) {
      if (widget.onMerge != null) {
        widget.onMerge!(selected!);
      }
    }
  }

  Future<void> _mergeToCurrent(CommitNode node) async {
    final allBranches = widget.data.branches.map((b) => b.name).toSet();
    final targets = node.refs.where((r) => allBranches.contains(r)).toList();
    String? targetBranch;
    if (targets.isNotEmpty) {
      targetBranch = targets.first;
    } else {
      targetBranch = node.id;
    }
    if (widget.onMerge != null) {
      await widget.onMerge!(targetBranch);
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
                      _showNodeActionDialog(hit);
                    } else {
                      final edgeHit = _hitEdge(d.localPosition, widget.data);
                      if (edgeHit != null && edgeHit.isMerge) return;
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
                                        child: Text(Branch.decodeName(b)),
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
                    child: AnimatedBuilder(
                      animation: _graphFlashCtrl,
                      builder: (context, child) {
                        return CustomPaint(
                          painter: GraphPainter(
                            widget.data,
                            _branchColors!,
                            _hoverEdgeKey(),
                            _laneWidth,
                            _rowHeight,
                            working: widget.working,
                            selectedNodes: _selectedNodes,
                            identicalCommitIds: widget.identicalCommitIds,
                            customRowMapping: widget.customRowMapping,
                            totalRows: widget.totalRows,
                            primaryBranchName: widget.primaryBranchName,
                            flashValue: _graphFlashCtrl.value,
                          ),
                          size: _canvasSize!,
                        );
                      },
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
          child: widget.readOnly
              ? const SizedBox.shrink()
              : Transform.scale(
                  scale: widget.uiScale,
                  alignment: Alignment.topLeft,
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
                            '当前分支: ${Branch.decodeName(widget.data.currentBranch ?? "Unknown")}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                                ElevatedButton.icon(
                                  onPressed: _onCommit,
                                  icon: const Icon(Icons.upload),
                                  label: const Text('提交更改'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
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
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _onMergeButton,
                                icon: const Icon(Icons.call_merge),
                                label: const Text('合并分支'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: widget.onFindIdentical,
                                icon: const Icon(Icons.find_in_page),
                                label: const Text('查找与当前本地文档相同的版本'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        Positioned(
          right: 16,
          top: 80,
          child: Transform.scale(
            scale: widget.uiScale,
            alignment: Alignment.topRight,
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
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            if (widget.projectName == null ||
                                widget.repoPath.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请先打开一个项目')),
                              );
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => BackupPage(
                                        projectName: widget.projectName!,
                                        repoPath: widget.repoPath,
                                        token: widget.token ??
                                            'No token there bro.',
                                      )),
                            );
                          },
                          icon: const Icon(Icons.history),
                          label: const Text('历史备份'),
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
                                Branch.decodeName(b.name),
                                style: TextStyle(
                                  fontWeight:
                                      b.name == widget.data.currentBranch
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
                    if (_hoverEdge!.isMerge)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF9E9E9E).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF9E9E9E),
                          ),
                        ),
                        child: const Text(
                          '合并边',
                          style: TextStyle(fontSize: 12),
                        ),
                      )
                    else
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

  Map<String, int> _laneOfByBranches(GraphData data) {
    final laneOf = <String, int>{};
    final byId = {for (final c in data.commits) c.id: c};

    // 1. 对分支进行排序 (master 优先，然后按 Head 提交的新旧排序)
    final orderedBranches = List<Branch>.from(data.branches);

    orderedBranches.sort((a, b) {
      int pa = a.name == 'master' ? 0 : 1;
      int pb = b.name == 'master' ? 0 : 1;
      if (pa != pb) return pa - pb;

      return a.name.compareTo(b.name);
    });

    int nextFreeLane = 0;

    // 2. 按优先级为每个分支分配 Lane
    for (final b in orderedBranches) {
      var curId = b.head;
      if (laneOf.containsKey(curId)) continue;

      final currentBranchLane = nextFreeLane++;

      while (true) {
        if (laneOf.containsKey(curId)) break;
        laneOf[curId] = currentBranchLane;

        final node = byId[curId];
        if (node == null || node.parents.isEmpty) break;

        curId = node.parents.first;
      }
    }

    // 3. 查漏补缺
    for (final c in data.commits) {
      if (!laneOf.containsKey(c.id)) {
        laneOf[c.id] = nextFreeLane++;
      }

      final currentLane = laneOf[c.id]!;

      for (int i = 0; i < c.parents.length; i++) {
        final pId = c.parents[i];
        if (laneOf.containsKey(pId)) continue;

        if (i == 0) {
          laneOf[pId] = currentLane;
        } else {
          laneOf[pId] = nextFreeLane++;
        }
      }
    }
    return laneOf;
  }

  EdgeInfo? _hitEdge(Offset sceneP, GraphData data) {
    final laneWidth = _laneWidth;
    final rowHeight = _rowHeight;
    final commits = data.commits;
    final laneOf = _laneOfByBranches(data);
    final rowOf = <String, int>{};
    final byId = <String, CommitNode>{};
    for (var i = 0; i < commits.length; i++) {
      rowOf[commits[i].id] = i;
      byId[commits[i].id] = commits[i];
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

      final childNode = byId[child];
      // 1. 同步 paint 中的过滤逻辑：确保 parent 确实是 child 的父节点
      // 这可以防止“幽灵边”被检测到（即 chains 中存在但 paint 中被过滤的边）
      if (childNode != null && !childNode.parents.contains(parent)) {
        continue;
      }

      bool isMergeEdge = false;
      // 如果 child 有多个父节点，且当前 edge 的 parent 不是第一个父节点，则视为 merge 边
      if (childNode != null && childNode.parents.length > 1) {
        if (childNode.parents[0] != parent) {
          isMergeEdge = true;
        }
      }

      // 如果我们处于 Merge 边的“对角线”区域，需要使用更宽松的判定，或者更精确的距离算法
      // 简单的 _distPointToSegment 已经足够精确，但问题可能出在判定条件上。
      // Merge 边 (diagonal) 和 Split 边 (L-shape) 的判定逻辑需要分开。

      double d = double.infinity;
      if (laneC == laneP) {
        // 同泳道，直线
        d = _distPointToSegment(sceneP, Offset(x, y), Offset(px, py));
      } else {
        if (isMergeEdge) {
          // Chains 里的 Merge 边（斜线）。
          // 在 paint 中我们通过 continue 跳过了这些边的绘制（隐藏了蓝色线）。
          // 因此，在 _hitEdge 中，我们也必须跳过它们，否则会检测到不可见的边。
          // 从而导致 Tooltip 显示了错误的信息（即 Chains 里的分支信息）。
          // 我们希望 Tooltip 信息由下方“2. Check explicit merge edges”逻辑来提供（显示“合并边”）。
          continue;
        } else {
          // Split 边：L 型 (Parent -> Horizontal -> Vertical -> Child)
          // 注意：绘制时是 path.moveTo(px, py); path.lineTo(x, py); path.lineTo(x, y);
          // 所以是两段线段：(px, py)->(x, py) 和 (x, py)->(x, y)
          final d1 = _distPointToSegment(sceneP, Offset(px, py), Offset(x, py));
          final d2 = _distPointToSegment(sceneP, Offset(x, py), Offset(x, y));
          d = d1 < d2 ? d1 : d2;
        }
      }

      if (d < best) {
        best = d;
        bestInfo = EdgeInfo(
          child: child,
          parent: parent,
          branches: entry.value,
          isMerge: false,
        );
      }
    }
    if (bestInfo != null && best <= 8.0) return bestInfo;

    // 2. & 3. Explicit merge edges check and First Parent fix check removed

    if (bestInfo != null && best <= 8.0) return bestInfo;

    // 4. Check custom edges
    for (final edge in data.customEdges) {
      if (edge.length < 2) continue;
      final child = edge[0];
      final parent = edge[1];
      final rowC = rowOf[child];
      final laneC = laneOf[child];
      final rowP = rowOf[parent];
      final laneP = laneOf[parent];
      if (rowC == null || laneC == null || rowP == null || laneP == null)
        continue;

      final x = laneC * laneWidth + laneWidth / 2;
      final y = rowC * rowHeight + rowHeight / 2;
      final px = laneP * laneWidth + laneWidth / 2;
      final py = rowP * rowHeight + rowHeight / 2;

      final d = _distPointToSegment(sceneP, Offset(x, y), Offset(px, py));
      if (d < best) {
        best = d;
        bestInfo = EdgeInfo(
          child: child,
          parent: parent,
          branches: ['MergeEdge'], // Force custom edge to show as MergeEdge
          isMerge: true,
        );
      }
    }

    if (bestInfo != null && best <= 8.0) return bestInfo;
    return null;
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
}
