import 'package:flutter/material.dart';

import '../models/subscription_state.dart';
import '../services/subscription_state_service.dart';

typedef SubscriptionStateLoader = Future<SubscriptionState?> Function();

class SubscriptionStatusScreen extends StatefulWidget {
  const SubscriptionStatusScreen({super.key, this.loadState});

  final SubscriptionStateLoader? loadState;

  @override
  State<SubscriptionStatusScreen> createState() =>
      _SubscriptionStatusScreenState();
}

class _SubscriptionStatusScreenState extends State<SubscriptionStatusScreen> {
  SubscriptionState? _state;
  bool _loading = true;
  String? _error;

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
                const Text(
                  '現在は契約状態の確認のみ利用できます。新規契約・プラン変更・解約のオンライン操作は、決済機能の公開後にこの画面へ追加します。',
                  style: TextStyle(height: 1.5),
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
  const _PlanCard({required this.definition, required this.currentPlan});

  final _PlanDefinition definition;
  final SubscriptionPlanTier currentPlan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = definition.tier == currentPlan;
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
