enum SubscriptionPlanTier { free, plus, premium }

extension SubscriptionPlanTierLabel on SubscriptionPlanTier {
  String get databaseValue => switch (this) {
    SubscriptionPlanTier.free => 'free',
    SubscriptionPlanTier.plus => 'plus',
    SubscriptionPlanTier.premium => 'premium',
  };

  String get label => switch (this) {
    SubscriptionPlanTier.free => 'Free',
    SubscriptionPlanTier.plus => 'Sharemarium Plus',
    SubscriptionPlanTier.premium => 'Sharemarium Premium',
  };

  String get shortLabel => switch (this) {
    SubscriptionPlanTier.free => 'Free',
    SubscriptionPlanTier.plus => 'Plus',
    SubscriptionPlanTier.premium => 'Premium',
  };

  static SubscriptionPlanTier fromDatabase(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'plus' => SubscriptionPlanTier.plus,
      'premium' => SubscriptionPlanTier.premium,
      _ => SubscriptionPlanTier.free,
    };
  }
}

class SubscriptionState {
  const SubscriptionState({
    required this.effectivePlan,
    required this.scheduledPlan,
    required this.scheduledPlanEffectiveAt,
    required this.currentPeriodEnd,
    required this.paymentGraceUntil,
    required this.trialEndsAt,
    required this.trialUsed,
    required this.cancelAtPeriodEnd,
    required this.billingStatus,
  });

  final SubscriptionPlanTier effectivePlan;
  final SubscriptionPlanTier? scheduledPlan;
  final DateTime? scheduledPlanEffectiveAt;
  final DateTime? currentPeriodEnd;
  final DateTime? paymentGraceUntil;
  final DateTime? trialEndsAt;
  final bool trialUsed;
  final bool cancelAtPeriodEnd;
  final String billingStatus;

  bool get isPaid => effectivePlan != SubscriptionPlanTier.free;
  bool get isTrialing => billingStatus == 'trialing';
  bool get isPastDue => billingStatus == 'past_due';
  bool get hasScheduledPlan => scheduledPlan != null;

  String get billingStatusLabel => switch (billingStatus) {
    'trialing' => '無料体験中',
    'active' => '契約中',
    'past_due' => 'お支払い確認中',
    'canceled' => '契約終了',
    _ => effectivePlan == SubscriptionPlanTier.free ? 'Free' : '有効',
  };

  factory SubscriptionState.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(Object? value) {
      final raw = value?.toString().trim() ?? '';
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    }

    final scheduledRaw = json['scheduled_plan']?.toString().trim();
    return SubscriptionState(
      effectivePlan: SubscriptionPlanTierLabel.fromDatabase(
        json['effective_plan'],
      ),
      scheduledPlan: scheduledRaw == null || scheduledRaw.isEmpty
          ? null
          : SubscriptionPlanTierLabel.fromDatabase(scheduledRaw),
      scheduledPlanEffectiveAt: parseDate(json['scheduled_plan_effective_at']),
      currentPeriodEnd: parseDate(json['current_period_end']),
      paymentGraceUntil: parseDate(json['payment_grace_until']),
      trialEndsAt: parseDate(json['trial_ends_at']),
      trialUsed: json['trial_used'] == true,
      cancelAtPeriodEnd: json['cancel_at_period_end'] == true,
      billingStatus: json['billing_status']?.toString().trim().toLowerCase() ??
          'manual',
    );
  }
}
