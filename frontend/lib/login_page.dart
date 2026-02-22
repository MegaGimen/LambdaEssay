import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart'; // To navigate to GraphPage

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  final TextEditingController userCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController verifyCodeCtrl = TextEditingController();
  
  bool _isRegisterMode = false;
  bool loading = false;
  String? error;
  late TabController _tabController;

  static const String baseUrl = 'http://localhost:8080';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _isRegisterMode = _tabController.index == 1;
        error = null;
      });
    });
    _checkLogin();
  }

  @override
  void dispose() {
    userCtrl.dispose();
    passCtrl.dispose();
    emailCtrl.dispose();
    verifyCodeCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _checkLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('git_username');
    final password = prefs.getString('git_password');

    if (username != null && password != null) {
      setState(() => loading = true);
      try {
        // Attempt to login/refresh token
        final resp = await http.post(
          Uri.parse('$baseUrl/create_user'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
          }),
        );
        
        if (resp.statusCode == 200) {
           final body = jsonDecode(resp.body);
           if (body['tokens'] != null) {
             // Success, navigate to main page
             if (mounted) {
               Navigator.of(context).pushReplacement(
                 MaterialPageRoute(builder: (_) => const GraphPage()),
               );
             }
             return;
           }
        }
      } catch (e) {
        // Ignore error, stay on login page
      } finally {
        if (mounted) setState(() => loading = false);
      }
    }
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
      await http.post(
        Uri.parse('$baseUrl/request_code'), 
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email})
      );
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
      final regResp = await http.post(
        Uri.parse('$baseUrl/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'username': username,
          'password': password,
          'verification_code': code,
        }),
      );

      if (regResp.statusCode != 200) {
        throw Exception(regResp.body);
      }

      // 2. Login (Create Gitea User & Get Token)
      await _performLogin(username, password);

    } catch (e) {
      setState(() => error = '注册失败: $e');
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
      await _performLogin(u, p);
    } catch (e) {
      setState(() {
        error = '登录失败: $e';
        loading = false;
      });
    }
  }

  Future<void> _performLogin(String username, String password) async {
      // First try /login
      final resp = await http.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      );

      Map<String, dynamic> body;
      if (resp.statusCode == 200) {
        body = jsonDecode(resp.body);
      } else {
        // Try create_user if login fails (legacy logic from main.dart)
         final resp2 = await http.post(
          Uri.parse('$baseUrl/create_user'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
          }),
        );
        if (resp2.statusCode != 200) {
          throw Exception(resp2.body);
        }
        body = jsonDecode(resp2.body);
      }

      // Save credentials
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('git_username', body['username'] ?? username);
      await prefs.setString('git_password', password);

      if (mounted) {
         Navigator.of(context).pushReplacement(
           MaterialPageRoute(builder: (_) => const GraphPage()),
         );
      }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5FF), // Light purple/blue bg
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Close button (optional, but in Figure 1)
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                  onPressed: () {}, // What to do? Exit app?
                ),
              ),
              const Text(
                'LambdaEssay',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF6200EE),
                ),
              ),
              const SizedBox(height: 24),
              
              // Tabs
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: const Color(0xFF8E44AD), // Purple
                    borderRadius: BorderRadius.circular(8),
                  ),
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.grey[600],
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(text: '登录'),
                    Tab(text: '注册'),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              if (loading)
                const CircularProgressIndicator()
              else if (_isRegisterMode)
                _buildRegisterForm()
              else
                _buildLoginForm(),

              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    return Column(
      children: [
        TextField(
          controller: userCtrl,
          decoration: InputDecoration(
            hintText: '邮箱/用户名',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: passCtrl,
          obscureText: true,
          decoration: InputDecoration(
            hintText: '密码',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
             enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Checkbox(value: false, onChanged: (v) {}), // Logic not implemented for remember me check (it auto saves)
                const Text('记住我'),
              ],
            ),
            TextButton(
              onPressed: () {},
              child: const Text('忘记密码?', style: TextStyle(color: Color(0xFF8E44AD))),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _doLogin,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8E44AD),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('登录'),
          ),
        ),
      ],
    );
  }

  Widget _buildRegisterForm() {
    return Column(
      children: [
        TextField(
          controller: emailCtrl,
          decoration: InputDecoration(
            hintText: '邮箱',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: verifyCodeCtrl,
                decoration: InputDecoration(
                  hintText: '验证码',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _sendCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[200],
                foregroundColor: Colors.black,
              ),
              child: const Text('发送验证码'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: userCtrl,
          decoration: InputDecoration(
            hintText: '用户名',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: passCtrl,
          obscureText: true,
          decoration: InputDecoration(
            hintText: '密码',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _doRegister,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8E44AD),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('注册'),
          ),
        ),
      ],
    );
  }
}
