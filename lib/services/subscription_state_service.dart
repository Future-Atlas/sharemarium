import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/subscription_state.dart';
import '../utils/dev_logger.dart';

class SubscriptionStateService {
  SubscriptionStateService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<SubscriptionState?> fetchCurrentState() async {
    if (_client.auth.currentUser == null) return null;
    try {
      final response = await _client.rpc('current_user_subscription_state');
      final rows = response is List<dynamic> ? response : <dynamic>[response];
      final row = rows.whereType<Map<String, dynamic>>().firstOrNull;
      return row == null ? null : SubscriptionState.fromJson(row);
    } catch (error) {
      debugLog('Error fetching current subscription state: $error');
      return null;
    }
  }
}
