import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/supabase_service.dart';
import '../models/book.dart';
import '../models/user_profile.dart';
import '../models/post.dart';
import '../models/post_reply.dart';
import '../models/social_models.dart';
import '../models/profile_page_color.dart';
import '../widgets/post_card.dart';
import '../widgets/book_card.dart';
import '../widgets/post_composer_dialog.dart';
import '../widgets/post_reply_dialog.dart';
import 'profile_book_search_screen.dart';
import 'report_post_dialog.dart';
import 'follow_list_screen.dart';
import 'post_engagement_users_screen.dart';
import '../repositories/book_repository.dart';

class UserProfileScreen extends StatefulWidget {
  final VoidCallback onBack;
  final bool showAppBar;
  final String? profileId;
  final ValueChanged<String>? onOpenProfile;

  const UserProfileScreen({
    super.key,
    required this.onBack,
    this.showAppBar = true,
    this.profileId,
    this.onOpenProfile,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _ProfileBookPostsPanel extends StatefulWidget {
  const _ProfileBookPostsPanel({
    required this.postsFuture,
    required this.onProfileTap,
    required this.onReply,
    required this.onReport,
    required this.onReplyReport,
  });

  final Future<({List<Post> posts, Map<String, List<PostReply>> replies})>
  postsFuture;
  final Future<void> Function(String profileId) onProfileTap;
  final Future<void> Function(Post post, [PostReply? parentReply]) onReply;
  final Future<void> Function(String postId) onReport;
  final Future<void> Function(PostReply reply) onReplyReport;

  @override
  State<_ProfileBookPostsPanel> createState() => _ProfileBookPostsPanelState();
}

class _ProfileBookPostsPanelState extends State<_ProfileBookPostsPanel> {
  List<Post> _posts = const [];
  Map<String, List<PostReply>> _replies = const {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.postsFuture;
    if (!mounted) return;
    setState(() {
      _posts = result.posts;
      _replies = result.replies;
      _isLoading = false;
    });
  }

  Future<void> _toggleReaction(Post post, PostReactionType reaction) async {
    final index = _posts.indexWhere((candidate) => candidate.id == post.id);
    if (index < 0) return;
    setState(() {
      final updated = List<Post>.from(_posts);
      updated[index] = post.withToggledReaction(reaction);
      _posts = updated;
    });
    final success = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).setPostReaction(post.id, reaction);
    if (!mounted || success) return;
    setState(() {
      final updated = List<Post>.from(_posts);
      updated[index] = post;
      _posts = updated;
    });
  }

  Future<void> _toggleWantToRead(Post post) async {
    final index = _posts.indexWhere((candidate) => candidate.id == post.id);
    if (index < 0) return;
    setState(() {
      final updated = List<Post>.from(_posts);
      updated[index] = post.withToggledWantToRead();
      _posts = updated;
    });
    final result = await Provider.of<SupabaseService>(context, listen: false)
        .toggleWantToRead(
          book: Book(
            id: post.bookId,
            title: post.bookTitle,
            author: post.bookAuthor,
            publisher: '',
            pubDate: '',
            isbn: post.bookId,
            coverUrl: post.bookCoverUrl,
          ),
          sourcePostId: post.id,
        );
    if (!mounted || !result.shouldRestoreOptimisticState) return;
    setState(() {
      final updated = List<Post>.from(_posts);
      updated[index] = post;
      _posts = updated;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _openEngagementUsers(
    Post post, {
    PostReactionType? reaction,
    bool wantToRead = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => PostEngagementUsersScreen(
          postId: post.id,
          title: wantToRead ? '「読みたい！」したユーザー' : '${reaction!.symbol}したユーザー',
          reaction: reaction,
          wantToRead: wantToRead,
          onProfileTap: (profile) {
            Navigator.of(routeContext).pop();
            widget.onProfileTap(profile.id);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final currentProfileId = Provider.of<SupabaseService>(
      context,
      listen: false,
    ).activeProfileId;
    return Container(
      height: 460,
      padding: const EdgeInsets.fromLTRB(10, 12, 6, 8),
      decoration: BoxDecoration(
        color: isDarkMode ? Colors.black : Colors.white,
        border: Border.all(color: isDarkMode ? Colors.white : Colors.black),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              'この本の投稿',
              style: TextStyle(
                color: isDarkMode ? Colors.white : Colors.black,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _posts.isEmpty
                ? Center(
                    child: Text(
                      'この本に関する投稿はまだありません。',
                      style: TextStyle(
                        color: isDarkMode ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(right: 8),
                    itemCount: _posts.length,
                    itemBuilder: (context, index) {
                      final post = _posts[index];
                      final isOwnPost = post.profileId == currentProfileId;
                      return PostCard(
                        key: ValueKey('profile-book-${post.id}'),
                        post: post,
                        replies: _replies[post.id] ?? const [],
                        concealSpoiler: !isOwnPost,
                        concealReplySpoiler: (reply) =>
                            reply.profileId != currentProfileId,
                        onUserTap: () => widget.onProfileTap(post.profileId),
                        onReaction: isOwnPost
                            ? null
                            : (reaction) => _toggleReaction(post, reaction),
                        onWantToRead: isOwnPost
                            ? null
                            : () => _toggleWantToRead(post),
                        onReactionUsers: (reaction) =>
                            _openEngagementUsers(post, reaction: reaction),
                        onWantToReadUsers: () =>
                            _openEngagementUsers(post, wantToRead: true),
                        onReport: isOwnPost
                            ? null
                            : () => widget.onReport(post.id),
                        onReply: (parentReply) async {
                          await widget.onReply(post, parentReply);
                        },
                        onReplyReport: widget.onReplyReport,
                        canReportReply: (reply) =>
                            currentProfileId.isEmpty ||
                            reply.profileId != currentProfileId,
                        onReplyUserTap: widget.onProfileTap,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _UserProfileScreenState extends State<UserProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _footerSearchController = TextEditingController();
  UserProfile? _profile;
  List<Post> _userPosts = [];
  Map<String, List<PostReply>> _postReplies = {};
  List<Book> _collections = [];
  List<Book> _favorites = [];
  List<Book> _wantToRead = [];
  int _favoriteLimit = SupabaseService.standardFavoriteLimit;
  List<Book> _searchResults = [];
  bool _isLoading = true;
  bool _isSearchPanelOpen = false;
  bool _isSearchingBooks = false;
  String? _searchError;
  ProfileRelationship? _relationship;
  bool _isSocialActionInProgress = false;
  final Set<String> _pendingReactionPostIds = <String>{};

  bool get _isOwnProfile => _relationship?.isOwnProfile ?? false;

  bool get _canViewProfileContent {
    final profile = _profile;
    final relationship = _relationship;
    if (profile == null || relationship == null) return false;
    if (relationship.isOwnProfile) return true;
    if (relationship.blockedEitherDirection) return false;
    return !profile.isPrivate ||
        relationship.followStatus == FollowRelationshipStatus.accepted;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadProfileData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _footerSearchController.dispose();
    super.dispose();
  }

  void _toggleSearchPanel() {
    setState(() {
      _isSearchPanelOpen = !_isSearchPanelOpen;
      if (!_isSearchPanelOpen) {
        _footerSearchController.clear();
        _searchResults = [];
        _searchError = null;
        _isSearchingBooks = false;
      }
    });
  }

  Future<void> _searchBooksFromFooter(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      setState(() {
        _searchResults = [];
        _searchError = null;
      });
      return;
    }

    setState(() {
      _isSearchingBooks = true;
      _searchError = null;
    });

    try {
      final service = Provider.of<SupabaseService>(context, listen: false);
      final allowAdultContent = await service.canViewAdultContent();
      final bookRepository = BookRepository(
        allowAdultContent: allowAdultContent,
      );
      final List<Book> merged = [];
      final primaryBooks = await bookRepository.searchBooks(keyword);
      merged.addAll(primaryBooks);

      // Fuzzy fallback: search by each token and merge results.
      final tokens = _tokenizeQuery(keyword);
      if (tokens.length > 1) {
        for (final token in tokens.take(3)) {
          final tokenBooks = await bookRepository.searchBooks(token);
          merged.addAll(tokenBooks);
        }
      }

      final books = _rankBooksByFuzzyScore(merged, keyword);
      if (!mounted) return;
      setState(() {
        _searchResults = books;
        _searchError = books.isEmpty ? '該当する本が見つかりませんでした。' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchError = '検索に失敗しました。しばらくしてから再試行してください。';
        _searchResults = [];
      });
    } finally {
      if (mounted) {
        setState(() => _isSearchingBooks = false);
      }
    }
  }

  List<String> _tokenizeQuery(String query) {
    return query
        .trim()
        .split(RegExp(r'\s+'))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
  }

  List<Book> _rankBooksByFuzzyScore(List<Book> books, String query) {
    final byId = <String, Book>{};
    for (final book in books) {
      byId[book.id] = book;
    }
    return BookRepository.rankSearchResults(
      byId.values,
      query,
    ).take(20).toList();
  }

  Future<void> _loadProfileData() async {
    setState(() => _isLoading = true);
    final service = Provider.of<SupabaseService>(context, listen: false);
    final uid = widget.profileId ?? service.activeProfileId;

    if (uid.isEmpty) {
      if (mounted) {
        setState(() {
          _profile = null;
          _userPosts = [];
          _postReplies = {};
          _collections = [];
          _favorites = [];
          _wantToRead = [];
          _isLoading = false;
        });
      }
      return;
    }

    final profile = await service.fetchUserProfile(uid);
    final profileId = profile.id;
    final relationship = await service.fetchProfileRelationship(profileId);
    final canLoadContent =
        relationship.isOwnProfile ||
        (!relationship.blockedEitherDirection &&
            (!profile.isPrivate ||
                relationship.followStatus ==
                    FollowRelationshipStatus.accepted));
    final posts = canLoadContent
        ? await service.fetchUserPosts(profileId)
        : <Post>[];
    final replies = canLoadContent
        ? await service.fetchRepliesForPosts(
            posts.map((post) => post.id).toList(growable: false),
          )
        : <String, List<PostReply>>{};
    final colls = canLoadContent
        ? await service.fetchUserCollections(profileId)
        : <Book>[];
    final favs = canLoadContent
        ? await service.fetchUserFavorites(profileId)
        : <Book>[];
    final wanted = canLoadContent
        ? await service.fetchUserWantToRead(profileId)
        : <Book>[];
    final favoriteLimit = relationship.isOwnProfile
        ? await service.fetchCurrentFavoriteLimit()
        : SupabaseService.standardFavoriteLimit;
    final postedBookIds = posts.map((post) => post.bookId).toSet();
    final visibleFavorites = favs
        .where((book) => postedBookIds.contains(book.id))
        .toList(growable: false);

    if (mounted) {
      setState(() {
        _profile = profile;
        _relationship = relationship;
        _userPosts = posts;
        _postReplies = replies;
        _collections = colls;
        _favorites = visibleFavorites;
        _wantToRead = wanted;
        _favoriteLimit = favoriteLimit;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    final profile = _profile;
    final relationship = _relationship;
    if (profile == null || relationship == null || relationship.isOwnProfile) {
      return;
    }

    final wasFollowing =
        relationship.followStatus != FollowRelationshipStatus.none;
    final optimisticStatus = wasFollowing
        ? FollowRelationshipStatus.none
        : profile.isPrivate
        ? FollowRelationshipStatus.pending
        : FollowRelationshipStatus.accepted;
    final followerDelta =
        relationship.followStatus == FollowRelationshipStatus.accepted
        ? -1
        : optimisticStatus == FollowRelationshipStatus.accepted
        ? 1
        : 0;

    setState(() {
      _isSocialActionInProgress = true;
      _relationship = relationship.copyWith(followStatus: optimisticStatus);
      _profile = profile.copyWith(
        followersCount: (profile.followersCount + followerDelta)
            .clamp(0, 1 << 31)
            .toInt(),
      );
    });
    final service = Provider.of<SupabaseService>(context, listen: false);
    final returnedStatus = wasFollowing
        ? null
        : await service.followProfile(profile.id);
    final success = wasFollowing
        ? await service.unfollowProfile(profile.id)
        : returnedStatus != null;
    if (!mounted) return;
    if (!success) {
      setState(() {
        _isSocialActionInProgress = false;
        _relationship = relationship;
        _profile = profile;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('フォロー設定を変更できませんでした。')));
      return;
    }
    setState(() {
      _isSocialActionInProgress = false;
      if (returnedStatus != null && returnedStatus != optimisticStatus) {
        _relationship = relationship.copyWith(followStatus: returnedStatus);
        final correctedDelta =
            returnedStatus == FollowRelationshipStatus.accepted ? 1 : 0;
        _profile = profile.copyWith(
          followersCount: (profile.followersCount + correctedDelta)
              .clamp(0, 1 << 31)
              .toInt(),
        );
      }
    });
  }

  Future<void> _toggleBlock() async {
    final profile = _profile;
    final relationship = _relationship;
    if (profile == null || relationship == null || relationship.isOwnProfile) {
      return;
    }

    if (!relationship.blockedByMe) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('このユーザーをブロックしますか？'),
          content: const Text('互いのフォローは解除され、投稿の表示、フォロー、リアクションが制限されます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('ブロック'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _isSocialActionInProgress = true);
    final service = Provider.of<SupabaseService>(context, listen: false);
    final success = relationship.blockedByMe
        ? await service.unblockProfile(profile.id)
        : await service.blockProfile(profile.id);
    if (!mounted) return;
    setState(() => _isSocialActionInProgress = false);
    if (!success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ブロック設定を変更できませんでした。')));
      return;
    }
    await _loadProfileData();
  }

  Future<void> _openFollowList({required bool followers}) async {
    final profile = _profile;
    final relationship = _relationship;
    if (profile == null || relationship == null) return;
    if (relationship.blockedEitherDirection) return;
    if (!relationship.isOwnProfile && profile.isPrivate) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('鍵アカウントのフォロー一覧は閲覧できません。')));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => FollowListScreen(
          profileId: profile.id,
          followers: followers,
          onProfileTap: (selectedProfile) {
            final openInMainShell = widget.onOpenProfile;
            if (openInMainShell != null) {
              Navigator.of(routeContext).pop();
              openInMainShell(selectedProfile.id);
              return;
            }
            Navigator.of(routeContext).push(
              MaterialPageRoute<void>(
                builder: (context) => UserProfileScreen(
                  profileId: selectedProfile.id,
                  onBack: () => Navigator.of(context).pop(),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!mounted) return;
    final refreshedProfile = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).fetchUserProfile(profile.id);
    if (mounted) setState(() => _profile = refreshedProfile);
  }

  Future<void> _toggleReaction(String postId, PostReactionType reaction) async {
    if (!_pendingReactionPostIds.add(postId)) return;

    final index = _userPosts.indexWhere((post) => post.id == postId);
    final previous = index < 0 ? null : _userPosts[index];
    if (previous != null) {
      setState(() {
        final updatedPosts = List<Post>.from(_userPosts);
        updatedPosts[index] = previous.withToggledReaction(reaction);
        _userPosts = updatedPosts;
      });
    }

    final service = Provider.of<SupabaseService>(context, listen: false);
    final success = await service.setPostReaction(postId, reaction);
    _pendingReactionPostIds.remove(postId);
    if (!mounted) return;

    if (!success && previous != null) {
      setState(() {
        final restoreIndex = _userPosts.indexWhere(
          (post) => post.id == previous.id,
        );
        if (restoreIndex < 0) return;
        final restoredPosts = List<Post>.from(_userPosts);
        restoredPosts[restoreIndex] = previous;
        _userPosts = restoredPosts;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('リアクションを更新できませんでした。')));
    }
  }

  Future<void> _toggleWantToReadFromPost(Post post) async {
    final pendingKey = 'want:${post.id}';
    if (!_pendingReactionPostIds.add(pendingKey)) return;
    final index = _userPosts.indexWhere((candidate) => candidate.id == post.id);
    final previous = index < 0 ? null : _userPosts[index];
    if (previous != null) {
      setState(() {
        final updated = List<Post>.from(_userPosts);
        updated[index] = previous.withToggledWantToRead();
        _userPosts = updated;
      });
    }
    final service = Provider.of<SupabaseService>(context, listen: false);
    final result = await service.toggleWantToRead(
      book: Book(
        id: post.bookId,
        title: post.bookTitle,
        author: post.bookAuthor,
        publisher: '',
        pubDate: '',
        isbn: post.bookId,
        coverUrl: post.bookCoverUrl,
      ),
      sourcePostId: post.id,
    );
    _pendingReactionPostIds.remove(pendingKey);
    if (!mounted) return;
    if (result.shouldRestoreOptimisticState && previous != null) {
      setState(() {
        final restoreIndex = _userPosts.indexWhere((p) => p.id == previous.id);
        if (restoreIndex >= 0) {
          final restored = List<Post>.from(_userPosts);
          restored[restoreIndex] = previous;
          _userPosts = restored;
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } else {
      final profileId = Provider.of<SupabaseService>(
        context,
        listen: false,
      ).activeProfileId;
      if (profileId.isNotEmpty) {
        _wantToRead = await service.fetchUserWantToRead(profileId);
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _openEngagementUsers(
    Post post, {
    PostReactionType? reaction,
    bool wantToRead = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => PostEngagementUsersScreen(
          postId: post.id,
          title: wantToRead ? '「読みたい！」したユーザー' : '${reaction!.symbol}したユーザー',
          reaction: reaction,
          wantToRead: wantToRead,
          onProfileTap: (profile) {
            Navigator.of(routeContext).pop();
            _openReplyProfile(profile.id);
          },
        ),
      ),
    );
  }

  Future<void> _reportPost(String postId) async {
    await showPostReportDialog(context: context, postId: postId);
  }

  Future<void> _reportReply(PostReply reply) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (!service.canWrite) {
      final result = await Navigator.of(context).pushNamed('/login');
      if (!mounted || (result != true && !service.canWrite)) return;
    }
    if (reply.profileId == service.activeProfileId) return;
    await showReplyReportDialog(context: context, replyId: reply.id);
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
    if (!mounted || !posted) return;
    await _loadProfileData();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('返信を投稿しました。')));
  }

  Future<void> _openReplyProfile(String profileId) async {
    final openInMainShell = widget.onOpenProfile;
    if (openInMainShell != null) {
      openInMainShell(profileId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => UserProfileScreen(
          profileId: profileId,
          onBack: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
  }

  void _showFavoriteResult(FavoriteToggleResult result) {
    final message = switch (result) {
      FavoriteToggleResult.added => 'お気に入りに登録しました。',
      FavoriteToggleResult.removed => 'お気に入りから解除しました。',
      FavoriteToggleResult.standardLimitReached =>
        '通常利用ではお気に入りは3冊までです。サブスクでは12冊まで登録できます。',
      FavoriteToggleResult.subscriberLimitReached =>
        'お気に入りは12冊までです。登録済みの本と入れ替えてください。',
      FavoriteToggleResult.requiresRead => '読了（投稿）した本のみお気に入りに追加できます。',
      FavoriteToggleResult.failed => 'お気に入りを更新できませんでした。',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isFavorited(String bookId) =>
      _favorites.any((book) => book.id == bookId);

  Future<void> _toggleFavorite(String bookId) async {
    if (!_isOwnProfile) return;
    final result = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).toggleFavorite(bookId);
    if (!mounted) return;
    _showFavoriteResult(result);
    if (result == FavoriteToggleResult.added ||
        result == FavoriteToggleResult.removed) {
      await _loadProfileData();
    }
  }

  Future<void> _deletePost(Post post) async {
    if (!_isOwnProfile) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('投稿を削除しますか？'),
        content: Text(
          '「${post.bookTitle}」の投稿を削除します。\n'
          'この本への投稿がほかにない場合、My 本棚からも削除されます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD00303),
            ),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final service = Provider.of<SupabaseService>(context, listen: false);
    final deleted = await service.deleteOwnPost(post.id);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('投稿を削除できませんでした。')));
      return;
    }
    await _loadProfileData();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('投稿を削除しました。')));
  }

  Future<void> _editPost(Post post) async {
    if (!_isOwnProfile) return;
    final book = Book(
      id: post.bookId,
      title: post.bookTitle,
      author: post.bookAuthor,
      publisher: '',
      pubDate: '',
      isbn: post.bookId,
      coverUrl: post.bookCoverUrl,
    );
    final edited = await showPostComposerDialog(
      context: context,
      book: book,
      existingPost: post,
    );
    if (edited && mounted) await _loadProfileData();
  }

  Future<void> _openBookSearch() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ProfileBookSearchScreen()),
    );
    if (posted == true && mounted) {
      await _loadProfileData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final profileHeaderColor = ProfilePageColors.colorFor(
      _profile?.pageColorKey,
    );
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              backgroundColor: isDarkMode ? Colors.black : Colors.white,
              foregroundColor: isDarkMode ? Colors.white : Colors.black,
              elevation: 0,
              shape: Border(
                bottom: BorderSide(color: profileHeaderColor, width: 3),
              ),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
              actions: _isOwnProfile
                  ? [
                      IconButton(
                        icon: const Icon(Icons.logout),
                        tooltip: 'ログアウト',
                        onPressed: () async {
                          final service = Provider.of<SupabaseService>(
                            context,
                            listen: false,
                          );
                          await service.signOut();
                          if (!mounted) return;
                          widget.onBack();
                        },
                      ),
                    ]
                  : null,
              title: Text(
                (_profile?.userId.isNotEmpty ?? false)
                    ? '@${_profile!.userId}'
                    : 'プロフィール',
                style: TextStyle(
                  color: profileHeaderColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              centerTitle: true,
            )
          : null,
      floatingActionButton: _profile == null || !_isOwnProfile
          ? null
          : FloatingActionButton(
              heroTag: 'addReadBookFromProfile',
              onPressed: _openBookSearch,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              shape: const CircleBorder(
                side: BorderSide(color: Colors.white24),
              ),
              tooltip: '読了した本を投稿',
              child: const Icon(Icons.add, size: 32),
            ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFD00303)),
            )
          : _profile == null
          ? const Center(child: Text('プロフィールの読み込みに失敗しました。')) // ⭕ データ未取得時の安全ガード
          : Container(
              width: double.infinity,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.black
                  : Colors.white,
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) => [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _buildProfileHeader(),
                        const SizedBox(height: 16),
                        if (_canViewProfileContent) _buildTabBar(),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ],
                body: _canViewProfileContent
                    ? TabBarView(
                        controller: _tabController,
                        children: [
                          _buildPostsTab(),
                          _buildGridTab(
                            _collections,
                            'My 本棚はありません。',
                            showDescription: true,
                            compactThreeColumn: true,
                          ),
                          _buildFavoritesTab(),
                          _buildGridTab(
                            _wantToRead,
                            '「読みたい！」作品はありません。',
                            showDescription: true,
                            compactThreeColumn: true,
                          ),
                        ],
                      )
                    : _buildPrivateOrBlockedState(),
              ),
            ),
    );
  }

  Widget _buildProfileHeader() {
    if (_profile == null) return const SizedBox.shrink();
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isDesktopLayout = MediaQuery.sizeOf(context).width >= 768;
    final avatarRadius = isDesktopLayout ? 80.0 : 40.0;
    final profileBackgroundColor = isDarkMode ? Colors.black : Colors.white;
    final profileTextColor = isDarkMode ? Colors.white : Colors.black;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: profileBackgroundColor,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            // Row containing avatar, username, ID, and stat fields
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Profile Photo
                CircleAvatar(
                  radius: avatarRadius,
                  backgroundImage: _profile!.avatarUrl.isNotEmpty
                      ? NetworkImage(_profile!.avatarUrl)
                      : null,
                  child: _profile!.avatarUrl.isEmpty
                      ? Icon(Icons.person, size: avatarRadius)
                      : null,
                ),
                const SizedBox(width: 16),

                // Name and Stats
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Username
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _profile!.username,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: isDesktopLayout ? 24 : 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (_profile!.isPrivate) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.lock, size: 16),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      // ⭕ 文字数が足りない場合の RangeError 回避
                      Text(
                        _profile!.userId.isNotEmpty
                            ? '@${_profile!.userId}'
                            : _profile!.id.length >= 8
                            ? '@${_profile!.id.substring(0, 8)}'
                            : '@${_profile!.id}',
                        style: TextStyle(
                          fontSize: isDesktopLayout ? 17 : 11,
                          color: Colors.grey[400],
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Stat counters row
                      Container(
                        padding: const EdgeInsets.all(8),
                        color: profileBackgroundColor,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildStatColumn(
                              '読了',
                              _profile!.readCount.toString(),
                            ),
                            _buildStatColumn(
                              'フォロワー',
                              _profile!.followersCount.toString(),
                              onTap: () => _openFollowList(followers: true),
                            ),
                            _buildStatColumn(
                              'フォロー',
                              _profile!.followingCount.toString(),
                              onTap: () => _openFollowList(followers: false),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            if (!_isOwnProfile) ...[
              const SizedBox(height: 14),
              _buildSocialActions(),
            ],

            const SizedBox(height: 16),

            if (_profile!.bio.isNotEmpty || _isOwnProfile)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: profileBackgroundColor,
                child: Text(
                  _profile!.bio.isNotEmpty ? _profile!.bio : '自己紹介はまだ登録されていません',
                  style: TextStyle(
                    fontSize: isDesktopLayout ? 18 : 12,
                    color: profileTextColor,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatColumn(String label, String count, {VoidCallback? onTap}) {
    final isDesktopLayout = MediaQuery.sizeOf(context).width >= 768;
    final textColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Column(
            children: [
              Text(
                count,
                style: TextStyle(
                  fontSize: isDesktopLayout ? 21 : 14,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: isDesktopLayout ? 20 : 10,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSocialActions() {
    final relationship = _relationship;
    if (relationship == null) return const SizedBox.shrink();

    if (relationship.blockedByThem) {
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.block, size: 18),
          SizedBox(width: 6),
          Text('このアカウントは利用できません。'),
        ],
      );
    }

    if (relationship.blockedByMe) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _isSocialActionInProgress ? null : _toggleBlock,
          icon: const Icon(Icons.lock_open),
          label: const Text('ブロックを解除'),
        ),
      );
    }

    final followLabel = switch (relationship.followStatus) {
      FollowRelationshipStatus.none => 'フォロー',
      FollowRelationshipStatus.pending => 'リクエスト済み',
      FollowRelationshipStatus.accepted => 'フォロー中',
    };
    final followIcon = switch (relationship.followStatus) {
      FollowRelationshipStatus.none => Icons.person_add_alt_1,
      FollowRelationshipStatus.pending => Icons.hourglass_top,
      FollowRelationshipStatus.accepted => Icons.person_remove_outlined,
    };
    final followingBackgroundColor =
        Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFF2F2F2)
        : Colors.black;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _isSocialActionInProgress ? null : _toggleFollow,
            icon: Icon(followIcon),
            label: Text(followLabel),
            style:
                relationship.followStatus == FollowRelationshipStatus.accepted
                ? FilledButton.styleFrom(
                    backgroundColor: followingBackgroundColor,
                    foregroundColor: const Color(0xFF00BFFF),
                    disabledBackgroundColor: followingBackgroundColor,
                    disabledForegroundColor: const Color(0xFF00BFFF),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _isSocialActionInProgress ? null : _toggleBlock,
          icon: const Icon(Icons.block, size: 18),
          label: const Text('ブロック'),
        ),
      ],
    );
  }

  Widget _buildPrivateOrBlockedState() {
    final relationship = _relationship;
    final blocked = relationship?.blockedEitherDirection ?? false;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(blocked ? Icons.block : Icons.lock, size: 52),
            const SizedBox(height: 14),
            Text(
              blocked ? 'このアカウントのコンテンツは表示できません。' : 'このアカウントは非公開です。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (!blocked) ...[
              const SizedBox(height: 8),
              const Text(
                'フォローリクエストが承認されると、投稿・My 本棚・お気に入り・「読みたい！」を確認できます。',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final tabBackgroundColor = isDarkMode
        ? const Color(0xFF424242)
        : const Color(0xFFBDBDBD);
    final selectedBackgroundColor = isDarkMode ? Colors.white : Colors.black;
    final selectedTextColor = isDarkMode ? Colors.black : Colors.white;
    final unselectedTextColor = isDarkMode ? Colors.white : Colors.black;
    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: tabBackgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: isMobile,
        tabAlignment: isMobile ? TabAlignment.start : null,
        labelPadding: EdgeInsets.zero,
        indicator: BoxDecoration(
          color: selectedBackgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        dividerHeight: 0,
        labelColor: selectedTextColor,
        unselectedLabelColor: unselectedTextColor,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 13,
        ),
        tabs: isMobile
            ? const [
                Tab(
                  child: SizedBox(width: 56, child: Center(child: Text('投稿'))),
                ),
                Tab(
                  child: SizedBox(
                    width: 74,
                    child: Center(child: Text('My 本棚')),
                  ),
                ),
                Tab(
                  child: SizedBox(
                    width: 100,
                    child: Center(child: Text('お気に入り')),
                  ),
                ),
                Tab(
                  child: SizedBox(
                    width: 94,
                    child: Center(child: Text('読みたい！')),
                  ),
                ),
              ]
            : const [
                Tab(text: '投稿'),
                Tab(text: 'My 本棚'),
                Tab(text: 'お気に入り'),
                Tab(text: '読みたい！'),
              ],
      ),
    );
  }

  Widget _buildPostsTab() {
    if (_userPosts.isEmpty) {
      return _buildEmptyState('投稿したレビューはありません。');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _userPosts.length,
      itemBuilder: (context, index) {
        // Hide user info header since profile context is clear
        final post = _userPosts[index];
        return PostCard(
          key: ValueKey(post.id),
          post: post,
          replies: _postReplies[post.id] ?? const [],
          showUserInfo: false,
          concealSpoiler: !_isOwnProfile,
          borderColor: ProfilePageColors.colorFor(_profile?.pageColorKey),
          onReaction: _isOwnProfile
              ? null
              : (reaction) => _toggleReaction(post.id, reaction),
          onWantToRead: _isOwnProfile
              ? null
              : () => _toggleWantToReadFromPost(post),
          onReactionUsers: (reaction) =>
              _openEngagementUsers(post, reaction: reaction),
          onWantToReadUsers: () => _openEngagementUsers(post, wantToRead: true),
          onDelete: _isOwnProfile ? () => _deletePost(post) : null,
          onEdit: _isOwnProfile ? () => _editPost(post) : null,
          onFavorite: _isOwnProfile ? () => _toggleFavorite(post.bookId) : null,
          favoriteLabel: _isFavorited(post.bookId) ? 'お気に入りから解除' : 'お気に入りに追加',
          onReport: _isOwnProfile ? null : () => _reportPost(post.id),
          onReply: (parentReply) => _replyToPost(post, parentReply),
          onReplyReport: _reportReply,
          concealReplySpoiler: (reply) {
            final profileId = Provider.of<SupabaseService>(
              context,
              listen: false,
            ).activeProfileId;
            return profileId.isEmpty || reply.profileId != profileId;
          },
          canReportReply: (reply) {
            final profileId = Provider.of<SupabaseService>(
              context,
              listen: false,
            ).activeProfileId;
            return profileId.isEmpty || reply.profileId != profileId;
          },
          onReplyUserTap: _openReplyProfile,
        );
      },
    );
  }

  Widget _buildGridTab(
    List<Book> booksList,
    String emptyMessage, {
    bool showDescription = false,
    bool compactThreeColumn = false,
  }) {
    if (booksList.isEmpty) {
      return _buildEmptyState(emptyMessage);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep three books per row, but size each card approximately like a
        // four-column grid so the bookshelf has comfortable side whitespace.
        final compactPadding = constraints.maxWidth * 0.125;
        final horizontalPadding = compactThreeColumn
            ? (compactPadding < 16 ? 16.0 : compactPadding)
            : 16.0;
        return GridView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 16,
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: booksList.length,
          itemBuilder: (context, index) {
            final book = booksList[index];
            return BookCard(
              book: book,
              width: double.infinity,
              height: 140,
              coverHeightRatio: showDescription ? (2 / 3) : (1 / 3),
              showDescription: showDescription,
              descriptionMaxLines: 3,
              onTap: () => _showSearchedBookDetailDialog(book),
            );
          },
        );
      },
    );
  }

  Widget _buildFavoritesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Text(
            _isOwnProfile
                ? '${_favorites.length}冊/$_favoriteLimit冊'
                : '${_favorites.length}冊',
            style: const TextStyle(
              color: Colors.black,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: _favorites.isEmpty
              ? _buildEmptyState('お気に入りの本はありません。')
              : _buildFavoriteBooksGrid(),
        ),
      ],
    );
  }

  Widget _buildFavoriteBooksGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactPadding = constraints.maxWidth * 0.125;
        final horizontalPadding = compactPadding < 16 ? 16.0 : compactPadding;
        return GridView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 16,
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: _favorites.length,
          itemBuilder: (context, index) {
            final book = _favorites[index];
            final matchingPosts = _userPosts.where(
              (post) => post.bookId == book.id,
            );
            final rating = matchingPosts.isEmpty
                ? 0.0
                : matchingPosts.first.rating;
            return GestureDetector(
              onTap: () => _showSearchedBookDetailDialog(book),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF00E5FF)
                        : const Color(0xFF00BFFF),
                    width: 2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      book.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey[300],
                        alignment: Alignment.center,
                        child: const Icon(Icons.book, size: 36),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.84),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 15,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Future-Atlas側のフッター検索案は、必要になったとき再利用できるよう保持する。
  // 現在の画面では、常時表示の右下＋ボタンから検索画面を開く。
  // ignore: unused_element
  Widget _buildFooterSearchPanel() {
    return SafeArea(
      top: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        height: _isSearchPanelOpen ? 310 : 74,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(top: BorderSide(color: Colors.grey[300]!)),
        ),
        child: _isSearchPanelOpen
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _footerSearchController,
                          textInputAction: TextInputAction.search,
                          onSubmitted: _searchBooksFromFooter,
                          decoration: InputDecoration(
                            hintText: '検索',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '検索',
                        onPressed: () => _searchBooksFromFooter(
                          _footerSearchController.text,
                        ),
                        icon: const Icon(Icons.search),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(child: _buildSearchResultContent()),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: CircleAvatar(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      radius: 20,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close, size: 30),
                        onPressed: _toggleSearchPanel,
                      ),
                    ),
                  ),
                ],
              )
            : Align(
                alignment: Alignment.bottomRight,
                child: CircleAvatar(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  radius: 20,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add, size: 34),
                    onPressed: _toggleSearchPanel,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildSearchResultContent() {
    if (_isSearchingBooks) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFD00303)),
      );
    }

    if (_searchError != null) {
      return Center(
        child: Text(
          _searchError!,
          style: TextStyle(color: Colors.grey[700], fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          '本のタイトルや著者名を入力してください。',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      itemCount: _searchResults.length,
      separatorBuilder: (_, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final book = _searchResults[index];
        return _buildSearchResultCard(book);
      },
    );
  }

  Widget _buildSearchResultCard(Book book) {
    final service = Provider.of<SupabaseService>(context, listen: false);

    return InkWell(
      onTap: () => _showSearchedBookDetailDialog(book),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black54, width: 1),
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).cardColor,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 62,
              height: 96,
              color: Colors.grey[300],
              child: book.coverUrl.trim().isNotEmpty
                  ? Image.network(
                      book.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.menu_book, color: Colors.black54),
                    )
                  : const Icon(Icons.menu_book, color: Colors.black54),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: FutureBuilder<bool>(
                      future: service.isBookReadByCurrentUser(bookId: book.id),
                      builder: (context, snapshot) {
                        final isRead = snapshot.data ?? false;
                        return SizedBox(
                          height: 34,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: const Color(0xFFFF1F1F),
                              disabledBackgroundColor: Colors.black,
                              disabledForegroundColor: const Color(0xFF00BFFF),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                            ),
                            onPressed: isRead
                                ? null
                                : () => _showSearchedBookDetailDialog(book),
                            child: Text(isRead ? '読了済み' : '読了'),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      ...List.generate(5, (i) {
                        final filled = i < book.ratingAvg.floor();
                        return Icon(
                          filled ? Icons.star : Icons.star_border,
                          size: 18,
                          color: const Color(0xFFE0B400),
                        );
                      }),
                      const SizedBox(width: 6),
                      Text(
                        book.ratingAvg.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFFE0B400),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    book.description.trim().isEmpty
                        ? 'あらすじ情報はまだ登録されていません。'
                        : book.description,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSearchedBookDetailDialog(Book book) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final isReadFuture = service.isBookReadByCurrentUser(bookId: book.id);
    final isWantedFuture = service.isBookWantedByCurrentUser(book.id);
    final postsFuture = () async {
      final posts = await service.fetchPostsForBook(book.id);
      final replies = await service.fetchRepliesForPosts(
        posts.map((post) => post.id).toList(growable: false),
      );
      return (posts: posts, replies: replies);
    }();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        final narrow = MediaQuery.sizeOf(dialogContext).width < 600;
        return Dialog(
          backgroundColor: const Color(0xFFE6E6E6),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 920,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Color(0xFF1E1E1E)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (book.coverUrl.trim().isNotEmpty)
                        Center(
                          child: SizedBox(
                            height: narrow ? 220 : 300,
                            child: Image.network(
                              book.coverUrl,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.menu_book,
                                size: 64,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        book.title.trim().isEmpty ? 'タイトル不明' : book.title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(book.author.trim().isEmpty ? '著者不明' : book.author),
                      const SizedBox(height: 3),
                      Text(
                        book.publisher.trim().isEmpty
                            ? '出版社不明'
                            : book.publisher,
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 12),
                      FutureBuilder<bool>(
                        future: isReadFuture,
                        builder: (context, snapshot) {
                          final isRead = snapshot.data ?? false;
                          final checking =
                              snapshot.connectionState ==
                              ConnectionState.waiting;
                          return Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: isRead || checking
                                      ? null
                                      : () async {
                                          Navigator.of(dialogContext).pop();
                                          final posted =
                                              await showPostComposerDialog(
                                                context: this.context,
                                                book: book,
                                              );
                                          if (posted && mounted) {
                                            await _loadProfileData();
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.black,
                                    foregroundColor: const Color(0xFFFF1F1F),
                                    disabledBackgroundColor: Colors.black,
                                    disabledForegroundColor: const Color(
                                      0xFF00BFFF,
                                    ),
                                  ),
                                  child: Text(isRead ? '読了済み' : '読了'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FutureBuilder<bool>(
                                  future: isWantedFuture,
                                  builder: (context, wantedSnapshot) {
                                    final wanted = wantedSnapshot.data ?? false;
                                    final checking =
                                        wantedSnapshot.connectionState ==
                                        ConnectionState.waiting;
                                    return ElevatedButton(
                                      onPressed: checking
                                          ? null
                                          : () async {
                                              final result = await service
                                                  .toggleWantToRead(book: book);
                                              if (!mounted) return;
                                              ScaffoldMessenger.of(
                                                this.context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(result.message),
                                                ),
                                              );
                                              if (!result
                                                      .shouldRestoreOptimisticState &&
                                                  dialogContext.mounted) {
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop();
                                              }
                                            },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.amber,
                                      ),
                                      child: Text(wanted ? '読みたい！済み' : '読みたい！'),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: const Color(0xFFD8D8D8),
                        child: SizedBox(
                          height: narrow ? 160 : 220,
                          child: Scrollbar(
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              child: Text(
                                book.description.trim().isEmpty
                                    ? 'あらすじ情報はまだ登録されていません。'
                                    : book.description,
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _ProfileBookPostsPanel(
                        postsFuture: postsFuture,
                        onProfileTap: _openReplyProfile,
                        onReply: _replyToPost,
                        onReport: _reportPost,
                        onReplyReport: _reportReply,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('閉じる'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }
}
