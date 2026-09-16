import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/favorite_retention_service.dart';
import '../services/supabase_service.dart';

/// Handles a favorite-limit result from the legacy Flutter client.
///
/// Premium is unlimited in the database, so if the old finite client precheck
/// fires for a Premium account we add through the Premium-only RPC instead of
/// showing a replacement dialog. Free/Plus use the same replacement UX with
/// their current 3/12-book limit.
Future<bool> showFavoriteReplacementDialog({
  required BuildContext context,
  required String targetBookId,
  required String targetBookTitle,
}) async {
  final service = Provider.of<SupabaseService>(context, listen: false);
  final retentionState = await FavoriteRetentionService.fetchState();
  if (!context.mounted) return false;
  if (retentionState?.isPremium == true &&
      retentionState?.isUnlimited == true) {
    return FavoriteRetentionService.addPremiumFavorite(targetBookId);
  }

  final replacementLimit =
      retentionState?.favoriteLimit ?? await service.fetchCurrentFavoriteLimit();
  if (!context.mounted) return false;
  final favorites = await service.fetchUserFavorites(service.activeProfileId);
  if (!context.mounted) return false;

  return (await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _FavoriteReplacementDialog(
          targetBookId: targetBookId,
          targetBookTitle: targetBookTitle,
          favorites: favorites.take(replacementLimit).toList(),
        ),
      )) ??
      false;
}

class _FavoriteReplacementDialog extends StatefulWidget {
  const _FavoriteReplacementDialog({
    required this.targetBookId,
    required this.targetBookTitle,
    required this.favorites,
  });

  final String targetBookId;
  final String targetBookTitle;
  final List<Book> favorites;

  @override
  State<_FavoriteReplacementDialog> createState() =>
      _FavoriteReplacementDialogState();
}

class _FavoriteReplacementDialogState
    extends State<_FavoriteReplacementDialog> {
  String? _replacingBookId;
  String? _errorMessage;

  Future<void> _replace(Book removedBook) async {
    if (_replacingBookId != null) return;
    setState(() {
      _replacingBookId = removedBook.id;
      _errorMessage = null;
    });

    final service = Provider.of<SupabaseService>(context, listen: false);
    final replaced = await service.replaceFavorite(
      removedBookId: removedBook.id,
      addedBookId: widget.targetBookId,
    );
    if (!mounted) return;
    if (replaced) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _replacingBookId = null;
      _errorMessage = 'お気に入りを入れ替えられませんでした。もう一度お試しください。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('お気に入りを入れ替える'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('「お気に入り」に登録できる本の上限に達しています。本を入れ替えますか？'),
            const SizedBox(height: 8),
            Text(
              '「${widget.targetBookTitle}」を登録するには、入れ替える本を1冊選んでください。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                itemCount: widget.favorites.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.56,
                ),
                itemBuilder: (context, index) {
                  final book = widget.favorites[index];
                  final replacing = _replacingBookId == book.id;
                  return Semantics(
                    button: true,
                    label: '「${book.title}」を入れ替える',
                    child: InkWell(
                      onTap: _replacingBookId == null
                          ? () => _replace(book)
                          : null,
                      borderRadius: BorderRadius.circular(8),
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
                                                    child: Icon(Icons.menu_book),
                                                  ),
                                        ),
                                ),
                                if (replacing)
                                  const ColoredBox(
                                    color: Color(0x99000000),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _replacingBookId == null
              ? () => Navigator.of(context).pop(false)
              : null,
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}
