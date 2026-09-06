import 'dart:math';

import '../models/book.dart';
import '../api/rakuten_api.dart';
import '../services/content_safety_service.dart';

enum BookSearchField { title, author, publisher }

extension BookSearchFieldApiName on BookSearchField {
  String get apiName => switch (this) {
    BookSearchField.title => 'title',
    BookSearchField.author => 'author',
    BookSearchField.publisher => 'publisherName',
  };
}

class BookRepository {
  static final Random _homeRandom = Random();

  BookRepository({this.allowAdultContent = false});

  final bool allowAdultContent;

  static String _normalizeForSearch(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'[^0-9a-zぁ-んァ-ヶ一-龥]+'), '');

  static String _normalizeForExact(String input) =>
      input.trim().toLowerCase().replaceAll(RegExp(r'[\s\u3000・･]+'), '');

  static int _matchQuality(String value, String query, List<String> tokens) {
    if (value == query) return 4;
    if (value.startsWith(query)) return 3;
    if (value.contains(query)) return 2;
    if (tokens.isNotEmpty && tokens.every(value.contains)) return 1;
    return 0;
  }

  static List<BookSearchField> searchFieldPriority(String rawQuery) {
    final query = rawQuery.trim();
    final normalized = _normalizeForSearch(query);
    const titleFirst = <BookSearchField>[
      BookSearchField.title,
      BookSearchField.author,
      BookSearchField.publisher,
    ];
    const authorFirst = <BookSearchField>[
      BookSearchField.author,
      BookSearchField.title,
      BookSearchField.publisher,
    ];
    const publisherFirst = <BookSearchField>[
      BookSearchField.publisher,
      BookSearchField.title,
      BookSearchField.author,
    ];

    if (query.endsWith('社')) return publisherFirst;

    final lowerQuery = query.toLowerCase();
    if (RegExp(r'(co\.|comics)\s*$').hasMatch(lowerQuery)) {
      return publisherFirst;
    }

    final containsLatin = RegExp(r'[a-zA-Z]').hasMatch(query);
    if (containsLatin) {
      if (RegExp(r'[!！?？:：()（）*＊]').hasMatch(query)) {
        return titleFirst;
      }
      if (RegExp(
        r"^[A-Za-z][A-Za-z.'’\-]*[\s\u3000]+[A-Za-z][A-Za-z.'’\-]*$",
      ).hasMatch(query)) {
        return authorFirst;
      }
      return titleFirst;
    }

    if (RegExp(r'[ァ-ヶー]+[・･][ァ-ヶー]+').hasMatch(query)) {
      return authorFirst;
    }

    final containsJapanese = RegExp(r'[ぁ-んァ-ヶ一-龥]').hasMatch(query);
    final containsSpace = RegExp(r'[\s\u3000]').hasMatch(query);
    if (containsJapanese &&
        !containsSpace &&
        normalized.length >= 3 &&
        normalized.length <= 5) {
      return authorFirst;
    }

    return titleFirst;
  }

  static String _fieldValue(Book book, BookSearchField field) =>
      switch (field) {
        BookSearchField.title => book.title,
        BookSearchField.author => book.author,
        BookSearchField.publisher => book.publisher,
      };

  static _RankedBook _rankedBook(Book book, String rawQuery) {
    final query = _normalizeForSearch(rawQuery);
    if (query.isEmpty) {
      return _RankedBook(book: book, priorityIndex: 3, quality: 0);
    }
    final tokens = rawQuery
        .split(RegExp(r'[\s\u3000・･]+'))
        .map(_normalizeForSearch)
        .where((token) => token.isNotEmpty)
        .toList();
    final priorities = searchFieldPriority(rawQuery);
    final qualities = <int>[];
    for (final field in priorities) {
      qualities.add(
        _matchQuality(
          _normalizeForSearch(_fieldValue(book, field)),
          query,
          tokens,
        ),
      );
    }

    // 指定どおり、スペースと中点だけを除いた完全一致は入力分類より常に優先する。
    final exactQuery = _normalizeForExact(rawQuery);
    for (var index = 0; index < qualities.length; index++) {
      if (_normalizeForExact(_fieldValue(book, priorities[index])) ==
          exactQuery) {
        return _RankedBook(
          book: book,
          priorityIndex: index,
          quality: qualities[index],
          isExact: true,
        );
      }
    }
    for (var index = 0; index < qualities.length; index++) {
      if (qualities[index] > 0) {
        return _RankedBook(
          book: book,
          priorityIndex: index,
          quality: qualities[index],
        );
      }
    }
    return _RankedBook(book: book, priorityIndex: 3, quality: 0);
  }

  static List<Book> rankSearchResults(Iterable<Book> source, String query) {
    final ranked = source.map((book) => _rankedBook(book, query)).toList();

    int compareMatches(_RankedBook a, _RankedBook b) {
      final quality = b.quality.compareTo(a.quality);
      if (quality != 0) return quality;
      final reviews = b.book.reviewCount.compareTo(a.book.reviewCount);
      if (reviews != 0) return reviews;
      final rating = b.book.ratingAvg.compareTo(a.book.ratingAvg);
      if (rating != 0) return rating;
      return a.book.title.compareTo(b.book.title);
    }

    final exact = ranked.where((item) => item.isExact).toList()
      ..sort((a, b) {
        final priority = a.priorityIndex.compareTo(b.priorityIndex);
        return priority != 0 ? priority : compareMatches(a, b);
      });
    final buckets = List.generate(4, (index) {
      final values = ranked
          .where((item) => !item.isExact && item.priorityIndex == index)
          .toList();
      values.sort(compareMatches);
      return values;
    });

    final output = <Book>[...exact.map((item) => item.book)];
    while (output.length < ranked.length) {
      final slot = output.length % 20;
      final preferred = slot < 10 ? 0 : (slot < 15 ? 1 : 2);
      final fallbackOrder = switch (preferred) {
        0 => const [0, 1, 2, 3],
        1 => const [1, 2, 0, 3],
        _ => const [2, 1, 0, 3],
      };
      _RankedBook? next;
      for (final bucketIndex in fallbackOrder) {
        if (buckets[bucketIndex].isNotEmpty) {
          next = buckets[bucketIndex].removeAt(0);
          break;
        }
      }
      if (next == null) break;
      output.add(next.book);
    }
    return output;
  }

  List<Book> _filterForViewer(List<Book> books) {
    return ContentSafetyService.filterBooks(
      books,
      allowAdultContent: allowAdultContent,
    );
  }

  /// 📌 1. トップ画面の各セクション（おすすめ・洋書・人気）の追加読み込み用
  /// ここでは最初から表紙画像が確実に手に入る楽天APIをページ指定で動かします。
  Future<List<Book>> fetchBooksByGenre(String genre, {int page = 1}) async {
    try {
      // ⏱️【429エラー（連打）対策】
      // コントローラーが一斉に複数のジャンルを要求してきた際、
      // 楽天APIがパンクして429エラーを返さないよう、通信の直前に必ず「1秒の休憩」を挟みます。
      await Future.delayed(const Duration(seconds: 1));

      // 楽天APIの searchBySelectedGenre を直接呼び出す
      final isRecommended = genre.contains('話題の本') || genre.contains('おすすめ');
      final rakutenBooks = await RakutenApi.searchBySelectedGenre(
        selectedGenre: genre,
        page: page,
        count: 27,
      );
      final filtered = _filterForViewer(rakutenBooks);
      if (isRecommended) {
        filtered.sort((a, b) {
          final reviews = b.reviewCount.compareTo(a.reviewCount);
          if (reviews != 0) return reviews;
          return b.ratingAvg.compareTo(a.ratingAvg);
        });
      }
      return _randomRankedSelection(filtered, count: 9);
    } catch (_) {
      return [];
    }
  }

  /// Selects a different subset for each home visit while preserving the
  /// ranking order supplied by the existing API and section-specific sort.
  List<Book> _randomRankedSelection(List<Book> ranked, {required int count}) {
    if (ranked.length <= count) return List<Book>.from(ranked);

    final selectedIndexes = List<int>.generate(ranked.length, (index) => index)
      ..shuffle(_homeRandom);
    selectedIndexes
      ..removeRange(count, selectedIndexes.length)
      ..sort();
    return selectedIndexes.map((index) => ranked[index]).toList();
  }

  /// 📌 2. 全件取得（初期表示用など）
  /// 楽天APIから取得します。
  Future<List<Book>> fetchAllBooks() async {
    try {
      final rakutenBooks = await RakutenApi.searchBySelectedGenre(
        selectedGenre: '',
        page: 1,
        count: 10,
      );
      return _filterForViewer(rakutenBooks);
    } catch (_) {
      return [];
    }
  }

  /// 📌 3. 検索窓からのキーワード検索（網羅性重視）
  /// 楽天APIでキーワード検索を行います。
  Future<List<Book>> searchBooks(
    String query, {
    int page = 1,
    int count = 20,
  }) async {
    if (query.isEmpty) return fetchAllBooks();
    if (!allowAdultContent && ContentSafetyService.isAdultSearchQuery(query)) {
      return [];
    }

    try {
      final rakutenBooks = await RakutenApi.searchByKeyword(
        keyword: query,
        page: page,
        count: count,
        searchFields: searchFieldPriority(
          query,
        ).map((field) => field.apiName).toList(),
      );
      return rankSearchResults(
        _filterForViewer(rakutenBooks),
        query,
      ).take(count).toList();
    } catch (_) {
      return [];
    }
  }
}

class _RankedBook {
  const _RankedBook({
    required this.book,
    required this.priorityIndex,
    required this.quality,
    this.isExact = false,
  });

  final Book book;
  final int priorityIndex;
  final int quality;
  final bool isExact;
}
