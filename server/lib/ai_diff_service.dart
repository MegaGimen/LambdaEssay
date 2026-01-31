import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// AI 文档对比服务
/// 
/// 通过调用 Python LambdaLinker API 实现智能文档对比
/// 自动使用缓存机制，提升性能
class AIDiffService {
  static const String _pythonApiUrl = 'http://127.0.0.1:8765';
  static const Duration _timeout = Duration(seconds: 120);
  
  /// 检查 Python API 服务是否可用
  static Future<bool> isAvailable() async {
    try {
      final url = Uri.parse('$_pythonApiUrl/health');
      final response = await http.get(url).timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  
  /// 对比两个文档（自动使用缓存）
  /// 
  /// [fileAPath] 文件A的绝对路径
  /// [fileBPath] 文件B的绝对路径
  /// [docType] 文档类型: word, ppt, excel
  /// [useCache] 是否使用缓存（默认: true）
  /// [useMcp] 是否使用MCP服务（默认: true）
  /// 
  /// 返回: AI 分析结果
  static Future<Map<String, dynamic>> compareDocuments(
    String fileAPath,
    String fileBPath,
    String docType, {
    bool useCache = true,
    bool useMcp = true,
  }) async {
    final url = Uri.parse('$_pythonApiUrl/compare');
    
    try {
      print('[AIDiff] 开始对比: $docType (cache=$useCache)');
      
      final requestBody = {
        'file_a': fileAPath,
        'file_b': fileBPath,
        'doc_type': docType,
        'use_cache': useCache,
        'use_mcp': useMcp,
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
          print('[AIDiff] ✅ 缓存命中: $docType');
        } else {
          print('[AIDiff] ⏱️  AI分析完成（新结果）: $docType');
        }
        
        return data['result'] as Map<String, dynamic>;
      } else if (response.statusCode == 404) {
        throw Exception('文件不存在');
      } else {
        final error = jsonDecode(response.body);
        throw Exception('AI服务调用失败: ${error['detail'] ?? response.statusCode}');
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
