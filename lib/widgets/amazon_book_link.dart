import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book.dart';
import '../services/amazon_book_destination.dart';

/// An Amazon Associates product link, with a labelled search fallback.
///
/// The Associates tag is intentionally supplied at build time. It is a public
/// tracking identifier once embedded in an Amazon URL, but keeping it out of
/// source makes it possible to enable or disable the feature per deployment.
class AmazonBookLink extends StatelessWidget {
  const AmazonBookLink({super.key, required this.book});

  final Book book;

  static const String _associateTag = String.fromEnvironment(
    'AMAZON_ASSOCIATE_TAG',
  );

  static bool get isConfigured => _associateTag.trim().isNotEmpty;

  @visibleForTesting
  static Uri destinationFor(Book book) {
    return AmazonBookDestination.forBook(book, _associateTag).uri;
  }

  Future<void> _openAmazon(BuildContext context) async {
    var launched = false;
    try {
      launched = await launchUrl(
        destinationFor(book),
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_blank',
      );
    } catch (_) {
      // Keep launch failures user-visible without exposing URL diagnostics.
    }
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Amazonを開けませんでした。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isConfigured) return const SizedBox.shrink();
    final destination = AmazonBookDestination.forBook(book, _associateTag);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => _openAmazon(context),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(destination.label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black, width: 1.2),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '広告・アフィリエイトリンク',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black, fontSize: 12),
        ),
        if (!destination.isProductPage)
          const Text(
            'この本はAmazonの検索結果を開きます。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 11),
          ),
        const Text(
          'Amazon のアソシエイトとして、Sharemarium は適格販売により収入を得ています。',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFF4A4A4A),
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}
