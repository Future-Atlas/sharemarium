import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/subscription_state.dart';
import '../utils/dev_logger.dart';

enum SubscriptionBillingPeriod { monthly, annual }

extension SubscriptionBillingPeriodLabel on SubscriptionBillingPeriod {
  String get apiValue => switch (this) {
    SubscriptionBillingPeriod.monthly => 'monthly',
    SubscriptionBillingPeriod.annual => 'annual',
  };

  String get label => switch (this) {
    SubscriptionBillingPeriod.monthly => '月額',
    SubscriptionBillingPeriod.annual => '年額',
  };
}

class SubscriptionCheckoutException implements Exception {
  const SubscriptionCheckoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef CheckoutUrlLauncher = Future<bool> Function(Uri uri);

String createCheckoutRequestId({Random? random}) {
  final generator = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => generator.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class SubscriptionCheckoutService {
  SubscriptionCheckoutService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<void> startCheckout({
    required SubscriptionPlanTier plan,
    required SubscriptionBillingPeriod billingPeriod,
    CheckoutUrlLauncher? launch,
  }) async {
    if (plan == SubscriptionPlanTier.free) {
      throw const SubscriptionCheckoutException('Freeプランでは購入手続きを開始できません。');
    }
    if (_client.auth.currentUser == null) {
      throw const SubscriptionCheckoutException('購入手続きを開始するにはログインしてください。');
    }

    try {
      final response = await _client.functions.invoke(
        'billing-checkout',
        body: {
          'plan': plan.databaseValue,
          'billingPeriod': billingPeriod.apiValue,
          'requestId': createCheckoutRequestId(),
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw const SubscriptionCheckoutException(
          '購入手続きを開始できませんでした。時間をおいて再度お試しください。',
        );
      }

      final data = response.data;
      final checkoutUrl = data is Map
          ? data['checkoutUrl']?.toString().trim() ?? ''
          : '';
      final uri = Uri.tryParse(checkoutUrl);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw const SubscriptionCheckoutException(
          '購入画面のURLを確認できませんでした。時間をおいて再度お試しください。',
        );
      }

      final launcher = launch ?? _launchCheckoutUri;
      if (!await launcher(uri)) {
        throw const SubscriptionCheckoutException('購入画面を開けませんでした。');
      }
    } on SubscriptionCheckoutException {
      rethrow;
    } on FunctionException catch (error) {
      debugLog('Billing checkout function error: $error');
      throw const SubscriptionCheckoutException(
        '購入手続きを開始できませんでした。時間をおいて再度お試しください。',
      );
    } catch (error) {
      debugLog('Billing checkout error: $error');
      throw const SubscriptionCheckoutException(
        '購入手続きを開始できませんでした。時間をおいて再度お試しください。',
      );
    }
  }

  static Future<bool> _launchCheckoutUri(Uri uri) {
    return launchUrl(
      uri,
      mode: LaunchMode.platformDefault,
      webOnlyWindowName: '_self',
    );
  }
}
