import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/book.dart';

class NdlApi {
  // 📌 新しい国会図書館サーチ（OpenSearch API）のエンドポイントURL
  static const _baseUrl = 'https://ndlsearch.ndl.go.jp/api/opensearch';

  /// 📌 画面から選択されたジャンル名（例: '文学', '話題の本', 'English' など）を受け取り、
  /// 自動的に分類コード（NDC）または検索キーワード（any）に切り替えて国会図書館から本を取得します。
  static Future<List<Book>> searchBySelectedGenre({
    required String selectedGenre,
    int page = 1,
    int count = 10,
  }) async {
    String ndcCode = '';
    String keyword = '';

    // 1. 画面から渡された文字列を解析し、分類コード(NDC)か一般キーワード(any)かを自動でマッピング
    if (selectedGenre.contains('文学') || selectedGenre.contains('小説')) {
      ndcCode = '9*'; // 900〜999 (文学)
    } else if (selectedGenre.contains('ビジネス') || selectedGenre.contains('産業')) {
      ndcCode = '6*'; // 600〜699 (産業・ビジネス)
    } else if (selectedGenre.contains('社会') ||
        selectedGenre.contains('経済') ||
        selectedGenre.contains('法律')) {
      ndcCode = '3*'; // 300〜399 (社会科学)
    } else if (selectedGenre.contains('自然科学') ||
        selectedGenre.contains('数学') ||
        selectedGenre.contains('医学')) {
      ndcCode = '4*'; // 400〜499 (自然科学)
    } else if (selectedGenre.contains('技術') || selectedGenre.contains('工学')) {
      ndcCode = '5*'; // 500〜599 (技術・工学)
    } else if (selectedGenre.contains('芸術') ||
        selectedGenre.contains('アート') ||
        selectedGenre.contains('スポーツ')) {
      ndcCode = '7*'; // 700〜799 (芸術・アート)
    } else if (selectedGenre.contains('歴史') || selectedGenre.contains('地理')) {
      ndcCode = '2*'; // 200〜299 (歴史・地理)
    } else if (selectedGenre.contains('哲学') ||
        selectedGenre.contains('心理') ||
        selectedGenre.contains('宗教')) {
      ndcCode = '1*'; // 100〜199 (哲学・宗教)
    } else if (selectedGenre.contains('言語') || selectedGenre.contains('語学')) {
      ndcCode = '8*'; // 800〜899 (言語)
    } else if (selectedGenre.contains('総記') || selectedGenre.contains('情報科学')) {
      ndcCode = '0*'; // 0000〜099 (総記)
    } else {
      // 📌 「話題の本」「English」「ベストセラー」や自由な検索文字はすべてキーワード検索に回す
      keyword = selectedGenre;
    }

    // 2. 基本パラメータの組み立て（cnt=取得件数, startPage=現在のページ, mediatype=1は図書固定）
    String urlString = '$_baseUrl?cnt=$count&startPage=$page&mediatype=1';

    // NDCコードがあれば付与
    if (ndcCode.isNotEmpty) {
      urlString += '&ndc=$ndcCode';
    }

    // キーワードがあればURL用に安全にエンコード（日本語等の文字化け・エラー防止）して付与
    if (keyword.isNotEmpty) {
      urlString += '&any=${Uri.encodeComponent(keyword)}';
    }

    // 💡 国会図書館APIの仕様上、両方空っぽ（初期表示などで何も指定がない状態）だと
    // ヒット件数が0件で返ってくるため、最低限「本」という広範なキーワードを安全弁として仕込む
    if (ndcCode.isEmpty && keyword.isEmpty) {
      urlString += '&any=${Uri.encodeComponent("本")}';
    }

    try {
      final uri = Uri.parse(urlString);
      final response = await http.get(uri);

      if (response.statusCode != 200) {
        return [];
      }

      // utf8.decode で文字化けを完全に防止してXMLをパース
      final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
      final itemElements = document.findAllElements('item');
      final List<Book> books = [];

      for (var element in itemElements) {
        final title =
            element.findElements('title').firstOrNull?.innerText ??
            element.findElements('dc:title').firstOrNull?.innerText ??
            '不明なタイトル';

        final author =
            element.findElements('author').firstOrNull?.innerText ??
            element.findElements('dc:creator').firstOrNull?.innerText ??
            '不明な著者';

        final link = element.findElements('link').firstOrNull?.innerText ?? '';
        final publisher =
            element.findElements('dc:publisher').firstOrNull?.innerText ??
            '不明な出版社';
        final pubDate =
            element.findElements('dcterms:issued').firstOrNull?.innerText ??
            element.findElements('dc:date').firstOrNull?.innerText ??
            '';

        // ISBN（バーコード番号）を抽出して、のちの楽天APIでの画像検索のフックにする
        String isbn = '';
        final idElements = element.findElements('dc:identifier');
        for (var idNode in idElements) {
          final typeAttr = idNode.getAttribute('xsi:type');
          if (typeAttr != null && typeAttr.contains('ISBN')) {
            isbn = idNode.innerText.trim();
            break;
          }
        }

        books.add(
          Book(
            id: isbn.isNotEmpty
                ? isbn
                : (link.isNotEmpty ? link : UniqueKey().toString()),
            title: title,
            author: author,
            publisher: publisher,
            pubDate: pubDate,
            isbn: isbn,
            coverUrl: '', // この後 BookRepository 側で RakutenApi を通じて結合されます
            genre: selectedGenre,
            description:
                element.findElements('dc:description').firstOrNull?.innerText ??
                '',
          ),
        );
      }

      return books;
    } catch (e) {
      return [];
    }
  }
}
