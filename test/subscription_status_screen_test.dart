import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/models/subscription_state.dart';
import 'package:sharemarium/screens/subscription_status_screen.dart';
import 'package:sharemarium/services/subscription_checkout_service.dart';
import 'package:sharemarium/services/subscription_management_service.dart';

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

  testWidgets('free user can start Plus checkout with selected billing period', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.free,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: null,
      paymentGraceUntil: null,
      trialEndsAt: null,
      trialUsed: false,
      cancelAtPeriodEnd: false,
      billingStatus: 'manual',
    );
    SubscriptionPlanTier? requestedPlan;
    SubscriptionBillingPeriod? requestedPeriod;

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          startCheckout:
              ({
                required SubscriptionPlanTier plan,
                required SubscriptionBillingPeriod billingPeriod,
              }) async {
                requestedPlan = plan;
                requestedPeriod = billingPeriod;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('お支払い方法'), findsOneWidget);
    expect(find.text('月額で申し込む'), findsNWidgets(2));

    await tester.tap(find.text('年額'));
    await tester.pumpAndSettle();
    expect(find.text('年額で申し込む'), findsNWidgets(2));

    final annualCheckoutButton =
        find.widgetWithText(FilledButton, '年額で申し込む').first;
    await tester.ensureVisible(annualCheckoutButton);
    await tester.pumpAndSettle();
    await tester.tap(annualCheckoutButton);
    await tester.pumpAndSettle();

    expect(requestedPlan, SubscriptionPlanTier.plus);
    expect(requestedPeriod, SubscriptionBillingPeriod.annual);
    expect(find.textContaining('購入画面を開きました'), findsOneWidget);
  });

  testWidgets('paid user does not see new subscription checkout buttons', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.plus,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 4, 1),
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

    expect(find.text('お支払い方法'), findsNothing);
    expect(find.text('月額で申し込む'), findsNothing);
    expect(find.text('年額で申し込む'), findsNothing);
  });

  testWidgets('checkout error is surfaced without changing subscription state', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.free,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: null,
      paymentGraceUntil: null,
      trialEndsAt: null,
      trialUsed: false,
      cancelAtPeriodEnd: false,
      billingStatus: 'manual',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          startCheckout:
              ({
                required SubscriptionPlanTier plan,
                required SubscriptionBillingPeriod billingPeriod,
              }) async {
                throw const SubscriptionCheckoutException('決済設定を確認してください。');
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final monthlyCheckoutButton =
        find.widgetWithText(FilledButton, '月額で申し込む').first;
    await tester.ensureVisible(monthlyCheckoutButton);
    await tester.pumpAndSettle();
    await tester.tap(monthlyCheckoutButton);
    await tester.pumpAndSettle();

    expect(find.text('決済設定を確認してください。'), findsOneWidget);
    expect(find.text('Free'), findsWidgets);
  });

  testWidgets('paid user can schedule cancellation for the renewal date', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.plus,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 4, 1),
      paymentGraceUntil: null,
      trialEndsAt: null,
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'active',
    );
    var cancellationCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          cancelSubscription: () async {
            cancellationCalls += 1;
            return SubscriptionCancellationResult(
              mode: SubscriptionCancellationMode.periodEnd,
              effectiveAt: DateTime.utc(2030, 4, 1),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cancelButton = find.widgetWithText(
      OutlinedButton,
      '次回更新日で解約',
    );
    await tester.ensureVisible(cancelButton);
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(find.text('契約を解約しますか？'), findsOneWidget);
    expect(find.textContaining('2030年4月1日で自動更新を停止'), findsOneWidget);

    await tester.tap(find.text('解約する'));
    await tester.pumpAndSettle();

    expect(cancellationCalls, 1);
    expect(find.textContaining('2030年4月1日で自動更新を停止します'), findsOneWidget);
  });

  testWidgets('trial cancellation warns that access ends immediately', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.premium,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 4, 10),
      paymentGraceUntil: null,
      trialEndsAt: DateTime.utc(2030, 4, 10),
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'trialing',
    );
    var cancellationCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          cancelSubscription: () async {
            cancellationCalls += 1;
            return const SubscriptionCancellationResult(
              mode: SubscriptionCancellationMode.immediate,
              effectiveAt: null,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cancelButton = find.widgetWithText(
      OutlinedButton,
      '無料体験を解約',
    );
    await tester.ensureVisible(cancelButton);
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(find.text('無料体験を解約しますか？'), findsOneWidget);
    expect(find.textContaining('直ちに終了'), findsOneWidget);

    await tester.tap(find.text('解約する'));
    await tester.pumpAndSettle();

    expect(cancellationCalls, 1);
    expect(find.textContaining('Freeプランへ移行します'), findsOneWidget);
  });


  testWidgets('paid user can schedule a plan change for the renewal date', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.plus,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 5, 1),
      paymentGraceUntil: null,
      trialEndsAt: null,
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'active',
    );
    SubscriptionPlanTier? requestedPlan;

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          changePlan: (targetPlan) async {
            requestedPlan = targetPlan;
            return SubscriptionPlanChangeResult(
              scheduledPlan: targetPlan,
              effectiveAt: DateTime.utc(2030, 5, 1),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final changeButton = find.widgetWithText(
      OutlinedButton,
      '次回更新日から変更',
    );
    expect(changeButton, findsOneWidget);
    await tester.ensureVisible(changeButton);
    await tester.tap(changeButton);
    await tester.pumpAndSettle();

    expect(find.text('Sharemarium Premiumへ変更しますか？'), findsOneWidget);
    expect(find.textContaining('2030年5月1日の次回更新日から'), findsOneWidget);

    await tester.tap(find.text('変更を予約'));
    await tester.pumpAndSettle();

    expect(requestedPlan, SubscriptionPlanTier.premium);
    expect(
      find.textContaining('2030年5月1日からSharemarium Premiumへ変更します'),
      findsOneWidget,
    );
  });

  testWidgets('scheduled or past-due subscriptions cannot schedule another plan change', (
    tester,
  ) async {
    Future<void> pumpState(SubscriptionState state) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionStatusScreen(loadState: () async => state),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpState(
      SubscriptionState(
        effectivePlan: SubscriptionPlanTier.plus,
        scheduledPlan: SubscriptionPlanTier.premium,
        scheduledPlanEffectiveAt: DateTime.utc(2030, 6, 1),
        currentPeriodEnd: DateTime.utc(2030, 6, 1),
        paymentGraceUntil: null,
        trialEndsAt: null,
        trialUsed: true,
        cancelAtPeriodEnd: false,
        billingStatus: 'active',
      ),
    );
    expect(find.text('次回更新日から変更'), findsNothing);

    await pumpState(
      SubscriptionState(
        effectivePlan: SubscriptionPlanTier.plus,
        scheduledPlan: null,
        scheduledPlanEffectiveAt: null,
        currentPeriodEnd: DateTime.utc(2030, 6, 1),
        paymentGraceUntil: DateTime.utc(2030, 6, 8),
        trialEndsAt: null,
        trialUsed: true,
        cancelAtPeriodEnd: false,
        billingStatus: 'past_due',
      ),
    );
    expect(find.text('次回更新日から変更'), findsNothing);
  });

  testWidgets('trial user schedules plan change for trial end', (
    tester,
  ) async {
    final state = SubscriptionState(
      effectivePlan: SubscriptionPlanTier.premium,
      scheduledPlan: null,
      scheduledPlanEffectiveAt: null,
      currentPeriodEnd: DateTime.utc(2030, 7, 10),
      paymentGraceUntil: null,
      trialEndsAt: DateTime.utc(2030, 7, 10),
      trialUsed: true,
      cancelAtPeriodEnd: false,
      billingStatus: 'trialing',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionStatusScreen(
          loadState: () async => state,
          changePlan: (targetPlan) async => SubscriptionPlanChangeResult(
            scheduledPlan: targetPlan,
            effectiveAt: DateTime.utc(2030, 7, 10),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final changeButton = find.widgetWithText(
      OutlinedButton,
      '無料体験終了後に変更',
    );
    expect(changeButton, findsOneWidget);
    await tester.ensureVisible(changeButton);
    await tester.tap(changeButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('2030年7月10日の無料体験終了時に'), findsOneWidget);
  });

}
