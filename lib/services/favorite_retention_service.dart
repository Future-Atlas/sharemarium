import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/book.dart';
import '../utils/dev_logger.dart';

class FavoriteRetentionState {
  const FavoriteRetentionState({
    required this.effectivePlan,
    required this.favoriteLimit,
    required this.totalCount,
    required this.effectiveVisibleCount,
    required this.selectionRequired,
  });

  final String effectivePlan;
  final int favoriteLimit;
  final int totalCount;
  final int effectiveVisibleCount;
  final bool selectionRequired;

  bool get isUnlimited => favoriteLimit >= 2147483647;
  bool get isPremium => effectivePlan == 'premium';

  factory FavoriteRetentionState.fromJson(Map<String, dynamic> json) {
    int parseInt(Object? value) => value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;

    return FavoriteRetentionState(
      effectivePlan: json['effective_plan']?.toString() ?? 'free',
      favoriteLimit: parseInt(json['favorite_limit']),
      totalCount: parseInt(json['total_count']),
      effectiveVisibleCount: parseInt(json['effective_visible_count']),
      selectionRequired: json['selection_required'] == true,
    );
  }
}

class FavoriteRetentionCandidate {
  const FavoriteRetentionCandidate({
    required this.book,
    required this.isSelected,
  });

  final Book book;
  final bool isSelected;
}

class FavoriteRetentionService {
  FavoriteRetentionService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static bool get isAuthenticated => _client.auth.currentUser != null;

  static Future<FavoriteRetentionState?> fetchState() async {
    if (!isAuthenticated) return null;
    try {
      final response = await _client.rpc(
        'current_user_favorite_retention_state',
      );
      final rows = response is List<dynamic> ? response : <dynamic>[response];
      final row = rows.whereType<Map<String, dynamic>>().firstOrNull;
      return row == null ? null : FavoriteRetentionState.fromJson(row);
    } catch (error) {
      debugLog('Error fetching favorite retention state: $error');
      return null;
    }
  }

  static Future<List<FavoriteRetentionCandidate>> fetchCandidates() async {
    if (!isAuthenticated) return const [];
    try {
      final response = await _client.rpc(
        'current_user_favorite_retention_candidates',
      );
      final rows = (response as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      return rows
          .map((row) {
            final bookId = row['book_id']?.toString().trim() ?? '';
            if (bookId.isEmpty) return null;
            return FavoriteRetentionCandidate(
              book: Book(
                id: bookId,
                title: row['book_title']?.toString().trim().isNotEmpty == true
                    ? row['book_title'].toString().trim()
                    : bookId,
                author: row['book_author']?.toString() ?? '',
                publisher: '',
                pubDate: '',
                isbn: bookId,
                coverUrl: row['book_cover_url']?.toString() ?? '',
                ratingAvg: 0,
                genre: '',
                description: '',
              ),
              isSelected: row['is_selected'] == true,
            );
          })
          .whereType<FavoriteRetentionCandidate>()
          .toList(growable: false);
    } catch (error) {
      debugLog('Error fetching favorite retention candidates: $error');
      return const [];
    }
  }

  static Future<bool> saveSelection(Iterable<String> bookIds) async {
    if (!isAuthenticated) return false;
    final normalized = bookIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    try {
      final response = await _client.rpc(
        'set_current_user_visible_favorites',
        params: {'p_book_ids': normalized},
      );
      return response == 'updated' || response == 'not_required';
    } catch (error) {
      debugLog('Error saving favorite retention selection: $error');
      return false;
    }
  }

  /// Adds a favorite through the database's Premium-only compatibility RPC.
  /// This remains useful for stale clients that still apply the historical
  /// finite paid-plan precheck before calling the database.
  static Future<bool> addPremiumFavorite(String bookId) async {
    if (!isAuthenticated || bookId.trim().isEmpty) return false;
    try {
      final state = await fetchState();
      if (state == null || !state.isPremium || !state.isUnlimited) return false;
      final response = await _client.rpc(
        'add_current_user_premium_favorite',
        params: {'p_book_id': bookId.trim()},
      );
      return response == 'added' || response == 'already_favorited';
    } catch (error) {
      debugLog('Error adding Premium favorite: $error');
      return false;
    }
  }
}
