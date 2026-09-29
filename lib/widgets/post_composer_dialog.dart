import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/post.dart';
import '../services/content_safety_service.dart';
import '../services/supabase_service.dart';

Future<bool> showPostComposerDialog({
  required BuildContext context,
  required Book book,
  Post? existingPost,
}) async {
  final service = Provider.of<SupabaseService>(context, listen: false);
  if (ContentSafetyService.isAdultBook(book) &&
      !await service.canViewAdultContent()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この書籍は18歳未満の利用者には表示・投稿できません。')),
      );
    }
    return false;
  }
  if (!context.mounted) return false;

  final isEditing = existingPost != null;
  double rating = existingPost?.rating ?? 5.0;
  bool isSpoiler = existingPost?.hasSpoiler ?? false;
  bool isSubmitting = false;
  final commentController = TextEditingController(
    text: existingPost?.reviewText ?? '',
  );

  final posted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final availableWidth = MediaQuery.sizeOf(dialogContext).width;
          final dialogWidth = (availableWidth - 80).clamp(280.0, 620.0);
          return AlertDialog(
            backgroundColor: const Color(0xFFE9E9E9),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            title: isEditing ? const Text('投稿を編集') : null,
            content: SizedBox(
              width: dialogWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 88,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 88,
                                height: 126,
                                color: Colors.grey[350],
                                child: book.coverUrl.trim().isNotEmpty
                                    ? Image.network(
                                        book.coverUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                _MissingCover(book: book),
                                      )
                                    : _MissingCover(book: book),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                book.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _SpoilerButton(
                                    label: 'ネタバレなし投稿',
                                    selected: !isSpoiler,
                                    onPressed: () {
                                      setDialogState(() => isSpoiler = false);
                                    },
                                  ),
                                  _SpoilerButton(
                                    label: 'ネタバレあり投稿',
                                    selected: isSpoiler,
                                    onPressed: () {
                                      setDialogState(() => isSpoiler = true);
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 2,
                                children: [
                                  ...List.generate(5, (index) {
                                    final starValue = index + 1.0;
                                    return IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 40,
                                      ),
                                      icon: Icon(
                                        rating >= starValue
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: const Color(0xFFE0B400),
                                        size: 34,
                                      ),
                                      onPressed: () {
                                        setDialogState(
                                          () => rating = starValue,
                                        );
                                      },
                                    );
                                  }),
                                  const SizedBox(width: 6),
                                  Text(
                                    rating.toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 24,
                                      color: Color(0xFFE0B400),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      height: 140,
                      color: const Color(0xFFD2D2D2),
                      padding: const EdgeInsets.all(10),
                      child: TextField(
                        controller: commentController,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(color: Colors.black87),
                        decoration: const InputDecoration(
                          hintText:
                              '例：印象に残った場面、その理由、読後に考えたことなどを自分の言葉で書いてみましょう',
                          hintStyle: TextStyle(color: Colors.black54),
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '短い感想でも投稿できます。あとで振り返ったときに分かるよう、作品のどこが印象に残ったか、なぜそう感じたかまで書くと読書記録として役立ちます。',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () => Navigator.of(dialogContext).pop(false),
                child: Text('キャンセル', style: TextStyle(color: Colors.grey[600])),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3B30),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final review = commentController.text.trim();
                        if (review.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('感想を入力してください')),
                          );
                          return;
                        }

                        setDialogState(() => isSubmitting = true);
                        final success = isEditing
                            ? await service.updateOwnPost(
                                post: existingPost,
                                rating: rating,
                                comment: review,
                                isSpoiler: isSpoiler,
                              )
                            : await service.createPost(
                                book: book,
                                rating: rating,
                                comment: review,
                                isSpoiler: isSpoiler,
                              );

                        if (!dialogContext.mounted) return;
                        if (success) {
                          Navigator.of(dialogContext).pop(true);
                        } else {
                          setDialogState(() => isSubmitting = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('保存できませんでした。もう一度お試しください。'),
                            ),
                          );
                        }
                      },
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(isEditing ? '保存する' : '投稿する'),
              ),
            ],
          );
        },
      );
    },
  );

  commentController.dispose();
  if (posted == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isEditing ? '投稿を編集しました' : 'レビューを投稿しました')),
    );
  }
  return posted ?? false;
}

class _SpoilerButton extends StatelessWidget {
  const _SpoilerButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black,
        foregroundColor: selected ? const Color(0xFFFF1F1F) : Colors.white70,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Text(label),
    );
  }
}

class _MissingCover extends StatelessWidget {
  const _MissingCover({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[300],
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book_outlined, color: Colors.black45, size: 30),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.black54,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
