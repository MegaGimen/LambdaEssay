import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

/// AI 文档对比服务
/// 
/// 通过调用 Python LambdaLinker API 实现智能文档对比
/// 自动使用缓存机制（本地 + 远程），提升性能
class AIDiffService {
  static const String _pythonApiUrl = 'https://llinker.com/LambdaEssay_agent';
  static const Duration _timeout = Duration(seconds: 120);
  
  /// 获取本地缓存目录
  static Directory _getLocalCacheDir() {
    String cachePath;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        cachePath = p.join(appData, 'gitdocx_ai_cache');
      } else {
        cachePath = p.join(Directory.systemTemp.path, 'gitdocx_ai_cache');
      }
    } else {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      cachePath = p.join(home, '.gitdocx_ai_cache');
    }
    final dir = Directory(cachePath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 计算文件哈希
  static Future<String> _computeFileHash(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return '';
    final bytes = await file.readAsBytes();
    return sha1.convert(bytes).toString();
  }

  /// 生成缓存键
  static Future<String> _generateCacheKey(
    String fileAPath,
    String fileBPath,
    String docType,
    String? commitA,
    String? commitB,
  ) async {
    final keyA = commitA ?? await _computeFileHash(fileAPath);
    final keyB = commitB ?? await _computeFileHash(fileBPath);
    return '${keyA}_vs_${keyB}_$docType';
  }
  
  /// 检查 Python API 服务是否可用
  static Future<bool> isAvailable() async {
    try {
      final url = Uri.parse('$_pythonApiUrl/health');
      final response = await http.get(url).timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      print('[AIDiff] Health check failed for $_pythonApiUrl: $e');
      return false;
    }
  }

  /// 检查本地缓存（无需文件路径，仅需 commit ID）
  static Future<Map<String, dynamic>?> checkLocalCache(
    String commitA,
    String commitB,
    String docType,
  ) async {
    try {
      // 当提供 commit ID 时，文件路径可以是任意值
      final cacheKey = await _generateCacheKey('', '', docType, commitA, commitB);
      final cacheDir = _getLocalCacheDir();
      final localCacheFile = File(p.join(cacheDir.path, '$cacheKey.json'));
      
      if (localCacheFile.existsSync()) {
        final content = await localCacheFile.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        print('[AIDiff] ✅ 本地缓存命中 (预检查): $cacheKey');
        return data;
      }
    } catch (e) {
      print('[AIDiff] 本地缓存预检查失败: $e');
    }
    return null;
  }
  
  /// 对比两个文档（自动使用缓存）
  ///
  /// [fileAPath] 文件A的绝对路径
  /// [fileBPath] 文件B的绝对路径
  /// [docType] 文档类型: word, ppt, excel
  /// [useCache] 是否使用缓存（默认: true）
  /// [useMcp] 是否使用MCP服务（默认: true）
  /// [commitA] 文件A的commit ID（可选，用于缓存键）
  /// [commitB] 文件B的commit ID（可选，用于缓存键）
  ///
  /// 返回: AI 分析结果
  static Future<Map<String, dynamic>> compareDocuments(
    String fileAPath,
    String fileBPath,
    String docType, {
    bool useCache = true,
    bool useMcp = true,
    String? commitA,
    String? commitB,
    String? authKey,
  }) async {
    // 1. 尝试读取本地缓存
    String? cacheKey;
    File? localCacheFile;
    
    if (useCache) {
      try {
        cacheKey = await _generateCacheKey(fileAPath, fileBPath, docType, commitA, commitB);
        final cacheDir = _getLocalCacheDir();
        localCacheFile = File(p.join(cacheDir.path, '$cacheKey.json'));
        
        if (localCacheFile.existsSync()) {
          final content = await localCacheFile.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          print('[AIDiff] ✅ 本地缓存命中: $cacheKey');
          return data;
        }
      } catch (e) {
        print('[AIDiff] 读取本地缓存失败: $e');
      }
    }

    final url = Uri.parse('$_pythonApiUrl/compare');

    try {
      print('[AIDiff] 开始对比: $docType (cache=$useCache, commits=$commitA vs $commitB)');
      print('[AIDiff] 使用 Base64 模式上传: $fileAPath, $fileBPath');

      final bytesA = await File(fileAPath).readAsBytes();
      final bytesB = await File(fileBPath).readAsBytes();
      final base64A = base64Encode(bytesA);
      final base64B = base64Encode(bytesB);

      final requestBody = {
        'file_a': fileAPath, // 保留路径/文件名
        'file_b': fileBPath,
        'file_a_base64': base64A,
        'file_b_base64': base64B,
        'doc_type': docType,
        'use_cache': useCache,
        'use_mcp': useMcp,
        if (commitA != null) 'commit_a': commitA,
        if (commitB != null) 'commit_b': commitB,
        if (authKey != null) 'auth_key': authKey,
      };

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(requestBody),
      ).timeout(_timeout);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        
        final cached = data['cached'] as bool? ?? false;
        if (cached) {
          print('[AIDiff] ✅ 远程缓存命中: $docType');
        } else {
          print('[AIDiff] ⏱️  AI分析完成（新结果）: $docType');
        }
        
        final result = data['result'] as Map<String, dynamic>;
        
        // 保存到本地缓存
        if (useCache && localCacheFile != null) {
          try {
            await localCacheFile.writeAsString(jsonEncode(result));
            print('[AIDiff] ✅ 结果已保存到本地缓存: ${localCacheFile.path}');
          } catch (e) {
            print('[AIDiff] 保存本地缓存失败: $e');
          }
        }
        
        return result;
      } else if (response.statusCode == 404) {
        throw Exception('文件不存在');
      } else {
        // 尝试解析错误信息，如果不是 JSON 则直接返回 body
        String errorMsg;
        try {
          final error = jsonDecode(response.body);
          errorMsg = error['detail'] ?? response.statusCode.toString();
        } catch (_) {
          errorMsg = response.body;
        }
        throw Exception('AI服务调用失败 ($errorMsg)');
      }
    } on http.ClientException catch (e) {
      print('[AIDiff] ❌ 网络错误: $e');
      throw Exception('无法连接到 AI 服务，请确保 Python API 服务已启动');
    } on SocketException catch (e) {
      print('[AIDiff] ❌ 连接失败: $e');
      throw Exception('无法连接到 AI 服务 (端口 8765)');
    } catch (e) {
      print('[AIDiff] ❌ AI服务错误: $e');
      rethrow;
    }
  }
  
  /// 获取缓存统计信息
  static Future<Map<String, dynamic>> getCacheStats() async {
    final url = Uri.parse('$_pythonApiUrl/cache/stats');
    
    try {
      final response = await http.get(url).timeout(_timeout);
      
      if (response.statusCode == 200) {
        return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('获取缓存统计失败: ${response.statusCode}');
    } catch (e) {
      print('[AIDiff] 获取缓存统计失败: $e');
      rethrow;
    }
  }
  
  /// 检查缓存是否存在
  static Future<bool> hasCached(
    String fileAPath,
    String fileBPath,
    String docType,
  ) async {
    final url = Uri.parse('$_pythonApiUrl/cache/check');
    
    try {
      final response = await http.get(
        url.replace(queryParameters: {
          'file_a': fileAPath,
          'file_b': fileBPath,
          'doc_type': docType,
        }),
      ).timeout(_timeout);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['exists'] as bool? ?? false;
      }
      return false;
    } catch (e) {
      print('[AIDiff] 检查缓存失败: $e');
      return false;
    }
  }
  
  /// 清空所有缓存
  static Future<int> clearCache() async {
    final url = Uri.parse('$_pythonApiUrl/cache');
    
    try {
      final response = await http.delete(url).timeout(_timeout);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final deleted = data['deleted'] as int? ?? 0;
        print('[AIDiff] ✅ AI缓存已清空: $deleted 个条目');
        return deleted;
      }
      throw Exception('清空缓存失败: ${response.statusCode}');
    } catch (e) {
      print('[AIDiff] 清空缓存失败: $e');
      rethrow;
    }
  }
  
  /// 格式化 AI 分析结果为文本摘要
  static String formatSummary(Map<String, dynamic> result) {
    final summary = result['summary'] as List?;
    final analysis = result['analysis'] as String?;
    
    final buffer = StringBuffer();
    
    // 添加摘要要点
    if (summary != null && summary.isNotEmpty) {
      buffer.writeln('📋 差异摘要:');
      for (var i = 0; i < summary.length; i++) {
        buffer.writeln('${i + 1}. ${summary[i]}');
      }
      buffer.writeln();
    }
    
    // 添加详细分析
    if (analysis != null && analysis.isNotEmpty) {
      buffer.writeln('🔍 详细分析:');
      buffer.writeln(analysis);
    }
    
    return buffer.toString();
  }
}
