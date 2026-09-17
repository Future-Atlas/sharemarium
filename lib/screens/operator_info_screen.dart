import 'package:flutter/material.dart';
import 'package:url_launcher/link.dart';

/// Public service information; viewing this page does not require an account.
class OperatorInfoScreen extends StatelessWidget {
  const OperatorInfoScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.bold,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('運営者情報'),
        leading: IconButton(
          tooltip: '戻る',
          icon: const Icon(Icons.arrow_back),
          onPressed:
              onClose ??
              () {
                final navigator = Navigator.of(context);
                if (navigator.canPop()) {
                  navigator.pop();
                } else {
                  navigator.pushReplacementNamed('/');
                }
              },
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sharemariumについて', style: heading),
                  const SizedBox(height: 12),
                  const Text(
                    'Sharemarium（シェアマリウム）は、伊能 龍之介が企画・開発・運営する読書記録Webサービスです。',
                    style: TextStyle(fontSize: 16, height: 1.8),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '読んだ本を記録し、感想をみんなと共有できる読書レビューSNSです。自分用の読書記録にも、お友だちとの感想共有にも使えるSharemariumで、あなただけの本棚を作りましょう。',
                    style: TextStyle(fontSize: 16, height: 1.8),
                  ),
                  const SizedBox(height: 32),
                  Text('企画・開発・運営', style: heading),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('伊能 龍之介', style: TextStyle(fontSize: 20)),
                      Link(
                        uri: Uri.parse(
                          'https://www.instagram.com/ryunosukeino/',
                        ),
                        target: LinkTarget.blank,
                        builder: (context, followLink) => TextButton(
                          onPressed: followLink,
                          child: const Text(
                            'Instagram',
                            style: TextStyle(
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('共同開発', style: heading),
                  const SizedBox(height: 12),
                  const Text('劉 鴻斌', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 32),
                  Text('お問い合わせ', style: heading),
                  const SizedBox(height: 12),
                  const Text(
                    'サービスに関するお問い合わせは、お問い合わせフォームからご連絡ください。',
                    style: TextStyle(fontSize: 16, height: 1.8),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/contact'),
                    child: const Text('お問い合わせフォーム'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
