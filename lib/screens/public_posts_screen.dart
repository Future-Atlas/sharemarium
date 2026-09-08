import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../models/post_reply.dart';
import '../models/social_models.dart';
import '../services/supabase_service.dart';
import '../widgets/post_card.dart';
import '../widgets/post_reply_dialog.dart';
import 'report_post_dialog.dart';
import 'user_profile_screen.dart';

class PublicPostsScreen extends StatefulWidget {
  const PublicPostsScreen({super.key});

  @override
  State<PublicPostsScreen> createState() => _PublicPostsScreenState();
}

class _PublicPostsScreenState extends State<PublicPostsScreen> {
  List<Post> _posts = const [];
  Map<String, List<PostReply>> _replies = const {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final service = Provider.of<SupabaseService>(context, listen: false);
    final posts = await service.fetchTimelinePosts();
    final replies = await service.fetchRepliesForPosts(
      posts.map((post) => post.id).toList(growable: false),
    );
    if (!mounted) return;
    setState(() {
      _posts = posts;
      _replies = replies;
      _isLoading = false;
    });
  }

  Future<bool> _ensureAuthenticated() async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (service.canWrite) return true;
    final result = await Navigator.of(context).pushNamed('/login');
    return mounted && (result == true || service.canWrite);
  }

  Future<void> _openProfile(String profileId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => UserProfileScreen(
          profileId: profileId,
          onBack: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _toggleReaction(
    Post post,
    PostReactionType reaction,
  ) async {
    if (!await _ensureAuthenticated() || !mounted) return;
    final service = Provider.of<SupabaseService>(context, listen: false);
    final updated = await service.setPostReaction(post.id, reaction);
    if (!mounted) return;
    if (!updated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('リアクションを更新できませんでした。')),
      );
      return;
    }
    await _load();
  }

  Future<void> _replyToPost(Post post, [PostReply? parentReply]) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final canReply = await service.canCreatePostReplies();
    if (!mounted) return;
    if (!canReply) {
      await showPostReplyLockedDialog(context: context);
      return;
    }

    final posted = await showPostReplyDialog(
      context: context,
      postId: post.id,
      parentReplyId: parentReply?.id,
      replyToUsername: parentReply?.username,
    );
    if (!posted || !mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('返信を投稿しました。')));
  }

  Future<void> _reportPost(String postId) async {
    if (!await _ensureAuthenticated() || !mounted) return;
    await showPostReportDialog(context: context, postId: postId);
  }

  Future<void> _reportReply(PostReply reply) async {
    if (!await _ensureAuthenticated() || !mounted) return;
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (reply.profileId == service.activeProfileId) return;
    await showReplyReportDialog(context: context, replyId: reply.id);
  }

  void _goHome() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SupabaseService>(
      builder: (context, service, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('公開投稿'),
            actions: [
              IconButton(
                tooltip: 'ホーム',
                onPressed: _goHome,
                icon: const Icon(Icons.home_outlined),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _load,
            child: _isLoading && _posts.isEmpty
                ? const ListView(
                    physics: AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: 360,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ],
                  )
                : _posts.isEmpty
                ? const ListView(
                    physics: AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.all(24),
                    children: [
                      SizedBox(height: 120),
                      Center(child: Text('公開投稿はまだありません。')),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _posts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      final post = _posts[index];
                      final isOwnPost =
                          service.activeProfileId.isNotEmpty &&
                          post.profileId == service.activeProfileId;
                      return PostCard(
                        key: ValueKey(post.id),
                        post: post,
                        replies: _replies[post.id] ?? const [],
                        concealSpoiler: !isOwnPost,
                        concealReplySpoiler: (reply) =>
                            reply.profileId != service.activeProfileId,
                        onUserTap: () => _openProfile(post.profileId),
                        onReplyUserTap: _openProfile,
                        onReaction: isOwnPost
                            ? null
                            : (reaction) => _toggleReaction(post, reaction),
                        onReport: isOwnPost
                            ? null
                            : () => _reportPost(post.id),
                        onReply: (parentReply) =>
                            _replyToPost(post, parentReply),
                        onReplyReport: _reportReply,
                        canReportReply: (reply) =>
                            service.activeProfileId.isEmpty ||
                            reply.profileId != service.activeProfileId,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
