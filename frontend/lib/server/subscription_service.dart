import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:http/http.dart' as http;

Response _cors(Response r) {
  return r.change(headers: {
    ...r.headers,
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Origin',
  });
}

class SubscriptionService {
  static const String _baseUrl = 'https://llinker.com';

  static Future<Response> handleSubscriptionPlans(Request req) async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/subscription/plans'));
      if (response.statusCode == 200) {
        return _cors(Response.ok(response.body, headers: {'Content-Type': 'application/json'}));
      } else {
         return _cors(Response(response.statusCode, body: response.body));
      }
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }

  static Future<Response> handleSubscriptionPurchase(Request req) async {
    try {
      final body = await req.readAsString();
      final response = await http.post(
        Uri.parse('$_baseUrl/api/subscription/purchase'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (response.statusCode == 200) {
        return _cors(Response.ok(response.body, headers: {'Content-Type': 'application/json'}));
      } else {
        return _cors(Response(response.statusCode, body: response.body));
      }
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }

  static Future<Response> handleSubscriptionQuery(Request req) async {
    try {
      final userId = req.url.queryParameters['userid'];
      if (userId == null) {
        return _cors(Response.badRequest(body: jsonEncode({'error': 'userid required'})));
      }
      final response = await http.get(Uri.parse('$_baseUrl/api/subscription/query?userid=$userId'));
      if (response.statusCode == 200) {
        return _cors(Response.ok(response.body, headers: {'Content-Type': 'application/json'}));
      } else {
        return _cors(Response(response.statusCode, body: response.body));
      }
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }

  static Future<int> checkSubscription(String userId) async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/subscription/query?userid=$userId'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['subscription'] as int? ?? 0;
      }
    } catch (e) {
      print('Failed to check subscription: $e');
    }
    return 0; // Default to 0 if check fails
  }
}
