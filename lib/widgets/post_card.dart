import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../models/post.dart';
import '../models/post_reply.dart';
import '../models/social_models.dart';
import '../models/profile_page_color.dart';

class PostCard extends StatefulWidget {
  final Post post;
  final bool showUserInfo;
  final VoidCallback? onUserTap;
  final Future<void> Function(PostReactionType reaction)? onReaction;
  final Future<void> Function()? onWantToRead;
  final ValueChanged<PostReactionType>? onReactionUsers;
  final VoidCallback? onWantToReadUsers;
  final VoidCallback? onReport;
  final VoidCallback? onFavorite;
  final String favoriteLabel;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<PostReply?>? onReply;
  final ValueChanged<PostReply>? onReplyReport;
  final bool Function(PostReply reply)? canReportReply;
  final bool Function(PostReply reply)? concealReplySpoiler;
  final ValueChanged<String>? onReplyUserTap;
  final List<PostReply> replies;
  final String? highlightedReplyId;
  final bool concealSpoiler;
  final Color? borderColor;

  const PostCard({
    super.key,
    required this.post,
    this.showUserInfo = true,
    this.onUserTap,
    this.onReaction,
    this.onWantToRead,
    this.onReactionUsers,
    this.onWantToReadUsers,
    this.onReport,
    this.onFavorite,
    this.favoriteLabel = 'お気に入りに追加／解除',
    this.onEdit,
    this.onDelete,
    this.onReply,
    this.onReplyReport,
    this.canReportReply,
    this.concealReplySpoiler,
    this.onReplyUserTap,
    this.replies = const [],
    this.highlightedReplyId,
    this.concealSpoiler = true,
    this.borderColor,
  });

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _spoilerRevealed = false;
  bool _spoilerManuallyHidden = false;
  bool _wasVisible = true;
  ScrollPosition? _scrollPosition;
  final Map<String, GlobalKey> _replyKeys = <String, GlobalKey>{};
  final Set<String> _revealedReplySpoilerIds = <String>{};

  Post get post => widget.post;
  bool get showUserInfo => widget.showUserInfo;
  VoidCallback? get onUserTap => widget.onUserTap;
  Future<void> Function(PostReactionType reaction)? get onReaction =>
      widget.onReaction;
  Future<void> Function()? get onWantToRead => widget.onWantToRead;
  VoidCallback? get onReport => widget.onReport;
  VoidCallback? get onFavorite => widget.onFavorite;
  VoidCallback? get onEdit => widget.onEdit;
  VoidCallback? get onDelete => widget.onDelete;
  ValueChanged<PostReply?>? get onReply => widget.onReply;
  ValueChanged<PostReply>? get onReplyReport => widget.onReplyReport;
  ValueChanged<String>? get onReplyUserTap => widget.onReplyUserTap;
  List<PostReply> get replies => widget.replies;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (!identical(_scrollPosition, nextPosition)) {
      _scrollPosition?.removeListener(_handleScroll);
      _scrollPosition = nextPosition;
      _scrollPosition?.addListener(_handleScroll);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateVisibility());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToHighlightedReply(),
    );
  }

  @override
  void didUpdateWidget(covariant PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id ||
        oldWidget.concealSpoiler != widget.concealSpoiler) {
      _spoilerRevealed = false;
      _spoilerManuallyHidden = false;
      _revealedReplySpoilerIds.clear();
    } else if (oldWidget.replies != widget.replies) {
      final currentReplyIds = widget.replies.map((reply) => reply.id).toSet();
      _revealedReplySpoilerIds.removeWhere(
        (replyId) => !currentReplyIds.contains(replyId),
      );
    }
    if (oldWidget.highlightedReplyId != widget.highlightedReplyId ||
        oldWidget.replies.length != widget.replies.length) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHighlightedReply(),
      );
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_handleScroll);
    super.dispose();
  }

  void _handleScroll() => _updateVisibility();

  void _scrollToHighlightedReply() {
    final replyId = widget.highlightedReplyId;
    if (!mounted || replyId == null) return;
    final targetContext = _replyKeys[replyId]?.currentContext;
    if (targetContext == null) return;
    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.45,
    );
  }

  void _updateVisibility() {
    if (!mounted || (!post.hasSpoiler && replies.every((r) => !r.hasSpoiler))) {
      return;
    }
    final item = context.findRenderObject();
    if (item is! RenderBox || !item.attached) return;
    final abstractViewport = RenderAbstractViewport.maybeOf(item);
    if (abstractViewport == null || abstractViewport is! RenderBox) return;
    final viewport = abstractViewport as RenderBox;
    if (!viewport.attached) return;

    final itemOffset = item.localToGlobal(Offset.zero, ancestor: viewport);
    final isVisible =
        itemOffset.dy < viewport.size.height &&
        itemOffset.dy + item.size.height > 0;

    if (isVisible && !_wasVisible) {
      if (_spoilerRevealed ||
          _spoilerManuallyHidden ||
          _revealedReplySpoilerIds.isNotEmpty) {
        setState(() {
          _spoilerRevealed = false;
          _spoilerManuallyHidden = false;
          _revealedReplySpoilerIds.clear();
        });
      }
    }
    _wasVisible = isVisible;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primaryTextColor = colorScheme.onSurface;
    final secondaryTextColor = colorScheme.onSurface.withValues(alpha: 0.72);
    final tertiaryTextColor = colorScheme.onSurface.withValues(alpha: 0.58);
    final spoilerIsHidden =
        post.hasSpoiler &&
        ((widget.concealSpoiler && !_spoilerRevealed) ||
            _spoilerManuallyHidden);

    if (MediaQuery.sizeOf(context).width < 600) {
      return _buildMobileCard(
        context,
        theme,
        primaryTextColor,
        secondaryTextColor,
        tertiaryTextColor,
        spoilerIsHidden,
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              widget.borderColor ??
              ProfilePageColors.colorFor(post.profilePageColorKey),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // User Header (for Home Timeline)
            if (showUserInfo) ...[
              InkWell(
                onTap: onUserTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundImage: post.userAvatarUrl.isNotEmpty
                            ? NetworkImage(post.userAvatarUrl)
                            : null,
                        radius: 18,
                        child: post.userAvatarUrl.isEmpty
                            ? const Icon(Icons.person, size: 18)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post.username,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: primaryTextColor,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 24, thickness: 0.8),
            ],

            // Book and review body
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Book Cover
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    post.bookCoverUrl,
                    width: 70,
                    height: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 70,
                      height: 100,
                      color: Colors.grey[300],
                      child: const Icon(Icons.book, color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // Review Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Book Title / Author
                      Text(
                        post.bookTitle,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: primaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        post.bookAuthor,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Rating Stars
                      Row(
                        children: [
                          _buildStars(post.rating),
                          const SizedBox(width: 8),
                          Text(
                            '${post.rating.toStringAsFixed(1)} / 5.0',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.amber,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Review text
                      if (post.hasSpoiler) ...[
                        const Text(
                          'ネタバレあり',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (spoilerIsHidden)
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _spoilerRevealed = true;
                              _spoilerManuallyHidden = false;
                            });
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: primaryTextColor,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            alignment: Alignment.centerLeft,
                          ),
                          child: const Text(
                            '感想を読む',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        )
                      else ...[
                        Text(
                          post.reviewText,
                          style: TextStyle(
                            color: primaryTextColor,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        if (post.hasSpoiler)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _spoilerRevealed = false;
                                _spoilerManuallyHidden = true;
                              });
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: primaryTextColor,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 32),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              alignment: Alignment.centerLeft,
                            ),
                            child: const Text(
                              '感想を隠す',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                      ],

                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (post.isEdited) ...[
                              Text(
                                '編集済み',
                                style: TextStyle(
                                  color: tertiaryTextColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              _formatDate(post.createdAt),
                              style: TextStyle(
                                color: tertiaryTextColor,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _buildWantToReadButton(tertiaryTextColor),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          for (final reaction in PostReactionType.values) ...[
                            _buildReactionButton(
                              context,
                              reaction,
                              tertiaryTextColor,
                            ),
                            const SizedBox(width: 4),
                          ],
                          const Spacer(),
                          if (onFavorite != null ||
                              onEdit != null ||
                              onDelete != null)
                            PopupMenuButton<String>(
                              tooltip: '投稿メニュー',
                              icon: Icon(
                                Icons.more_vert,
                                size: 22,
                                color: tertiaryTextColor,
                              ),
                              padding: EdgeInsets.zero,
                              position: PopupMenuPosition.under,
                              onSelected: (value) {
                                if (value == 'favorite') onFavorite?.call();
                                if (value == 'edit') onEdit?.call();
                                if (value == 'delete') onDelete?.call();
                              },
                              itemBuilder: (context) => [
                                if (onFavorite != null)
                                  PopupMenuItem<String>(
                                    value: 'favorite',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.favorite_border,
                                          size: 19,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(widget.favoriteLabel),
                                      ],
                                    ),
                                  ),
                                if (onEdit != null)
                                  const PopupMenuItem<String>(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit_outlined, size: 19),
                                        SizedBox(width: 8),
                                        Text('編集'),
                                      ],
                                    ),
                                  ),
                                if (onDelete != null)
                                  const PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                          size: 19,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          '投稿削除',
                                          style: TextStyle(color: Colors.red),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          if (onReply != null)
                            TextButton.icon(
                              onPressed: () => onReply!(null),
                              icon: const Icon(Icons.reply_outlined, size: 16),
                              label: Text('返信 ${replies.length}'),
                              style: TextButton.styleFrom(
                                foregroundColor: tertiaryTextColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                minimumSize: const Size(0, 34),
                              ),
                            ),
                          if (onReport != null)
                            TextButton.icon(
                              onPressed: onReport,
                              icon: const Icon(Icons.flag_outlined, size: 16),
                              label: const Text('報告'),
                              style: TextButton.styleFrom(
                                foregroundColor: tertiaryTextColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                minimumSize: const Size(0, 34),
                              ),
                            ),
                        ],
                      ),
                      if (replies.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: tertiaryTextColor.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '返信',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              for (final reply in _rootReplies())
                                _buildReplyThread(
                                  context,
                                  reply,
                                  primaryTextColor,
                                  tertiaryTextColor,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileCard(
    BuildContext context,
    ThemeData theme,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color tertiaryTextColor,
    bool spoilerIsHidden,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              widget.borderColor ??
              ProfilePageColors.colorFor(post.profilePageColorKey),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showUserInfo) ...[
              InkWell(
                onTap: onUserTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundImage: post.userAvatarUrl.isNotEmpty
                            ? NetworkImage(post.userAvatarUrl)
                            : null,
                        radius: 18,
                        child: post.userAvatarUrl.isEmpty
                            ? const Icon(Icons.person, size: 18)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          post.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: primaryTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 24, thickness: 0.8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    post.bookCoverUrl,
                    width: 76,
                    height: 108,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 76,
                      height: 108,
                      color: Colors.grey[300],
                      child: const Icon(Icons.book, color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.bookTitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: primaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        post.bookAuthor,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                _buildStars(post.rating),
                Text(
                  '${post.rating.toStringAsFixed(1)} / 5.0',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Colors.amber,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (post.hasSpoiler) ...[
              const Text(
                'ネタバレあり',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (spoilerIsHidden)
              TextButton(
                onPressed: () {
                  setState(() {
                    _spoilerRevealed = true;
                    _spoilerManuallyHidden = false;
                  });
                },
                style: TextButton.styleFrom(
                  foregroundColor: primaryTextColor,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  alignment: Alignment.centerLeft,
                ),
                child: const Text(
                  '感想を読む',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              )
            else ...[
              Text(
                post.reviewText,
                style: TextStyle(
                  color: primaryTextColor,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              if (post.hasSpoiler)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _spoilerRevealed = false;
                      _spoilerManuallyHidden = true;
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: primaryTextColor,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                  ),
                  child: const Text(
                    '感想を隠す',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (post.isEdited)
                    Text(
                      '編集済み',
                      style: TextStyle(
                        color: tertiaryTextColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    _formatDate(post.createdAt),
                    style: TextStyle(color: tertiaryTextColor, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (onReply != null || onReport != null) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 0,
                  children: [
                    if (onReply != null)
                      TextButton.icon(
                        onPressed: () => onReply!(null),
                        icon: const Icon(Icons.reply_outlined, size: 16),
                        label: Text('返信 ${replies.length}'),
                        style: TextButton.styleFrom(
                          foregroundColor: tertiaryTextColor,
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    if (onReport != null)
                      TextButton.icon(
                        onPressed: onReport,
                        icon: const Icon(Icons.flag_outlined, size: 16),
                        label: const Text('報告'),
                        style: TextButton.styleFrom(
                          foregroundColor: tertiaryTextColor,
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _buildWantToReadButton(tertiaryTextColor),
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                return Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final reaction in PostReactionType.values)
                          _buildReactionButton(
                            context,
                            reaction,
                            tertiaryTextColor,
                          ),
                      ],
                    ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 0,
                      runSpacing: 0,
                      children: [
                        if (onFavorite != null ||
                            onEdit != null ||
                            onDelete != null)
                          _buildPostMenu(tertiaryTextColor),
                      ],
                    ),
                  ],
                );
              },
            ),
            if (replies.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildRepliesPanel(context, primaryTextColor, tertiaryTextColor),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPostMenu(Color tertiaryTextColor) {
    return PopupMenuButton<String>(
      tooltip: '投稿メニュー',
      icon: Icon(Icons.more_vert, size: 22, color: tertiaryTextColor),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == 'favorite') onFavorite?.call();
        if (value == 'edit') onEdit?.call();
        if (value == 'delete') onDelete?.call();
      },
      itemBuilder: (context) => [
        if (onFavorite != null)
          PopupMenuItem<String>(
            value: 'favorite',
            child: Row(
              children: [
                const Icon(Icons.favorite_border, size: 19),
                const SizedBox(width: 8),
                Text(widget.favoriteLabel),
              ],
            ),
          ),
        if (onEdit != null)
          const PopupMenuItem<String>(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit_outlined, size: 19),
                SizedBox(width: 8),
                Text('編集'),
              ],
            ),
          ),
        if (onDelete != null)
          const PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: Colors.red, size: 19),
                SizedBox(width: 8),
                Text('投稿削除', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRepliesPanel(
    BuildContext context,
    Color primaryTextColor,
    Color tertiaryTextColor,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tertiaryTextColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '返信',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final reply in _rootReplies())
            _buildReplyThread(
              context,
              reply,
              primaryTextColor,
              tertiaryTextColor,
            ),
        ],
      ),
    );
  }

  List<PostReply> _rootReplies() {
    final ids = replies.map((reply) => reply.id).toSet();
    return replies
        .where(
          (reply) =>
              reply.parentReplyId == null || !ids.contains(reply.parentReplyId),
        )
        .toList(growable: false);
  }

  List<PostReply> _childReplies(String parentReplyId) => replies
      .where((reply) => reply.parentReplyId == parentReplyId)
      .toList(growable: false);

  Widget _buildReplyThread(
    BuildContext context,
    PostReply reply,
    Color primaryTextColor,
    Color tertiaryTextColor, {
    int depth = 0,
  }) {
    final highlighted = widget.highlightedReplyId == reply.id;
    final profileLabel = reply.userId.isEmpty ? '' : '@${reply.userId}';
    final children = _childReplies(reply.id);
    final safeDepth = depth.clamp(0, 3).toDouble();
    final replyKey = _replyKeys.putIfAbsent(reply.id, GlobalKey.new);
    final shouldConcealSpoiler =
        reply.hasSpoiler && (widget.concealReplySpoiler?.call(reply) ?? true);
    final replySpoilerRevealed =
        !shouldConcealSpoiler || _revealedReplySpoilerIds.contains(reply.id);

    return Padding(
      padding: EdgeInsets.only(left: safeDepth * 14.0, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            key: replyKey,
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: highlighted
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.55)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: depth > 0
                  ? Border(
                      left: BorderSide(
                        color: tertiaryTextColor.withValues(alpha: 0.35),
                        width: 2,
                      ),
                    )
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: onReplyUserTap == null
                      ? null
                      : () => onReplyUserTap!(reply.profileId),
                  customBorder: const CircleBorder(),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundImage: reply.userAvatarUrl.isNotEmpty
                        ? NetworkImage(reply.userAvatarUrl)
                        : null,
                    child: reply.userAvatarUrl.isEmpty
                        ? const Icon(Icons.person, size: 17)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: onReplyUserTap == null
                            ? null
                            : () => onReplyUserTap!(reply.profileId),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          children: [
                            Text(
                              reply.username,
                              style: TextStyle(
                                color: primaryTextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (profileLabel.isNotEmpty)
                              Text(
                                profileLabel,
                                style: TextStyle(
                                  color: tertiaryTextColor,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (reply.hasSpoiler)
                        const Text(
                          'ネタバレあり',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (shouldConcealSpoiler && !replySpoilerRevealed)
                        TextButton(
                          onPressed: () {
                            setState(
                              () => _revealedReplySpoilerIds.add(reply.id),
                            );
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('返信を読む'),
                        )
                      else ...[
                        Text(
                          reply.message,
                          style: TextStyle(
                            color: primaryTextColor,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                        if (shouldConcealSpoiler)
                          TextButton(
                            onPressed: () {
                              setState(
                                () => _revealedReplySpoilerIds.remove(reply.id),
                              );
                            },
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('返信を隠す'),
                          ),
                      ],
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            _formatDate(reply.createdAt),
                            style: TextStyle(
                              color: tertiaryTextColor,
                              fontSize: 9,
                            ),
                          ),
                          if (onReply != null) ...[
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () => onReply!(reply),
                              style: TextButton.styleFrom(
                                foregroundColor: tertiaryTextColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                minimumSize: const Size(0, 26),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '返信',
                                style: TextStyle(fontSize: 10),
                              ),
                            ),
                          ],
                          if (onReplyReport != null &&
                              (widget.canReportReply?.call(reply) ?? true)) ...[
                            const SizedBox(width: 4),
                            TextButton.icon(
                              onPressed: () => onReplyReport!(reply),
                              style: TextButton.styleFrom(
                                foregroundColor: tertiaryTextColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                minimumSize: const Size(0, 26),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.flag_outlined, size: 13),
                              label: const Text(
                                '報告',
                                style: TextStyle(fontSize: 10),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final child in children)
            _buildReplyThread(
              context,
              child,
              primaryTextColor,
              tertiaryTextColor,
              depth: depth + 1,
            ),
        ],
      ),
    );
  }

  Widget _buildReactionButton(
    BuildContext context,
    PostReactionType reaction,
    Color inactiveColor,
  ) {
    final selected = post.currentUserReaction == reaction;
    final count = post.reactionCounts[reaction] ?? 0;
    final selectedColor = reaction == PostReactionType.love
        ? Colors.red
        : Theme.of(context).colorScheme.primary;

    void showUsers() => widget.onReactionUsers?.call(reaction);
    return InkWell(
      onTap: onReaction != null
          ? () async => onReaction!(reaction)
          : widget.onReactionUsers != null
          ? showUsers
          : null,
      onLongPress: widget.onReactionUsers == null ? null : showUsers,
      onSecondaryTap: widget.onReactionUsers == null ? null : showUsers,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        constraints: const BoxConstraints(minWidth: 42, minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? selectedColor.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? selectedColor.withValues(alpha: 0.55)
                : inactiveColor.withValues(alpha: 0.22),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              reaction.symbol,
              style: TextStyle(
                fontSize: 17,
                color: reaction == PostReactionType.love ? Colors.red : null,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: selected ? selectedColor : inactiveColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWantToReadButton(Color inactiveColor) {
    final selected = post.wantedByCurrentUser;
    void showUsers() => widget.onWantToReadUsers?.call();
    return InkWell(
      onTap: onWantToRead != null
          ? () async => onWantToRead!()
          : widget.onWantToReadUsers != null
          ? showUsers
          : null,
      onLongPress: widget.onWantToReadUsers == null ? null : showUsers,
      onSecondaryTap: widget.onWantToReadUsers == null ? null : showUsers,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? Colors.amber
                : inactiveColor.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.bookmark_add_outlined,
              color: Colors.amber,
              size: 17,
            ),
            const SizedBox(width: 5),
            const Text(
              '読みたい！',
              style: TextStyle(
                color: Colors.amber,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (post.wantToReadCount > 0) ...[
              const SizedBox(width: 5),
              Text(
                '${post.wantToReadCount}',
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStars(double rating) {
    List<Widget> stars = [];
    int fullStars = rating.floor();
    bool hasHalfStar = (rating - fullStars) >= 0.5;

    for (int i = 0; i < 5; i++) {
      if (i < fullStars) {
        stars.add(const Icon(Icons.star, color: Colors.amber, size: 14));
      } else if (i == fullStars && hasHalfStar) {
        stars.add(const Icon(Icons.star_half, color: Colors.amber, size: 14));
      } else {
        stars.add(Icon(Icons.star_border, color: Colors.grey[400], size: 14));
      }
    }
    return Row(children: stars);
  }

  String _formatDate(DateTime date) {
    return '${date.year}年${date.month}月${date.day}日';
  }
}
