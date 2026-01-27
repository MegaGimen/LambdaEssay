import 'dart:io';
import 'dart:convert'; // 导入 dart:convert 库
import 'package:docx_to_text/docx_to_text.dart';
import 'package:http/http.dart' as http;

// 修正返回类型为 Future<String>
Future<String> runWorkflow(String before, String after) async {
  final url = "https://llinker.com/LambdaEssayWorkFlow/summarize_diff";
  final headers = {
    'Content-Type': 'application/json; charset=UTF-8',
  };
  final body = {"after": after, "before": before};
  try {
    // 发送 POST 请求
    final response = await http.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode(body), // 将 Map 转换为 JSON 字符串
    );

    // 检查响应状态
    if (response.statusCode >= 200 && response.statusCode < 300) {
      // 确保返回的是字符串
      return jsonDecode(response.body)['output']?.toString() ?? '';
    } else {
      print('请求失败，状态码: ${response.statusCode}');
      print('错误信息: ${response.body}');
      return '';
    }
  } catch (e) {
    print('发生异常: $e');
    return '';
  }
}

Future<String> docx2txt(String filePath) async {
  final file = File(filePath);
  final bytes = await file.readAsBytes();
  final text = docxToText(bytes);
  return text;
}

Future<String> summarizeDiff(String beforePath, String afterPath) async {
  String beforeTxt = await docx2txt(beforePath);
  String afterTxt = await docx2txt(afterPath);
  String diff = await runWorkflow(beforeTxt, afterTxt);
  return diff;
}

Future<void> main() async {
  String beforePath = 'lib/1.docx';
  String afterPath = 'lib/2.docx';
  String result = await summarizeDiff(beforePath, afterPath);
  print(result);
}
