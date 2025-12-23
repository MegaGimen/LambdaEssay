// This file is for hosting web page built by Flutter to enable word plugin to use webview to show it
// You know, no one wants to rewrite the whole project just for a capitalist(Microsoft) shit.

import 'dart:io';
import 'dart:convert';

void main(List<String> arguments) {
  // 获取文件夹路径参数，如果没有则使用当前目录
  String directoryPath = arguments.isNotEmpty ? arguments[0] : '.';
  Directory servingDirectory = Directory(directoryPath);
  
  // 检查目录是否存在
  if (!servingDirectory.existsSync()) {
    print('错误: 目录 "$directoryPath" 不存在');
    exit(1);
  }
  
  int port = 3891;
  
  print('在端口 $port 上启动Dart HTTP服务器');
  print('服务目录: ${servingDirectory.absolute.path}');
  print('访问地址: http://localhost:$port');
  print('按 Ctrl+C 停止服务器\n');
  
  // 创建HTTP服务器
  HttpServer.bind(InternetAddress.loopbackIPv4, port).then((HttpServer server) {
    print('服务器已启动，正在监听 http://localhost:$port/');
    
    server.listen((HttpRequest request) {
      _handleRequest(request, servingDirectory);
    });
  }).catchError((e) {
    print('启动服务器失败: $e');
    if (e is SocketException && e.osError?.errorCode == 10048) {
      print('端口 $port 已被占用，请尝试其他端口');
    }
  });
}

void _handleRequest(HttpRequest request, Directory servingDirectory) {
  try {
    String requestPath = request.uri.path;
    
    // 处理根路径，重定向到index.html
    if (requestPath == '/') {
      requestPath = '/index.html';
    }
    
    // 构建文件路径
    String filePath = '${servingDirectory.path}${requestPath.replaceAll('..', '')}';
    File file = File(filePath);
    
    if (file.existsSync()) {
      // 设置正确的Content-Type
      String contentType = _getContentType(filePath);
      
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.add(file.readAsBytesSync());
      
      // 记录访问日志（可选）
      print('${DateTime.now().toString().substring(11, 19)} - ${request.uri.path} - 200');
    } else {
      // 文件不存在，返回404
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('文件未找到: $requestPath');
      print('${DateTime.now().toString().substring(11, 19)} - ${request.uri.path} - 404');
    }
    
    request.response.close();
  } catch (e) {
    print('处理请求时出错: $e');
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.write('服务器内部错误');
    request.response.close();
  }
}

String _getContentType(String filePath) {
  String extension = filePath.split('.').last.toLowerCase();
  
  switch (extension) {
    case 'html': return 'text/html; charset=utf-8';
    case 'css': return 'text/css; charset=utf-8';
    case 'js': return 'application/javascript';
    case 'json': return 'application/json';
    case 'png': return 'image/png';
    case 'jpg':
    case 'jpeg': return 'image/jpeg';
    case 'gif': return 'image/gif';
    case 'svg': return 'image/svg+xml';
    case 'ico': return 'image/x-icon';
    case 'txt': return 'text/plain; charset=utf-8';
    case 'xml': return 'application/xml';
    default: return 'application/octet-stream';
  }
}