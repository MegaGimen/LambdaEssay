import 'dart:async';

class LogService {
  static final List<String> _logs = [];
  static final StreamController<List<String>> _controller = StreamController<List<String>>.broadcast();

  static void log(String message) {
    final timestamp = DateTime.now().toString().split('.').first;
    final logMessage = '[$timestamp] $message';
    _logs.add(logMessage);
    if (_logs.length > 1000) {
      _logs.removeAt(0);
    }
    _controller.add(List.unmodifiable(_logs));
    print(logMessage);
  }

  static Stream<List<String>> get logsStream => _controller.stream;
  static List<String> get currentLogs => List.unmodifiable(_logs);

  static void clear() {
    _logs.clear();
    _controller.add([]);
  }
}
