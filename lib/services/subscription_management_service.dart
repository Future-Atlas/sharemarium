import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/subscription_state.dart';
import '../utils/dev_logger.dart';
import 'subscription_checkout_service.dart';

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

class SubscriptionPlanChangeResult {
  const SubscriptionPlanChangeResult({
    required this.scheduledPlan,
    required this.effectiveAt,
  });

  final SubscriptionPlanTier scheduledPlan;
  final DateTime effectiveAt;
}

class SubscriptionPlanChangeException implements Exception {
  const SubscriptionPlanChangeException(this.message);

  final String message;

  @override
  String toString() => message;
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

  static Future<SubscriptionPlanChangeResult> schedulePlanChange({
    required SubscriptionPlanTier targetPlan,
  }) async {
    if (targetPlan == SubscriptionPlanTier.free) {
      throw const SubscriptionPlanChangeException(
        'Freeへの移行は解約手続きを利用してください。',
      );
    }
    if (_client.auth.currentUser == null) {
      throw const SubscriptionPlanChangeException(
        'プランを変更するにはログインしてください。',
      );
    }

    try {
      final response = await _client.functions.invoke(
        'billing-change-plan',
        body: {
          'plan': targetPlan.databaseValue,
          'requestId': createCheckoutRequestId(),
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw const SubscriptionPlanChangeException(
          'プラン変更を予約できませんでした。契約状態を確認して再度お試しください。',
        );
      }

      final data = response.data;
      if (data is! Map) {
        throw const SubscriptionPlanChangeException(
          'プラン変更の予約状態を確認できませんでした。',
        );
      }
      final scheduledPlan = SubscriptionPlanTierLabel.fromDatabase(
        data['scheduledPlan'],
      );
      final effectiveAt = DateTime.tryParse(
        data['effectiveAt']?.toString() ?? '',
      );
      if (scheduledPlan == SubscriptionPlanTier.free ||
          scheduledPlan != targetPlan ||
          effectiveAt == null) {
        throw const SubscriptionPlanChangeException(
          'プラン変更の予約状態を確認できませんでした。',
        );
      }

      return SubscriptionPlanChangeResult(
        scheduledPlan: scheduledPlan,
        effectiveAt: effectiveAt,
      );
    } on SubscriptionPlanChangeException {
      rethrow;
    } on FunctionException catch (error) {
      debugLog('Billing plan change function error: $error');
      throw const SubscriptionPlanChangeException(
        'プラン変更を予約できませんでした。契約状態を確認して再度お試しください。',
      );
    } catch (error) {
      debugLog('Billing plan change error: $error');
      throw const SubscriptionPlanChangeException(
        'プラン変更を予約できませんでした。契約状態を確認して再度お試しください。',
      );
    }
  }

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
