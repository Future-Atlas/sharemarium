import 'package:flutter/material.dart';

import '../models/subscription_state.dart';
import '../services/subscription_checkout_service.dart';
import '../services/subscription_management_service.dart';
import '../services/subscription_state_service.dart';

typedef SubscriptionStateLoader = Future<SubscriptionState?> Function();

typedef SubscriptionCheckoutStarter =
    Future<void> Function({
      required SubscriptionPlanTier plan,
      required SubscriptionBillingPeriod billingPeriod,
    });

typedef SubscriptionCancellationStarter =
    Future<SubscriptionCancellationResult> Function();

typedef SubscriptionPlanChangeStarter =
    Future<SubscriptionPlanChangeResult> Function(SubscriptionPlanTier targetPlan);

class SubscriptionStatusScreen extends StatefulWidget {
  const SubscriptionStatusScreen({
    super.key,
    this.loadState,
    this.startCheckout,
    this.cancelSubscription,
    this.changePlan,
  });

  final SubscriptionStateLoader? loadState;
  final SubscriptionCheckoutStarter? startCheckout;
  final SubscriptionCancellationStarter? cancelSubscription;
  final SubscriptionPlanChangeStarter? changePlan;

  @override
  State<SubscriptionStatusScreen> createState() =>
      _SubscriptionStatusScreenState();
}

class _SubscriptionStatusScreenState extends State<SubscriptionStatusScreen> {
  SubscriptionState? _state;
  bool _loading = true;
  String? _error;
  SubscriptionBillingPeriod _billingPeriod =
      SubscriptionBillingPeriod.monthly;
  SubscriptionPlanTier? _startingPlan;
  SubscriptionPlanTier? _changingPlan;
  bool _canceling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final loader =
          widget.loadState ?? SubscriptionStateService.fetchCurrentState;
      final state = await loader();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
        _error = state == null ? '契約情報を取得できませんでした。' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = null;
        _loading = false;
        _error = '契約情報を取得できませんでした。';
      });
    }
  }

  Future<void> _startCheckout(SubscriptionPlanTier plan) async {
    if (_startingPlan != null) return;
    setState(() => _startingPlan = plan);

    try {
      final starter =
          widget.startCheckout ?? SubscriptionCheckoutService.startCheckout;
      await starter(plan: plan, billingPeriod: _billingPeriod);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('購入画面を開きました。決済完了後にこの画面を更新してください。')),
      );
    } on SubscriptionCheckoutException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('購入手続きを開始できませんでした。時間をおいて再度お試しください。'),
        ),
      );
    } finally {
      if (mounted) setState(() => _startingPlan = null);
    }
  }

  Future<void> _schedulePlanChange(
    SubscriptionState state,
    SubscriptionPlanTier targetPlan,
  ) async {
    if (_changingPlan != null || targetPlan == state.effectivePlan) return;

    final effectiveAt = state.currentPeriodEnd;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${targetPlan.label}へ変更しますか？'),
        content: Text(
          effectiveAt == null
              ? '現在の請求期間が終了した時点でプランを変更します。日割り請求・日割り返金は行いません。'
              : state.isTrialing
                  ? '${_formatDate(effectiveAt)}の無料体験終了時に${targetPlan.label}へ変更します。'
                  : '${_formatDate(effectiveAt)}の次回更新日から${targetPlan.label}へ変更します。日割り請求・日割り返金は行いません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('変更を予約'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _changingPlan = targetPlan);
    try {
      final changer = widget.changePlan ??
          (plan) => SubscriptionManagementService.schedulePlanChange(
                targetPlan: plan,
              );
      final result = await changer(targetPlan);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_formatDate(result.effectiveAt)}から${result.scheduledPlan.label}へ変更します。',
          ),
        ),
      );
      await _load();
    } on SubscriptionPlanChangeException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('プラン変更を予約できませんでした。契約状態を確認して再度お試しください。'),
        ),
      );
    } finally {
      if (mounted) setState(() => _changingPlan = null);
    }
  }

  Future<void> _cancelSubscription(SubscriptionState state) async {
    if (_canceling) return;

    final immediate = state.isTrialing;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(immediate ? '無料体験を解約しますか？' : '契約を解約しますか？'),
        content: Text(
          immediate
              ? '無料体験は直ちに終了し、Freeプランへ戻ります。この無料体験は再利用できません。'
              : state.currentPeriodEnd == null
                  ? '自動更新を停止します。現在の利用期間が終了するまでは有料機能を利用できます。'
                  : '${_formatDate(state.currentPeriodEnd!)}で自動更新を停止します。それまでは有料機能を利用できます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解約する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _canceling = true);
    try {
      final starter =
          widget.cancelSubscription ??
          SubscriptionManagementService.cancelCurrentSubscription;
      final result = await starter();
      if (!mounted) return;

      final message = switch (result.mode) {
        SubscriptionCancellationMode.immediate =>
          '無料体験を解約しました。Freeプランへ移行します。',
        SubscriptionCancellationMode.periodEnd =>
          result.effectiveAt == null
              ? '自動更新を停止しました。現在の利用期間終了後にFreeへ移行します。'
              : '${_formatDate(result.effectiveAt!)}で自動更新を停止します。',
        SubscriptionCancellationMode.alreadyScheduled =>
          'すでに解約予約済みです。',
        SubscriptionCancellationMode.alreadyCanceled =>
          '契約はすでに終了しています。',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      await _load();
    } on SubscriptionCancellationException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('解約手続きを完了できませんでした。時間をおいて再度お試しください。'),
        ),
      );
    } finally {
      if (mounted) setState(() => _canceling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('プラン・契約')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: double.infinity,
                  child: _buildContent(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 72),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final state = _state;
    if (state == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text(_error ?? '契約情報を取得できませんでした。'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込み'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CurrentSubscriptionCard(state: state),
        if (state.isPaid && !state.cancelAtPeriodEnd) ...[
          const SizedBox(height: 18),
          _CancellationCard(
            state: state,
            canceling: _canceling,
            onCancel: () => _cancelSubscription(state),
          ),
        ],
        if (state.effectivePlan == SubscriptionPlanTier.free) ...[
          const SizedBox(height: 18),
          _CheckoutControls(
            billingPeriod: _billingPeriod,
            onChanged: (period) => setState(() => _billingPeriod = period),
          ),
        ],
        const SizedBox(height: 18),
        Text(
          'プラン比較',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ..._planDefinitions.map(
          (plan) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PlanCard(
              definition: plan,
              currentPlan: state.effectivePlan,
              billingPeriod: _billingPeriod,
              startingPlan: _startingPlan,
              changingPlan: _changingPlan,
              canChangePlan:
                  state.isPaid &&
                  !state.cancelAtPeriodEnd &&
                  !state.hasScheduledPlan &&
                  !state.isPastDue &&
                  plan.tier != SubscriptionPlanTier.free &&
                  plan.tier != state.effectivePlan,
              planChangeLabel: state.isTrialing
                  ? '無料体験終了後に変更'
                  : '次回更新日から変更',
              onStartCheckout: _startCheckout,
              onChangePlan: (target) => _schedulePlanChange(state, target),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '契約操作について',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  state.effectivePlan == SubscriptionPlanTier.free
                      ? 'Plus／Premiumの新規契約はこの画面から開始できます。'
                      : state.hasScheduledPlan
                          ? 'プラン変更は予約済みです。現在の契約情報に変更予定日を表示しています。'
                          : 'Plus／Premium間の変更予約と契約の解約をこの画面から行えます。',
                  style: const TextStyle(height: 1.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  '無料体験は10日間で、Plus／Premiumを通じて1アカウントにつき1回です。プラン変更と有料契約の解約は次回更新日に反映し、日割り請求・日割り返金は行いません。支払失敗時は7日間の猶予があります。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _CancellationCard extends StatelessWidget {
  const _CancellationCard({
    required this.state,
    required this.canceling,
    required this.onCancel,
  });

  final SubscriptionState state;
  final bool canceling;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final immediate = state.isTrialing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '契約の解約',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              immediate
                  ? '無料体験中の解約は即時反映され、Freeプランへ戻ります。'
                  : state.currentPeriodEnd == null
                      ? '解約すると自動更新を停止し、現在の利用期間終了後にFreeへ移行します。'
                      : '${_formatDate(state.currentPeriodEnd!)}までは現在のプランを利用できます。',
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: canceling ? null : onCancel,
              icon: canceling
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cancel_outlined),
              label: Text(immediate ? '無料体験を解約' : '次回更新日で解約'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckoutControls extends StatelessWidget {
  const _CheckoutControls({
    required this.billingPeriod,
    required this.onChanged,
  });

  final SubscriptionBillingPeriod billingPeriod;
  final ValueChanged<SubscriptionBillingPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'お支払い方法',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '月額または年額を選択して、有料プランの購入画面へ進みます。無料体験を未利用の場合は10日間の無料体験が適用されます。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            SegmentedButton<SubscriptionBillingPeriod>(
              segments: const [
                ButtonSegment(
                  value: SubscriptionBillingPeriod.monthly,
                  label: Text('月額'),
                  icon: Icon(Icons.calendar_month_outlined),
                ),
                ButtonSegment(
                  value: SubscriptionBillingPeriod.annual,
                  label: Text('年額'),
                  icon: Icon(Icons.event_repeat_outlined),
                ),
              ],
              selected: {billingPeriod},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onChanged(selection.first);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentSubscriptionCard extends StatelessWidget {
  const _CurrentSubscriptionCard({required this.state});

  final SubscriptionState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = <_StatusDetail>[
      _StatusDetail('現在のプラン', state.effectivePlan.label),
      _StatusDetail('契約状態', state.billingStatusLabel),
    ];

    if (state.isTrialing && state.trialEndsAt != null) {
      details.add(_StatusDetail('無料体験終了予定', _formatDate(state.trialEndsAt!)));
    }
    if (state.isPaid && state.currentPeriodEnd != null) {
      details.add(
        _StatusDetail(
          state.cancelAtPeriodEnd ? '利用期限' : '次回更新日',
          _formatDate(state.currentPeriodEnd!),
        ),
      );
    }
    if (state.isPastDue && state.paymentGraceUntil != null) {
      details.add(
        _StatusDetail('支払猶予期限', _formatDate(state.paymentGraceUntil!)),
      );
    }
    if (state.cancelAtPeriodEnd) {
      details.add(
        _StatusDetail(
          '解約予定',
          state.currentPeriodEnd == null
              ? '次回更新日にFreeへ移行'
              : '${_formatDate(state.currentPeriodEnd!)}にFreeへ移行',
        ),
      );
    } else if (state.hasScheduledPlan) {
      final effectiveAt = state.scheduledPlanEffectiveAt;
      details.add(
        _StatusDetail(
          '変更予定',
          effectiveAt == null
              ? '${state.scheduledPlan!.label}へ変更'
              : '${_formatDate(effectiveAt)}から${state.scheduledPlan!.label}',
        ),
      );
    }
    details.add(
      _StatusDetail(
        '無料体験',
        state.trialUsed ? '利用済み' : '未利用（全有料プラン共通で1回）',
      ),
    );

    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '現在の契約',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Chip(label: Text(state.billingStatusLabel)),
              ],
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < details.length; index++) ...[
              _StatusRow(detail: details[index]),
              if (index < details.length - 1) const Divider(height: 20),
            ],
            if (state.isPastDue) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'お支払いを確認できない状態です。猶予期限までに解消しない場合、Freeへ移行します。',
                  style: TextStyle(color: scheme.onErrorContainer, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusDetail {
  const _StatusDetail(this.label, this.value);

  final String label;
  final String value;
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.detail});

  final _StatusDetail detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            detail.label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail.value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _PlanDefinition {
  const _PlanDefinition({
    required this.tier,
    required this.price,
    required this.features,
  });

  final SubscriptionPlanTier tier;
  final String price;
  final List<String> features;
}

const _planDefinitions = <_PlanDefinition>[
  _PlanDefinition(
    tier: SubscriptionPlanTier.free,
    price: '0円',
    features: [
      '広告あり',
      'お気に入り 3冊',
      'ページカラー 3色',
      '「読みたい！」・返信は利用不可',
    ],
  ),
  _PlanDefinition(
    tier: SubscriptionPlanTier.plus,
    price: '月額 300円 ／ 年額 3,000円',
    features: [
      '広告なし',
      'お気に入り 12冊',
      'ページカラー 3色',
      '他ユーザーの1投稿につき親返信を1件',
      '「読みたい！」・返信編集・返信への返信は利用不可',
    ],
  ),
  _PlanDefinition(
    tier: SubscriptionPlanTier.premium,
    price: '月額 550円 ／ 年額 5,000円',
    features: [
      '広告なし',
      'お気に入り 無制限',
      'ページカラー 全14色',
      '「読みたい！」を利用可能',
      '複数返信・返信への返信・自分の返信編集を利用可能',
    ],
  ),
];

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.definition,
    required this.currentPlan,
    required this.billingPeriod,
    required this.startingPlan,
    required this.changingPlan,
    required this.canChangePlan,
    required this.planChangeLabel,
    required this.onStartCheckout,
    required this.onChangePlan,
  });

  final _PlanDefinition definition;
  final SubscriptionPlanTier currentPlan;
  final SubscriptionBillingPeriod billingPeriod;
  final SubscriptionPlanTier? startingPlan;
  final SubscriptionPlanTier? changingPlan;
  final bool canChangePlan;
  final String planChangeLabel;
  final ValueChanged<SubscriptionPlanTier> onStartCheckout;
  final ValueChanged<SubscriptionPlanTier> onChangePlan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = definition.tier == currentPlan;
    final canStartCheckout =
        currentPlan == SubscriptionPlanTier.free &&
        definition.tier != SubscriptionPlanTier.free;
    return Card(
      elevation: current ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: current ? scheme.primary : scheme.outlineVariant,
          width: current ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    definition.tier.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (current)
                  Chip(
                    avatar: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('現在のプラン'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              definition.price,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            for (final feature in definition.features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check, size: 17),
                    const SizedBox(width: 8),
                    Expanded(child: Text(feature)),
                  ],
                ),
              ),
            if (canStartCheckout) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: startingPlan == null
                      ? () => onStartCheckout(definition.tier)
                      : null,
                  child: startingPlan == definition.tier
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('${billingPeriod.label}で申し込む'),
                ),
              ),
            ],
            if (canChangePlan) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: changingPlan == null
                      ? () => onChangePlan(definition.tier)
                      : null,
                  icon: changingPlan == definition.tier
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.event_repeat_outlined),
                  label: Text(planChangeLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}年${local.month}月${local.day}日';
}
