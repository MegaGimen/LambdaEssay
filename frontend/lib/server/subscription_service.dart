import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

class QuotaData {
  int? ai;
  int? eth;
  double? storage;
  int? planAi;
  int? planEth;
  double? planStorage;
  int? freeAi;
  int? freeEth;
  double? freeStorage;

  QuotaData({
    this.ai, this.eth, this.storage,
    this.planAi, this.planEth, this.planStorage,
    this.freeAi, this.freeEth, this.freeStorage,
  });

  factory QuotaData.fromJson(Map<String, dynamic> json) {
    return QuotaData(
      ai: json['ai']?['default'],
      eth: json['eth'],
      storage: (json['storage'] is int) ? (json['storage'] as int).toDouble() : json['storage'],
      
      planAi: json['plan_ai']?['default'],
      planEth: json['plan_eth'],
      planStorage: (json['plan_storage'] is int) ? (json['plan_storage'] as int).toDouble() : json['plan_storage'],
      
      freeAi: json['free_ai']?['default'],
      freeEth: json['free_eth'],
      freeStorage: (json['free_storage'] is int) ? (json['free_storage'] as int).toDouble() : json['free_storage'],
    );
  }
}

class FullSubscriptionInfo {
  final int subscriptionLevel;
  final DateTime? expireAt;
  final QuotaData quotas;
  
  FullSubscriptionInfo({
    required this.subscriptionLevel,
    this.expireAt,
    required this.quotas,
  });
}

class SubscriptionService {
  static Future<FullSubscriptionInfo?> checkSubscription(String userid) async {
    try {
       final url = 'https://llinker.com/register/api/subscription/query?userid=$userid';
       // print('Debug: [Check Subscription] Requesting: $url');
       final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));

       if (response.statusCode == 200) {
         final resp = jsonDecode(response.body);
         DateTime? expireAt;
         if (resp['expire_at'] != null) {
           try {
             expireAt = HttpDate.parse(resp['expire_at']);
           } catch (_) {
             expireAt = DateTime.parse(resp['expire_at']);
           }
         }
         
         return FullSubscriptionInfo(
           subscriptionLevel: resp['subscription'] as int? ?? 0,
           expireAt: expireAt,
           quotas: QuotaData.fromJson(resp['quotas'] ?? {}),
         );
       }
    } catch (e) {
      print('Check subscription failed: $e');
    }
    return null;
  }

  static Future<Map<int, Map<String, dynamic>>> fetchPlans() async {
    final Map<int, Map<String, dynamic>> planTotals = {};
    try {
      final url = 'https://llinker.com/register/api/subscription/plans';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final resp = jsonDecode(response.body);
        if (resp['plans'] != null) {
          final plans = resp['plans'] as List;
          for (var p in plans) {
             final level = p['subscription_level'] as int? ?? 0;
             if (p['quotas'] != null) {
               planTotals[level] = p['quotas'];
             }
          }
        }
      }
    } catch (e) {
      print('Fetch plans failed: $e');
    }
    return planTotals;
  }

  static Future<Response> handleSubscriptionPlans(Request req) async {
    // Forward to remote API
    try {
      final url = 'https://llinker.com/register/api/subscription/plans';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      return _cors(Response(response.statusCode, body: response.body, headers: {'Content-Type': 'application/json'}));
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }

  static Future<Response> handleSubscriptionPurchase(Request req) async {
    // Forward to remote API
    try {
      final body = await req.readAsString();
      final url = 'https://llinker.com/register/api/subscription/purchase';
      final response = await http.post(Uri.parse(url), body: body, headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 10));
      return _cors(Response(response.statusCode, body: response.body, headers: {'Content-Type': 'application/json'}));
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }

  static Future<Response> handleSubscriptionQuery(Request req) async {
    // Forward to remote API
    try {
      final userid = req.url.queryParameters['userid'];
      if (userid == null) return _cors(Response.badRequest(body: 'userid required'));
      
      final url = 'https://llinker.com/register/api/subscription/query?userid=$userid';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      return _cors(Response(response.statusCode, body: response.body, headers: {'Content-Type': 'application/json'}));
    } catch (e) {
      return _cors(Response.internalServerError(body: jsonEncode({'error': e.toString()})));
    }
  }
}

// Helper for CORS (duplicated from server.dart to keep service self-contained or need to import server.dart?)
// Since server.dart imports this file, we can't import server.dart here (circular dependency).
// We should probably move these handlers to server.dart or make _cors public in a shared file.
// For now, let's just use Shelf Response directly and assume the router wrapper handles CORS or we duplicate _cors here.
// Actually, looking at route_map.dart, it maps paths to these static methods.
// The error was "undefined_getter".
// It seems I need to import 'package:shelf/shelf.dart';

Response _cors(Response response) {
  return response.change(headers: {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS, PUT, PATCH, DELETE',
    'Access-Control-Allow-Headers': 'Origin, X-Requested-With, Content-Type, Accept',
  });
}
