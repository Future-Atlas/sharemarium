import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/favorite_retention_service.dart';
import '../services/supabase_service.dart';

/// Prompts an authenticated user to choose the favorites that remain visible
/// when a subscription downgrade lowers the favorite limit.
///
/// Database RLS already caps the public shelf even before this dialog is
/// completed, so dismissing or racing this UI cannot expose excess favorites.
class FavoriteRetentionGate extends StatefulWidget {
  const FavoriteRetentionGate({super.key, required this.child});

  final Widget child;

  @override
  State<FavoriteRetentionGate> createState() => _FavoriteRetentionGateState();
}

class _FavoriteRetentionGateState extends State<FavoriteRetentionGate> {
  String? _observedProfileId;
  bool _checking = false;
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    final profileId = context.watch<SupabaseService>().activeProfileId;
    if (_observedProfileId != profileId) {
      _observedProfileId = profileId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkRetention(profileId);
      });
    }
    return widget.child;
  }

  Future<void> _checkRetention(String profileId) async {
    if (profileId.isEmpty || _checking || _dialogOpen) return;
    _checking = true;
    var retryAfterCheck = false;
    try {
      final service = context.read<SupabaseService>();

      // Do not interrupt the mandatory legal-consent or profile-onboarding
      // flows. Both operations notify SupabaseService when they complete; by
      // clearing the observed ID we re-check on that next rebuild.
      final hasLegalConsent = await service.hasCurrentLegalConsent();
      if (!mounted || _observedProfileId != profileId) return;
      if (!hasLegalConsent) {
        _observedProfileId = null;
        return;
      }

      final hasCompletedRegistration = await service.hasCompletedRegistration();
      if (!mounted || _observedProfileId != profileId) return;
      if (!hasCompletedRegistration) {
        _observedProfileId = null;
        return;
      }

      final state = await FavoriteRetentionService.fetchState();
      if (!mounted || _observedProfileId != profileId) return;
      if (state == null || !state.selectionRequired || state.isUnlimited) return;

      final candidates = await FavoriteRetentionService.fetchCandidates();
      if (!mounted || _observedProfileId != profileId) return;
      if (candidates.length <= state.favoriteLimit) return;

      _dialogOpen = true;
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _FavoriteRetentionSelectionDialog(
          favoriteLimit: state.favoriteLimit,
          candidates: candidates,
        ),
      );
      _dialogOpen = false;
      if (!mounted || _observedProfileId != profileId) return;

      // If saving lost a race with another session or a plan change, re-read
      // once after this check has fully released its in-flight guard.
      retryAfterCheck = saved != true;
    } finally {
      _checking = false;
      if (retryAfterCheck && mounted && _observedProfileId == profileId) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _checkRetention(profileId);
        });
      }
    }
  }
}

class _FavoriteRetentionSelectionDialog extends StatefulWidget {
  const _FavoriteRetentionSelectionDialog({
    required this.favoriteLimit,
    required this.candidates,
  });

  final int favoriteLimit;
  final List<FavoriteRetentionCandidate> candidates;

  @override
  State<_FavoriteRetentionSelectionDialog> createState() =>
      _FavoriteRetentionSelectionDialogState();
}

class _FavoriteRetentionSelectionDialogState
    extends State<_FavoriteRetentionSelectionDialog> {
  late final Set<String> _selectedBookIds;
  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selectedBookIds = widget.candidates
        .where((candidate) => candidate.isSelected)
        .map((candidate) => candidate.book.id)
        .take(widget.favoriteLimit)
        .toSet();
  }

  void _toggle(Book book) {
    if (_saving) return;
    setState(() {
      _errorMessage = null;
      if (_selectedBookIds.remove(book.id)) return;
      if (_selectedBookIds.length < widget.favoriteLimit) {
        _selectedBookIds.add(book.id);
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _selectedBookIds.length != widget.favoriteLimit) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    final saved = await FavoriteRetentionService.saveSelection(_selectedBookIds);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _errorMessage = 'お気に入りの選択を保存できませんでした。もう一度お試しください。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = _selectedBookIds.length;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('表示するお気に入りを選択'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'プラン変更により、お気に入りの表示上限は${widget.favoriteLimit}冊になりました。'
                'データは削除されません。表示する${widget.favoriteLimit}冊を選んでください。',
              ),
              const SizedBox(height: 10),
              Text(
                '$selectedCount / ${widget.favoriteLimit}冊を選択中',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  itemCount: widget.candidates.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.62,
                  ),
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final book = candidate.book;
                    final selected = _selectedBookIds.contains(book.id);
                    final selectionFull =
                        !selected && selectedCount >= widget.favoriteLimit;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: selected
                          ? '「${book.title}」を表示対象から外す'
                          : '「${book.title}」を表示対象にする',
                      child: InkWell(
                        onTap: selectionFull || _saving
                            ? null
                            : () => _toggle(book),
                        borderRadius: BorderRadius.circular(10),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              width: selected ? 3 : 1,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.dividerColor,
                            ),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: book.coverUrl.isEmpty
                                          ? const ColoredBox(
                                              color: Color(0xFFE7E7E7),
                                              child: Icon(Icons.menu_book),
                                            )
                                          : Image.network(
                                              book.coverUrl,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (context, error, stackTrace) =>
                                                      const ColoredBox(
                                                        color: Color(0xFFE7E7E7),
                                                        child: Icon(
                                                          Icons.menu_book,
                                                        ),
                                                      ),
                                            ),
                                    ),
                                    if (selected)
                                      Align(
                                        alignment: Alignment.topRight,
                                        child: Container(
                                          margin: const EdgeInsets.all(5),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary,
                                            shape: BoxShape.circle,
                                          ),
                                          padding: const EdgeInsets.all(3),
                                          child: Icon(
                                            Icons.check,
                                            size: 18,
                                            color: theme.colorScheme.onPrimary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed:
                !_saving && selectedCount == widget.favoriteLimit ? _save : null,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('この内容で保存'),
          ),
        ],
      ),
    );
  }
}
