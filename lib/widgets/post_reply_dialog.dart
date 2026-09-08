import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/input_security_service.dart';
import '../services/supabase_service.dart';

class _ReplyLengthFormatter extends TextInputFormatter {
  const _ReplyLengthFormatter();

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

Future<void> showPostReplyLockedDialog({
  required BuildContext context,
  bool? isAuthenticated,
}) {
  final signedIn = isAuthenticated ?? SupabaseService().isAuthenticated;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            signedIn ? Icons.lock_rounded : Icons.login_rounded,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            signedIn ? '返信は限定コンテンツです' : '返信するにはサインインしてください',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (!signedIn) ...[
            const SizedBox(height: 10),
            const Text(
              '公開投稿と返信はサインインせず閲覧できます。返信を投稿する場合のみサインインが必要です。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('閉じる'),
        ),
        if (!signedIn)
          FilledButton(
            onPressed: () {
              final navigator = Navigator.of(context);
              Navigator.of(dialogContext).pop();
              navigator.pushNamed('/login');
            },
            child: const Text('サインイン'),
          ),
      ],
    ),
  );
}

Future<bool> showPostReplyDialog({
  required BuildContext context,
  required String postId,
  String? parentReplyId,
  String? replyToUsername,
}) async {
  final controller = TextEditingController();
  var isSubmitting = false;
  var hasSpoiler = false;

  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final availableWidth = MediaQuery.sizeOf(dialogContext).width - 80;
      final contentWidth = availableWidth.clamp(240.0, 340.0).toDouble();

      return StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            replyToUsername == null ? '返信する' : '$replyToUsernameさんに返信',
          ),
          content: SizedBox(
            width: contentWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('100文字以内で返信できます', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                TextField(
                  controller: controller,
                  enabled: !isSubmitting,
                  minLines: 5,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  inputFormatters: const [_ReplyLengthFormatter()],
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
                      : (value) {
                          setDialogState(() => hasSpoiler = value);
                        },
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
                      final service = SupabaseService();
                      final error = await service.createPostReply(
                        postId: postId,
                        message: controller.text,
                        parentReplyId: parentReplyId,
                        hasSpoiler: hasSpoiler,
                      );
                      if (!dialogContext.mounted) return;
                      if (error == null) {
                        Navigator.of(dialogContext).pop(true);
                        return;
                      }
                      setDialogState(() => isSubmitting = false);
                      ScaffoldMessenger.of(
                        dialogContext,
                      ).showSnackBar(SnackBar(content: Text(error)));
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('返信を投稿'),
            ),
          ],
        ),
      );
    },
  );

  controller.dispose();
  return submitted == true;
}
