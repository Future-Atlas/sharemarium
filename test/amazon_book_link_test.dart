import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/models/book.dart';
import 'package:sharemarium/services/amazon_book_destination.dart';
import 'package:sharemarium/widgets/amazon_book_link.dart';

Book book(String isbn) => Book(
  id: 'test',
  title: '本 & タイトル',
  author: '著者',
  publisher: '',
  pubDate: '',
  isbn: isbn,
  coverUrl: '',
);

void main() {
  test('978 ISBN-13 converts to the print edition ISBN-10 product URL', () {
    final link = AmazonBookDestination.forBook(
      book('978-4-10-101001-4'),
      ' test-22 ',
    );
    expect(
      link.uri.toString(),
      'https://www.amazon.co.jp/dp/4101010013/ref=nosim?tag=test-22',
    );
    expect(link.isProductPage, isTrue);
    expect(link.label, 'Amazonで見る');
  });
  test('ISBN-10 leading zero and X check digit are preserved', () {
    for (final isbn in ['0747591059', '080442957x']) {
      final link = AmazonBookDestination.forBook(book(isbn), 'test-22');
      expect(link.uri.path, '/dp/${isbn.toUpperCase()}/ref=nosim');
    }
    expect(
      AmazonBookDestination.forBook(book('9780804429573'), 'test-22').uri.path,
      '/dp/080442957X/ref=nosim',
    );
  });
  test('spaces and hyphens can be removed without changing the ISBN', () {
    final link = AmazonBookDestination.forBook(
      book(' 978 4-10-101001-4　'),
      'test-22',
    );
    expect(link.uri.path, '/dp/4101010013/ref=nosim');
  });
  test('unknown or invalid ISBN never fabricates a product ASIN', () {
    for (final isbn in [
      '9791234567896',
      '9784101010015',
      '4101010014',
      '9784101010014oops',
      '123',
      '',
    ]) {
      final link = AmazonBookDestination.forBook(book(isbn), 'test-22');
      expect(link.isProductPage, isFalse, reason: isbn);
      expect(link.uri.path, '/s');
      expect(link.label, 'Amazonで探す');
      expect(link.uri.queryParameters['tag'], 'test-22');
    }
  });
  test(
    'missing ISBN falls back to title and author with safe URL encoding',
    () {
      final link = AmazonBookDestination.forBook(book(''), 'test-22');
      expect(link.uri.queryParameters['k'], '本 & タイトル 著者');
      expect(link.uri.queryParameters.keys, unorderedEquals(['k', 'tag']));
    },
  );
  testWidgets('no affiliate UI is shown without a configured tracking tag', (
    tester,
  ) async {
    if (AmazonBookLink.isConfigured) return;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AmazonBookLink(book: book('9784101010014'))),
      ),
    );
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('広告・アフィリエイトリンク'), findsNothing);
  });
  testWidgets(
    'configured links display product/search labels and disclosure on a narrow screen',
    (tester) async {
      if (!AmazonBookLink.isConfigured) return;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final isbn in ['9784101010014', '']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AmazonBookLink(book: book(isbn))),
          ),
        );
        expect(
          find.text(isbn.isEmpty ? 'Amazonで探す' : 'Amazonで見る'),
          findsOneWidget,
        );
        expect(find.text('広告・アフィリエイトリンク'), findsOneWidget);
        expect(
          find.text('この本はAmazonの検索結果を開きます。'),
          isbn.isEmpty ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
