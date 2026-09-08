import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/services/input_security_service.dart';
import 'package:sharemarium/widgets/post_reply_dialog.dart';

void main() {
  testWidgets('guest reply dialog guides the user to sign in', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          '/login': (_) => const Scaffold(body: Text('login screen')),
        },
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPostReplyLockedDialog(
              context: context,
              isAuthenticated: false,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.login_rounded), findsOneWidget);
    expect(find.text('返信するにはサインインしてください'), findsOneWidget);
    expect(
      find.text('公開投稿と返信はサインインせず閲覧できます。返信を投稿する場合のみサインインが必要です。'),
      findsOneWidget,
    );
    expect(find.text('サインイン'), findsOneWidget);

    await tester.tap(find.text('サインイン'));
    await tester.pumpAndSettle();
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('signed-in locked reply dialog shows the limited-content message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPostReplyLockedDialog(
              context: context,
              isAuthenticated: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(find.text('返信は限定コンテンツです'), findsOneWidget);
    expect(find.text('サインイン'), findsNothing);
  });

  testWidgets('reply dialog shows only the requested length guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showPostReplyDialog(context: context, postId: 'post-id'),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('100文字以内で返信できます'), findsOneWidget);
    expect(find.textContaining('URL'), findsNothing);

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.minLines, 5);
    expect(textField.maxLines, 5);

    final initialWidth = tester.getSize(find.byType(TextField)).width;
    await tester.enterText(
      find.byType(TextField),
      List.filled(100, 'あ').join(),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(TextField)).width, initialWidth);
  });

  test('reply character count excludes spaces and line breaks', () {
    expect(InputSecurityService.replyCharacterCount('あ い\nう'), 3);
    expect(InputSecurityService.validateReplyMessage('あ い\nう'), isNull);

    final oneHundredCharacters = List.filled(100, 'あ').join();
    expect(
      InputSecurityService.validateReplyMessage('$oneHundredCharacters\n   '),
      isNull,
    );
    expect(
      InputSecurityService.validateReplyMessage('$oneHundredCharactersあ'),
      '返信は100文字以内で入力してください。',
    );
  });
}
