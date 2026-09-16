import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/supabase_service.dart';

class BookActionLabel extends StatelessWidget {
  const BookActionLabel({
    super.key,
    required this.bookId,
    required this.label,
    required this.color,
    required this.wantToRead,
    this.style,
  });

  final String bookId;
  final String label;
  final Color color;
  final bool wantToRead;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SupabaseService>(context, listen: false);
    return FutureBuilder<BookEngagementCounts>(
      future: service.fetchBookEngagementCounts(bookId),
      builder: (context, snapshot) {
        final counts = snapshot.data;
        final count = wantToRead
            ? counts?.wantToReadCount ?? 0
            : counts?.readCount ?? 0;
        return Text(
          '$label $count',
          textAlign: TextAlign.center,
          style: (style ?? const TextStyle(fontWeight: FontWeight.bold))
              .copyWith(color: color),
        );
      },
    );
  }
}
