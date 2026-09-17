import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/post_reply.dart';
import '../services/reply_editing_service.dart';
import 'post_reply_actions.dart';

class PostReplyOwnerActions extends StatefulWidget {
  const PostReplyOwnerActions({
    super.key,
    required this.reply,
    required this.onChanged,
    required this.iconColor,
  });

  final PostReply reply;
  final Future<void> Function() onChanged;
  final Color iconColor;

  @override
  State<PostReplyOwnerActions> createState() => _PostReplyOwnerActionsState();
}

class _PostReplyOwnerActionsState extends State<PostReplyOwnerActions> {
  late Future<bool> _canEditFuture;

  bool get _isOwner =>
      Supabase.instance.client.auth.currentUser?.id == widget.reply.profileId;

  @override
  void initState() {
    super.initState();
    _canEditFuture = ReplyEditingService.canEditReplies();
  }

  @override
  void didUpdateWidget(covariant PostReplyOwnerActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reply.id != widget.reply.id ||
        oldWidget.reply.updatedAt != widget.reply.updatedAt) {
      _canEditFuture = ReplyEditingService.canEditReplies();
    }
  }

  Future<void> _handleAction(String action) async {
    if (!_isOwner) return;
    var changed = false;
    if (action == 'edit') {
      changed = await showPostReplyEditDialog(
        context: context,
        reply: widget.reply,
      );
    } else if (action == 'delete') {
      changed = await showPostReplyDeleteDialog(
        context: context,
        reply: widget.reply,
      );
    }
    if (!mounted || !changed) return;
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isOwner) return const SizedBox.shrink();

    return FutureBuilder<bool>(
      future: _canEditFuture,
      builder: (context, snapshot) {
        final canEdit = snapshot.data == true;
        return PopupMenuButton<String>(
          tooltip: '自分の返信メニュー',
          icon: Icon(Icons.more_horiz, size: 17, color: widget.iconColor),
          padding: EdgeInsets.zero,
          position: PopupMenuPosition.under,
          onSelected: _handleAction,
          itemBuilder: (context) => [
            if (canEdit)
              const PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('返信を編集'),
                  ],
                ),
              ),
            const PopupMenuItem<String>(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  SizedBox(width: 8),
                  Text('返信を削除', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
