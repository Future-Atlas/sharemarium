import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/social_models.dart';
import '../services/supabase_service.dart';
import 'post_detail_screen.dart';
import 'user_profile_screen.dart';

class NotificationBellButton extends StatefulWidget {
  const NotificationBellButton({super.key, this.onOpenProfile});

  final ValueChanged<String>? onOpenProfile;

  @override
  State<NotificationBellButton> createState() => _NotificationBellButtonState();
}

class _NotificationBellButtonState extends State<NotificationBellButton> {
  Timer? _timer;
  int _unreadCount = 0;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    _refreshing = true;
    final service = Provider.of<SupabaseService>(context, listen: false);
    final count = await service.fetchUnreadNotificationCount();
    _refreshing = false;
    if (mounted && count != _unreadCount) {
      setState(() => _unreadCount = count);
    }
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            NotificationsScreen(onOpenProfile: widget.onOpenProfile),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '通知',
      onPressed: _openNotifications,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Text('📣', style: TextStyle(fontSize: 21)),
          if (_unreadCount > 0)
            Positioned(
              right: -3,
              top: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, this.onOpenProfile});

  final ValueChanged<String>? onOpenProfile;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<SocialNotification> _notifications = [];
  bool _isLoading = true;
  String? _error;
  final Set<int> _respondingIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final service = Provider.of<SupabaseService>(context, listen: false);
    final notifications = await service.fetchNotifications();
    await service.markNotificationsRead();
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _isLoading = false;
    });
  }

  Future<void> _respond(
    SocialNotification notification, {
    required bool approve,
  }) async {
    setState(() => _respondingIds.add(notification.id));
    final service = Provider.of<SupabaseService>(context, listen: false);
    final success = await service.respondToFollowRequest(
      requesterProfileId: notification.actorId,
      approve: approve,
    );
    if (!mounted) return;
    setState(() => _respondingIds.remove(notification.id));
    if (!success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('フォローリクエストを処理できませんでした。')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(approve ? 'フォローを承認しました。' : 'リクエストを拒否しました。')),
    );
    await _load();
  }

  Future<void> _openActorProfile(SocialNotification notification) async {
    final openInMainShell = widget.onOpenProfile;
    if (openInMainShell != null) {
      Navigator.of(context).pop();
      openInMainShell(notification.actorId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          profileId: notification.actorId,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openNotification(SocialNotification notification) async {
    if ((notification.type == SocialNotificationType.reply ||
            notification.type == SocialNotificationType.reaction ||
            notification.type == SocialNotificationType.wantToRead ||
            notification.type == SocialNotificationType.wantToReadCompleted ||
            notification.type == SocialNotificationType.newPost) &&
        notification.postId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PostDetailScreen(
            postId: notification.postId!,
            onOpenProfile: widget.onOpenProfile,
            highlightedReplyId:
                notification.type == SocialNotificationType.reply
                ? notification.replyId
                : null,
          ),
        ),
      );
      if (mounted) await _load();
      return;
    }
    await _openActorProfile(notification);
  }

  String _message(SocialNotification notification) {
    final actor = notification.actorUserId.isEmpty
        ? '${notification.actorUsername}さん'
        : '${notification.actorUsername}（@${notification.actorUserId}）さん';
    final bookTitle = notification.bookTitle ?? '書籍';
    switch (notification.type) {
      case SocialNotificationType.reaction:
        return '$actorがあなたの『$bookTitle』の投稿にリアクションしました';
      case SocialNotificationType.wantToRead:
        return '$actorがあなたの『$bookTitle』の投稿を「読みたい！」しました';
      case SocialNotificationType.wantToReadCompleted:
        return '$actorが『$bookTitle』を読了しました';
      case SocialNotificationType.reply:
        return '$actorがあなたの『$bookTitle』の投稿に返信しました';
      case SocialNotificationType.follow:
        return '$actorがあなたをフォローしました';
      case SocialNotificationType.followRequest:
        return '$actorからあなたにフォローリクエストが届いています';
      case SocialNotificationType.newPost:
        return '$actorが『$bookTitle』の感想を投稿しました';
    }
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(child: Text(_error!)),
                ],
              )
            : _notifications.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('通知はありません。')),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _notifications.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final notification = _notifications[index];
                  final responding = _respondingIds.contains(notification.id);
                  return Material(
                    color: notification.isRead
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.primaryContainer
                              .withValues(alpha: 0.24),
                    child: InkWell(
                      onTap: () => _openNotification(notification),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              backgroundImage:
                                  notification.actorAvatarUrl.isNotEmpty
                                  ? NetworkImage(notification.actorAvatarUrl)
                                  : null,
                              child: notification.actorAvatarUrl.isEmpty
                                  ? const Icon(Icons.person)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_message(notification)),
                                  const SizedBox(height: 5),
                                  Text(
                                    _formatDate(notification.createdAt),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (notification.type ==
                                          SocialNotificationType
                                              .followRequest &&
                                      notification.followRequestPending) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        FilledButton(
                                          onPressed: responding
                                              ? null
                                              : () => _respond(
                                                  notification,
                                                  approve: true,
                                                ),
                                          child: const Text('承認'),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton(
                                          onPressed: responding
                                              ? null
                                              : () => _respond(
                                                  notification,
                                                  approve: false,
                                                ),
                                          child: const Text('拒否'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
