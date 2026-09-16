enum FollowRelationshipStatus { none, pending, accepted }

enum PostReactionType {
  like('like', '👍'),
  love('love', '♥'),
  sad('sad', '😢');

  const PostReactionType(this.databaseValue, this.symbol);

  final String databaseValue;
  final String symbol;

  static PostReactionType? fromDatabase(String? value) {
    for (final type in values) {
      if (type.databaseValue == value) return type;
    }
    return null;
  }
}

class ProfileRelationship {
  const ProfileRelationship({
    required this.isOwnProfile,
    required this.followStatus,
    required this.blockedByMe,
    required this.blockedEitherDirection,
  });

  final bool isOwnProfile;
  final FollowRelationshipStatus followStatus;
  final bool blockedByMe;
  final bool blockedEitherDirection;

  bool get blockedByThem => blockedEitherDirection && !blockedByMe;

  ProfileRelationship copyWith({
    bool? isOwnProfile,
    FollowRelationshipStatus? followStatus,
    bool? blockedByMe,
    bool? blockedEitherDirection,
  }) {
    return ProfileRelationship(
      isOwnProfile: isOwnProfile ?? this.isOwnProfile,
      followStatus: followStatus ?? this.followStatus,
      blockedByMe: blockedByMe ?? this.blockedByMe,
      blockedEitherDirection:
          blockedEitherDirection ?? this.blockedEitherDirection,
    );
  }
}

enum SocialNotificationType {
  reaction,
  wantToRead,
  wantToReadCompleted,
  reply,
  follow,
  followRequest,
  newPost,
}

class SocialNotification {
  const SocialNotification({
    required this.id,
    required this.type,
    required this.actorId,
    required this.actorUsername,
    required this.actorUserId,
    required this.actorAvatarUrl,
    required this.postId,
    required this.replyId,
    required this.bookId,
    required this.bookTitle,
    required this.isRead,
    required this.followRequestPending,
    required this.createdAt,
  });

  final int id;
  final SocialNotificationType type;
  final String actorId;
  final String actorUsername;
  final String actorUserId;
  final String actorAvatarUrl;
  final String? postId;
  final String? replyId;
  final String? bookId;
  final String? bookTitle;
  final bool isRead;
  final bool followRequestPending;
  final DateTime createdAt;

  SocialNotification copyWith({
    String? bookTitle,
    bool? isRead,
    bool? followRequestPending,
  }) {
    return SocialNotification(
      id: id,
      type: type,
      actorId: actorId,
      actorUsername: actorUsername,
      actorUserId: actorUserId,
      actorAvatarUrl: actorAvatarUrl,
      postId: postId,
      replyId: replyId,
      bookId: bookId,
      bookTitle: bookTitle ?? this.bookTitle,
      isRead: isRead ?? this.isRead,
      followRequestPending: followRequestPending ?? this.followRequestPending,
      createdAt: createdAt,
    );
  }
}
