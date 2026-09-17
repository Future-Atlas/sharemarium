import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/models/subscription_state.dart';

void main() {
  test('parses active Premium lifecycle state', () {
    final state = SubscriptionState.fromJson({
      'effective_plan': 'premium',
      'scheduled_plan': 'plus',
      'scheduled_plan_effective_at': '2030-02-01T00:00:00Z',
      'current_period_end': '2030-02-01T00:00:00Z',
      'payment_grace_until': null,
      'trial_ends_at': null,
      'trial_used': true,
      'cancel_at_period_end': false,
      'billing_status': 'active',
    });

    expect(state.effectivePlan, SubscriptionPlanTier.premium);
    expect(state.scheduledPlan, SubscriptionPlanTier.plus);
    expect(state.hasScheduledPlan, isTrue);
    expect(state.isPaid, isTrue);
    expect(state.isTrialing, isFalse);
    expect(state.trialUsed, isTrue);
    expect(state.billingStatusLabel, '契約中');
  });

  test('defaults unknown or missing plan values safely to Free', () {
    final state = SubscriptionState.fromJson({
      'effective_plan': 'unexpected',
      'scheduled_plan': null,
      'trial_used': false,
      'cancel_at_period_end': false,
      'billing_status': null,
    });

    expect(state.effectivePlan, SubscriptionPlanTier.free);
    expect(state.scheduledPlan, isNull);
    expect(state.isPaid, isFalse);
    expect(state.billingStatusLabel, 'Free');
    expect(state.trialUsed, isFalse);
  });

  test('recognizes payment grace state', () {
    final state = SubscriptionState.fromJson({
      'effective_plan': 'plus',
      'payment_grace_until': '2030-03-08T00:00:00Z',
      'trial_used': true,
      'cancel_at_period_end': false,
      'billing_status': 'past_due',
    });

    expect(state.isPastDue, isTrue);
    expect(state.billingStatusLabel, 'お支払い確認中');
    expect(state.paymentGraceUntil, DateTime.utc(2030, 3, 8));
  });
}
