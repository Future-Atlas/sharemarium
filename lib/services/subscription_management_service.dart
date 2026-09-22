import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/dev_logger.dart';

enum SubscriptionCancellationMode {
  immediate,
  periodEnd,
  alreadyScheduled,
  alreadyCanceled,
}

class SubscriptionCancellationResult {
  const SubscriptionCancellationResult({
    required this.mode,
    required this.effectiveAt,
  });

  final SubscriptionCancellationMode mode;
  final DateTime? effectiveAt;
}

class SubscriptionCancellationException implements Exception {
  const SubscriptionCancellationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionManagementService {
  SubscriptionManagementService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<SubscriptionCancellationResult>
  cancelCurrentSubscription() async {
    if (_client.auth.currentUser == null) {
      throw const SubscriptionCancellationException(
        '解約するにはログインしてください。',
      );
    }

    try {
      final response = await _client.functions.invoke(
        'billing-cancel-subscription',
        body: const <String, dynamic>{},
      );
      if (response.status < 200 || response.status >= 300) {
        throw const SubscriptionCancellationException(
          '解約手続きを完了できませんでした。時間をおいて再度お試しください。',
        );
      }

      final data = response.data;
      if (data is! Map) {
        throw const SubscriptionCancellationException(
          '解約状態を確認できませんでした。',
        );
      }

      final mode = switch (data['mode']?.toString()) {
        'immediate' => SubscriptionCancellationMode.immediate,
        'period_end' => SubscriptionCancellationMode.periodEnd,
        'already_scheduled' => SubscriptionCancellationMode.alreadyScheduled,
        'already_canceled' => SubscriptionCancellationMode.alreadyCanceled,
        _ => null,
      };
      if (mode == null) {
        throw const SubscriptionCancellationException(
          '解約状態を確認できませんでした。',
        );
      }

      final effectiveRaw = data['effectiveAt']?.toString().trim() ?? '';
      return SubscriptionCancellationResult(
        mode: mode,
        effectiveAt: effectiveRaw.isEmpty
            ? null
            : DateTime.tryParse(effectiveRaw),
      );
    } on SubscriptionCancellationException {
      rethrow;
    } on FunctionException catch (error) {
      debugLog('Billing cancellation function error: $error');
      throw const SubscriptionCancellationException(
        '解約手続きを完了できませんでした。時間をおいて再度お試しください。',
      );
    } catch (error) {
      debugLog('Billing cancellation error: $error');
      throw const SubscriptionCancellationException(
        '解約手続きを完了できませんでした。時間をおいて再度お試しください。',
      );
    }
  }
}
