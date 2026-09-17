import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/post_reply.dart';
import '../services/input_security_service.dart';
import '../services/reply_editing_service.dart';

class _ReplyEditLengthFormatter extends TextInputFormatter {
  const _ReplyEditLengthFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final isWithinLimits =
        newValue.text.runes.length <=
            InputSecurityService.maxReplyRawCharacters &&
        InputSecurityService.replyCharacterCount(newValue.text) <=
            InputSecurityService.maxReplyCharacters;
    return isWithinLimits ? newValue : oldValue;
  }
}

Future<bool> showPostReplyEditDialog({
  required BuildContext context,
  required PostReply reply,
}) async {
  final canEdit = await ReplyEditingService.canEditReplies();
  if (!context.mounted) return false;
  if (!canEdit) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 56),
            SizedBox(height: 14),
            Text(
              '返信の編集はPremium限定です',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              '契約終了後も既存の返信は閲覧・削除できますが、編集はできません。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    return false;
  }

  final controller = TextEditingController(text: reply.message);
  var isSubmitting = false;
  var hasSpoiler = reply.hasSpoiler;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final availableWidth = MediaQuery.sizeOf(dialogContext).width - 80;
      final contentWidth = availableWidth.clamp(240.0, 340.0).toDouble();
      return StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('返信を編集'),
          content: SizedBox(
            width: contentWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('100文字以内で編集できます', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                TextField(
                  controller: controller,
                  enabled: !isSubmitting,
                  minLines: 5,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  inputFormatters: const [_ReplyEditLengthFormatter()],
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '返信内容を入力',
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, child) => Text(
                      '${InputSecurityService.replyCharacterCount(value.text)}/100',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  value: hasSpoiler,
                  onChanged: isSubmitting
                      ? null
                      : (value) => setDialogState(() => hasSpoiler = value),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('ネタバレあり', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      setDialogState(() => isSubmitting = true);
                      final error = await ReplyEditingService.updateReply(
                        replyId: reply.id,
                        message: controller.text,
                        hasSpoiler: hasSpoiler,
                      );
                      if (!dialogContext.mounted) return;
                      if (error == null) {
                        Navigator.of(dialogContext).pop(true);
                        return;
                      }
                      setDialogState(() => isSubmitting = false);
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(error)),
                      );
                    },
              child: isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('変更を保存'),
            ),
          ],
        ),
      );
    },
  );

  controller.dispose();
  return saved == true;
}

Future<bool> showPostReplyDeleteDialog({
  required BuildContext context,
  required PostReply reply,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('返信を削除'),
      content: const Text('この返信を削除しますか？この操作は取り消せません。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final error = await ReplyEditingService.deleteOwnReply(reply.id);
  if (!context.mounted) return false;
  if (error == null) return true;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  return false;
}
