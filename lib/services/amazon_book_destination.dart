import '../models/book.dart';

/// ISBN-based links for print editions; Kindle ASINs must not be inferred.
class AmazonBookDestination {
  const AmazonBookDestination._(this.uri, this.isProductPage);

  final Uri uri;
  final bool isProductPage;

  String get label => isProductPage ? 'Amazonで見る' : 'Amazonで探す';

  factory AmazonBookDestination.forBook(Book book, String associateTag) {
    final isbn = book.isbn
        .replaceAll(RegExp(r'[\s\-\u3000]'), '')
        .toUpperCase();
    final asin = _printAsin(isbn);
    return AmazonBookDestination._(
      Uri.https(
        'www.amazon.co.jp',
        asin == null ? '/s' : '/dp/$asin/ref=nosim',
        {
          if (asin == null)
            'k': book.isbn.trim().isNotEmpty
                ? book.isbn.trim()
                : '${book.title.trim()} ${book.author.trim()}'.trim(),
          'tag': associateTag.trim(),
        },
      ),
      asin != null,
    );
  }

  // Amazon commonly uses ISBN-10 as the ASIN for print books. Validate the
  // checksum before linking; 979 ISBNs have no ISBN-10 equivalent. This does
  // not guarantee that Amazon stocks the edition.
  static String? _printAsin(String isbn) {
    if (RegExp(r'^\d{9}[\dX]$').hasMatch(isbn)) {
      var sum = 0;
      for (var i = 0; i < 10; i++) {
        sum += (isbn[i] == 'X' ? 10 : int.parse(isbn[i])) * (10 - i);
      }
      return sum % 11 == 0 ? isbn : null;
    }
    if (!RegExp(r'^978\d{10}$').hasMatch(isbn)) return null;
    var sum13 = 0;
    for (var i = 0; i < 13; i++) {
      sum13 += int.parse(isbn[i]) * (i.isEven ? 1 : 3);
    }
    if (sum13 % 10 != 0) return null;

    final body = isbn.substring(3, 12);
    var sum10 = 0;
    for (var i = 0; i < 9; i++) {
      sum10 += int.parse(body[i]) * (10 - i);
    }
    final check = (11 - sum10 % 11) % 11;
    return '$body${check == 10 ? 'X' : check}';
  }
}
