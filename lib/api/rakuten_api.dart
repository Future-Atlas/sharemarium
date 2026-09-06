import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/book.dart';
import '../utils/dev_logger.dart';

// Kept for local troubleshooting. `debugLog` is silent outside debug builds.
void debugPrint(String? message, {int? wrapWidth}) {
  debugLog(message, wrapWidth: wrapWidth);
}

class RakutenApi {
  static const String _proxyBaseUrl = String.fromEnvironment(
    'RAKUTEN_PROXY_BASE_URL',
  );
  static final Map<String, Book?> _bookByIdCache = <String, Book?>{};

  static bool _canRequestRakuten() {
    return kIsWeb || _proxyBaseUrl.trim().isNotEmpty;
  }

  static Uri _buildProxyUri(
    String endpoint,
    Map<String, String> queryParameters,
  ) {
    final params = <String, String>{'endpoint': endpoint, ...queryParameters};
    final trimmedBase = _proxyBaseUrl.trim();
    if (trimmedBase.isEmpty) {
      return Uri(path: '/api/rakuten', queryParameters: params);
    }

    final normalized = trimmedBase.endsWith('/')
        ? trimmedBase.substring(0, trimmedBase.length - 1)
        : trimmedBase;
    return Uri.parse(
      '$normalized/api/rakuten',
    ).replace(queryParameters: params);
  }

  static Future<http.Response?> _requestRakuten(
    String endpoint,
    Map<String, String> queryParameters,
  ) {
    return _getWithRateLimitRetry(_buildProxyUri(endpoint, queryParameters));
  }

  static List<String> buildSearchKeywordVariants(String keyword) {
    final original = keyword.trim();
    if (original.isEmpty) return const [];

    final separators = RegExp(r'[\s\u3000・･]+');
    final compact = original.replaceAll(separators, '');
    final variants = <String>{original, compact};

    // Rakuten's field-specific search does not always treat a middle dot as
    // optional, so search the first meaningful segment as a fallback.
    final hasMiddleDot = RegExp(r'[・･]').hasMatch(original);
    final segments = original
        .split(separators)
        .where((value) => value.length >= 2)
        .toList();
    if (hasMiddleDot && segments.length > 1) {
      variants.add(segments.first);
    } else if (compact.length > 6 && RegExp(r'[ぁ-んァ-ヶ一-龥]').hasMatch(compact)) {
      variants.add(compact.substring(0, 6));
    }

    return variants.where((value) => value.isNotEmpty).toList();
  }

  static Future<http.Response?> _getWithRateLimitRetry(
    Uri uri, {
    int maxRetries = 3,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final response = await http.get(uri);

      if (response.statusCode != 429) {
        return response;
      }

      if (attempt == maxRetries) {
        return response;
      }

      final retryAfterHeader = response.headers['retry-after'];
      final retryAfterSeconds = int.tryParse(retryAfterHeader ?? '') ?? 1;
      final safeWait = retryAfterSeconds < 1 ? 1 : retryAfterSeconds;

      debugPrint(
        'Rakuten rate limit reached. Retrying in ${safeWait}s '
        '(${attempt + 1}/$maxRetries).',
      );
      await Future.delayed(Duration(seconds: safeWait));
    }

    return null;
  }

  static Future<Book?> fetchBookById(String bookId) async {
    if (bookId.trim().isEmpty || !_canRequestRakuten()) {
      return null;
    }

    final trimmed = bookId.trim();
    final cacheKey = trimmed.replaceAll('-', '');
    if (_bookByIdCache.containsKey(cacheKey)) {
      return _bookByIdCache[cacheKey];
    }

    final isbnLike = RegExp(r'^[0-9Xx-]{10,17}$').hasMatch(trimmed);
    final queryParameters = <String, String>{'hits': '1'};
    if (isbnLike) {
      queryParameters['isbn'] = trimmed.replaceAll('-', '');
    } else {
      queryParameters['keyword'] = trimmed;
    }

    try {
      final response = await _requestRakuten('book', queryParameters);
      if (response == null || response.statusCode != 200) {
        _bookByIdCache[cacheKey] = null;
        return null;
      }

      final json = jsonDecode(utf8.decode(response.bodyBytes));
      final items = json['Items'] as List<dynamic>? ?? [];
      if (items.isEmpty) return null;

      final item = items.first;
      final bookData = item['Item'];
      if (bookData is! Map<String, dynamic>) return null;

      final result = _bookFromRakutenData(
        bookData,
        fallbackId: trimmed,
        genre: '',
      );
      _bookByIdCache[cacheKey] = result;
      return result;
    } catch (e) {
      debugPrint('Rakuten book lookup failed: $e');
      _bookByIdCache[cacheKey] = null;
      return null;
    }
  }

  static Future<List<Book>> searchBySelectedGenre({
    required String selectedGenre,
    int page = 1,
    int count = 10,
    bool keywordSearch = false,
    String? sort,
    String? searchField,
  }) async {
    if (!_canRequestRakuten()) {
      debugPrint('Rakuten proxy is not configured.');
      return [];
    }

    final effectiveCount = count.clamp(1, 30);
    var endpoint = 'book';
    final queryParameters = <String, String>{
      'page': '$page',
      'hits': '$effectiveCount',
    };

    if (keywordSearch) {
      const allowedFields = {'title', 'author', 'publisherName'};
      final field = allowedFields.contains(searchField)
          ? searchField!
          : 'title';
      queryParameters['booksGenreId'] = '001';
      queryParameters[field] = selectedGenre.trim();
      queryParameters['sort'] = sort ?? 'reviewCount';
    } else if (selectedGenre.contains('English') ||
        selectedGenre.contains('洋書')) {
      endpoint = 'foreign';
      queryParameters['booksGenreId'] = '005';
      queryParameters['sort'] = sort ?? 'reviewCount';
    } else {
      String genreId = '001';
      String keyword = '';

      if (selectedGenre.contains('話題の本') || selectedGenre.contains('おすすめ')) {
        genreId = '001004';
        sort ??= '-releaseDate';
      } else if (selectedGenre.contains('ビジネス') ||
          selectedGenre.contains('経済')) {
        genreId = '001006';
      } else if (selectedGenre.contains('ベストセラー') ||
          selectedGenre.contains('人気作品')) {
        genreId = '001';
        sort ??= 'reviewCount';
      } else {
        keyword = selectedGenre;
      }

      queryParameters['booksGenreId'] = genreId;
      if (keyword.isNotEmpty) {
        queryParameters['keyword'] = keyword;
      }
      if (sort != null && sort.isNotEmpty) {
        queryParameters['sort'] = sort;
      }
    }

    try {
      final response = await _requestRakuten(endpoint, queryParameters);
      if (response == null || response.statusCode != 200) {
        debugPrint('Rakuten request failed: ${response?.statusCode}');
        return [];
      }

      final json = jsonDecode(utf8.decode(response.bodyBytes));
      final items = json['Items'] as List<dynamic>? ?? [];
      final books = <Book>[];
      for (final item in items) {
        final bookData = item['Item'];
        if (bookData is! Map<String, dynamic>) continue;
        books.add(
          _bookFromRakutenData(
            bookData,
            fallbackId: UniqueKey().toString(),
            genre: selectedGenre,
          ),
        );
      }
      return books;
    } catch (e) {
      debugPrint('Rakuten search failed: $e');
      return [];
    }
  }

  static Book _bookFromRakutenData(
    Map<String, dynamic> bookData, {
    required String fallbackId,
    required String genre,
  }) {
    final title = bookData['title'] as String? ?? '不明な書籍';
    final author = bookData['author'] as String? ?? '不明な著者';
    final publisher = bookData['publisherName'] as String? ?? '不明な出版社';
    final pubDate = bookData['salesDate'] as String? ?? '';
    final isbn = bookData['isbn'] as String? ?? '';
    final itemUrl = bookData['itemUrl'] as String? ?? '';
    final description = bookData['itemCaption'] as String? ?? '';
    final rawReviewAverage = bookData['reviewAverage'];
    final parsedReviewAverage = rawReviewAverage is num
        ? rawReviewAverage.toDouble()
        : double.tryParse(rawReviewAverage?.toString() ?? '') ?? 0.0;
    final rawReviewCount = bookData['reviewCount'];
    final parsedReviewCount = rawReviewCount is num
        ? rawReviewCount.toInt()
        : int.tryParse(rawReviewCount?.toString() ?? '') ?? 0;

    String coverUrl = bookData['largeImageUrl'] as String? ?? '';
    if (coverUrl.isNotEmpty) {
      coverUrl =
          'https://images.weserv.nl/?url=${Uri.encodeComponent(coverUrl)}';
    }

    return Book(
      id: isbn.isNotEmpty ? isbn : (itemUrl.isNotEmpty ? itemUrl : fallbackId),
      title: title,
      author: author,
      publisher: publisher,
      pubDate: pubDate,
      isbn: isbn,
      coverUrl: coverUrl,
      ratingAvg: parsedReviewAverage,
      reviewCount: parsedReviewCount,
      genre: genre,
      description: description,
    );
  }

  static Future<List<Book>> searchByKeyword({
    required String keyword,
    int page = 1,
    int count = 20,
    List<String>? searchFields,
  }) async {
    const allowedFields = {'title', 'author', 'publisherName'};
    final fields = (searchFields ?? const <String>[])
        .where(allowedFields.contains)
        .toSet()
        .toList();
    if (fields.isEmpty) {
      fields.addAll(const ['title', 'author', 'publisherName']);
    }
    final merged = <String, Book>{};
    final keywordVariants = buildSearchKeywordVariants(keyword);

    for (final field in fields) {
      for (final keywordVariant in keywordVariants) {
        final books = await searchBySelectedGenre(
          selectedGenre: keywordVariant,
          page: page,
          count: count,
          keywordSearch: true,
          searchField: field,
          sort: 'standard',
        );
        for (final book in books) {
          merged.putIfAbsent(book.id, () => book);
        }
      }
    }
    return merged.values.toList();
  }
}
