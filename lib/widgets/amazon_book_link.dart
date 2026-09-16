import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book.dart';

/// An Amazon Associates search link for a book.
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
    final isbn = book.isbn.replaceAll(RegExp(r'[^0-9Xx]'), '');
    final query = isbn.isNotEmpty
        ? isbn
        : '${book.title.trim()} ${book.author.trim()}'.trim();

    return Uri.https('www.amazon.co.jp', '/s', {
      'k': query,
      'tag': _associateTag.trim(),
    });
  }

  Future<void> _openAmazon(BuildContext context) async {
    final launched = await launchUrl(
      destinationFor(book),
      mode: LaunchMode.platformDefault,
      webOnlyWindowName: '_blank',
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Amazonを開けませんでした。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isConfigured) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => _openAmazon(context),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Amazonで探す'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black, width: 1.2),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 6),
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
