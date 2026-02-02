import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

class LogEntry {
  final DateTime time;
  final String source; // 'Server', 'COM', 'Warden'
  final String content;
  final bool isError;

  LogEntry(this.source, this.content, {this.isError = false}) : time = DateTime.now();

  @override
  String toString() {
    return '[${time.toIso8601String()}] [$source] ${isError ? "[ERR] " : ""}$content';
  }
}

class BackendManager {
  static final BackendManager _instance = BackendManager._internal();
  factory BackendManager() => _instance;
  BackendManager._internal();

  final List<LogEntry> _logs = [];
  final StreamController<LogEntry> _logStreamController = StreamController.broadcast();

  Stream<LogEntry> get logStream => _logStreamController.stream;
  List<LogEntry> get logs => List.unmodifiable(_logs);

  Process? _serverProcess;
  Process? _comProcess;
  
  bool _isServerRunning = false;
  bool _isComRunning = false;

  bool get isServerRunning => _isServerRunning;
  bool get isComRunning => _isComRunning;

  void log(String source, String content, {bool isError = false}) {
    final entry = LogEntry(source, content.trim(), isError: isError);
    _logs.add(entry);
    _logStreamController.add(entry);
    if (kDebugMode) {
      print(entry);
    }
  }

  Future<void> startProcess(String name, String executablePath, List<String> args) async {
    try {
      log(name, 'Starting $executablePath with args: $args');
      
      // 使用正常模式启动以捕获输出
      final process = await Process.start(
        executablePath, 
        args,
        mode: ProcessStartMode.normal, 
        runInShell: false, 
      );

      if (name == 'Server') {
        _serverProcess = process;
        _isServerRunning = true;
      } else if (name == 'COM') {
        _comProcess = process;
        _isComRunning = true;
      }

      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        log(name, line);
      });

      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        log(name, line, isError: true);
      });

      process.exitCode.then((code) {
        log(name, 'Process exited with code $code');
        if (name == 'Server') {
          _isServerRunning = false;
          _serverProcess = null;
        } else if (name == 'COM') {
          _isComRunning = false;
          _comProcess = null;
        }
      });

    } catch (e) {
      log(name, 'Failed to start: $e', isError: true);
      rethrow;
    }
  }

  Future<void> stopAll() async {
    if (_serverProcess != null) {
      log('System', 'Stopping Server...');
      _serverProcess!.kill();
      _serverProcess = null;
    }
    if (_comProcess != null) {
      log('System', 'Stopping COM...');
      _comProcess!.kill();
      _comProcess = null;
    }
  }

  Future<void> exportLogs() async {
    try {
      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: '导出日志',
        fileName: 'gitbin_logs_${DateTime.now().millisecondsSinceEpoch}.txt',
      );

      if (outputFile != null) {
        final sb = StringBuffer();
        for (final log in _logs) {
          sb.writeln(log.toString());
        }
        await File(outputFile).writeAsString(sb.toString());
        log('System', 'Logs exported to $outputFile');
      }
    } catch (e) {
      log('System', 'Failed to export logs: $e', isError: true);
    }
  }
}
