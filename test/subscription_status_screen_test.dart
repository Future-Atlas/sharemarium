import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/models/subscription_state.dart';
import 'package:sharemarium/screens/subscription_status_screen.dart';

void main() {
  testWidgets('shows current Premium state and scheduled downgrade', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.premium,
      scheduledPlan: SubscriptionPlanTier.plus,
      scheduledPlanEffectiveAt: DateTime.utc(2030, 2, 1),
      currentPeriodEnd: DateTime.utc(2030, 2, 1),
      paymentGraceUntil: null,
      trialEndsAt: null,
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'active',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(loadState: () async => state),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('プラン・契約'), findsOneWidget);
    expect(find.text('Sharemarium Premium'), findsWidgets);
    expect(find.text('契約中'), findsWidgets);
    expect(find.text('2030年2月1日からSharemarium Plus'), findsOneWidget);
    expect(find.text('利用済み'), findsOneWidget);
    expect(find.text('月額 300円 ／ 年額 3,000円'), findsOneWidget);
    expect(find.text('月額 550円 ／ 年額 5,000円'), findsOneWidget);
  });

  testWidgets('shows payment grace warning and database-derived deadline', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.plus,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 3, 1),
      paymentGraceUntil: DateTime.utc(2030, 3, 8),
      trialEndsAt: null,
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'past_due',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(loadState: () async => state),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('お支払い確認中'), findsWidgets);
    expect(find.text('2030年3月8日'), findsOneWidget);
    expect(find.textContaining('猶予期限までに解消しない場合'), findsOneWidget);
  });

  testWidgets('shows retry state when lifecycle data cannot be loaded', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(loadState: () async => null),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('契約情報を取得できませんでした。'), findsOneWidget);
    expect(find.text('再読み込み'), findsOneWidget);
  });
}
