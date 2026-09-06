import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../repositories/book_repository.dart';
import '../services/supabase_service.dart';
import '../widgets/post_composer_dialog.dart';

class ProfileBookSearchScreen extends StatefulWidget {
  const ProfileBookSearchScreen({super.key});

  @override
  State<ProfileBookSearchScreen> createState() =>
      _ProfileBookSearchScreenState();
}

class _ProfileBookSearchScreenState extends State<ProfileBookSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<Book> _results = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  int _searchGeneration = 0;
  final Map<String, Future<bool>> _readStatusFutures = {};
  final Map<String, Future<bool>> _wantedStatusFutures = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_scheduleSearch);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController
      ..removeListener(_scheduleSearch)
      ..dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _searchGeneration++;
      setState(() {
        _results = [];
        _isSearching = false;
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _search(query);
    });
  }

  Future<void> _search(String query) async {
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _hasSearched = true;
    });

    final service = Provider.of<SupabaseService>(context, listen: false);
    final allowAdultContent = await service.canViewAdultContent();
    final books = await BookRepository(
      allowAdultContent: allowAdultContent,
    ).searchBooks(query);
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _results = books;
      _isSearching = false;
    });
  }

  Future<void> _markAsRead(Book book) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (await service.isBookReadByCurrentUser(bookId: book.id)) return;
    if (!mounted) return;
    final posted = await showPostComposerDialog(context: context, book: book);
    if (!mounted || !posted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _toggleWantToRead(Book book) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final result = await service.toggleWantToRead(book: book);
    if (!mounted) return;
    _wantedStatusFutures[book.id] = service.isBookWantedByCurrentUser(book.id);
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          '本を検索',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'closeProfileBookSearch',
        onPressed: () => Navigator.of(context).pop(false),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        tooltip: '閉じる',
        child: const Icon(Icons.close, size: 30),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (value) {
                  _debounce?.cancel();
                  final query = value.trim();
                  if (query.isNotEmpty) _search(query);
                },
                style: const TextStyle(color: Colors.black87),
                decoration: InputDecoration(
                  hintText: '本の名前・著者名を入力',
                  hintStyle: const TextStyle(color: Colors.black45),
                  prefixIcon: const Icon(Icons.search, color: Colors.black54),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _searchController.clear,
                          icon: const Icon(Icons.clear, color: Colors.black54),
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black54),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black, width: 2),
                  ),
                ),
              ),
            ),
            Expanded(child: _buildSearchBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBody() {
    if (_isSearching) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF3B30)),
      );
    }
    if (!_hasSearched) {
      return const Center(
        child: Text('読了した本を検索してください', style: TextStyle(color: Colors.black54)),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          '該当する本が見つかりませんでした',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: _results.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final book = _results[index];
        return Material(
          color: const Color(0xFFF3F3F3),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 72,
                  height: 104,
                  color: Colors.grey[300],
                  child: book.coverUrl.trim().isNotEmpty
                      ? Image.network(
                          book.coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                                Icons.menu_book_outlined,
                                color: Colors.black45,
                              ),
                        )
                      : const Icon(
                          Icons.menu_book_outlined,
                          color: Colors.black45,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        book.author.isEmpty ? '著者不明' : book.author,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FutureBuilder<bool>(
                            future: _readStatusFutures.putIfAbsent(
                              book.id,
                              () => Provider.of<SupabaseService>(
                                context,
                                listen: false,
                              ).isBookReadByCurrentUser(bookId: book.id),
                            ),
                            builder: (context, snapshot) {
                              final isRead = snapshot.data ?? false;
                              final isChecking =
                                  snapshot.connectionState ==
                                  ConnectionState.waiting;
                              return ElevatedButton(
                                onPressed: isRead || isChecking
                                    ? null
                                    : () => _markAsRead(book),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.black,
                                  foregroundColor: const Color(0xFFFF1F1F),
                                  disabledBackgroundColor: Colors.black,
                                  disabledForegroundColor: isRead
                                      ? const Color(0xFF00BFFF)
                                      : Colors.grey,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: Text(
                                  isRead ? '読了済み' : '読了',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          FutureBuilder<bool>(
                            future: _wantedStatusFutures.putIfAbsent(
                              book.id,
                              () => Provider.of<SupabaseService>(
                                context,
                                listen: false,
                              ).isBookWantedByCurrentUser(book.id),
                            ),
                            builder: (context, snapshot) {
                              final wanted = snapshot.data ?? false;
                              return ElevatedButton(
                                onPressed:
                                    snapshot.connectionState ==
                                        ConnectionState.waiting
                                    ? null
                                    : () => _toggleWantToRead(book),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.black,
                                  foregroundColor: Colors.amber,
                                  disabledBackgroundColor: Colors.black,
                                  disabledForegroundColor:
                                      Colors.amber.shade200,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: Text(wanted ? '読みたい！済み' : '読みたい！'),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
