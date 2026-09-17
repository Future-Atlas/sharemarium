import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/screens/operator_info_screen.dart';
import 'package:url_launcher/link.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('public operator page: $width, $brightness', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const OperatorInfoScreen(),
            routes: {
              '/contact': (_) => const Scaffold(body: Text('contact opened')),
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('伊能 龍之介'), findsOneWidget);
        expect(find.text('劉 鴻斌'), findsOneWidget);
        final link = tester.widget<Link>(find.byType(Link));
        expect(link.uri.toString(), 'https://www.instagram.com/ryunosukeino/');
        expect(link.target, LinkTarget.blank);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('お問い合わせフォーム'));
        await tester.tap(find.text('お問い合わせフォーム'));
        await tester.pumpAndSettle();
        expect(find.text('contact opened'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
