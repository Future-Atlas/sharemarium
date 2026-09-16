import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/supabase_service.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _subjectController = TextEditingController();
  final _messageController = TextEditingController();
  String _category = 'general';
  bool _isSubmitting = false;

  static const _categories = <String, String>{
    'general': '一般的なお問い合わせ',
    'privacy': '個人情報・開示等の請求',
    'infringement': '権利侵害に関する申出',
    'report': '投稿・利用者の通報',
    'account': 'アカウント・退会',
    'billing': '料金・返金',
    'fraud': '不正利用',
    'other': 'その他',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_emailController.text.isEmpty) {
      final email = Provider.of<SupabaseService>(
        context,
        listen: false,
      ).currentUser?.email;
      if (email != null) _emailController.text = email;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    final service = Provider.of<SupabaseService>(context, listen: false);
    final error = await service.submitContactRequest(
      email: _emailController.text,
      category: _category,
      subject: _subjectController.text,
      message: _messageController.text,
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('送信しました'),
        content: const Text('お問い合わせを受け付けました。内容を確認の上、入力されたメールアドレスへ回答します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final close = widget.onClose;
    if (close != null) {
      close();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('お問い合わせ'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '個人情報の開示等、権利侵害、通報、アカウント、料金・返金、不正利用に関するご連絡もこちらから送信できます。',
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    decoration: const InputDecoration(
                      labelText: 'お問い合わせ種別',
                      border: OutlineInputBorder(),
                    ),
                    items: _categories.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: _isSubmitting
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _category = value);
                            }
                          },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '返信先メールアドレス',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final email = value?.trim() ?? '';
                      if (email.isEmpty ||
                          !email.contains('@') ||
                          email.length > 320) {
                        return '有効なメールアドレスを入力してください。';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _subjectController,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: '件名',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value?.trim().isEmpty ?? true) ? '件名を入力してください。' : null,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _messageController,
                    minLines: 7,
                    maxLines: 12,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: 'お問い合わせ内容',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value?.trim().isEmpty ?? true)
                        ? 'お問い合わせ内容を入力してください。'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _isSubmitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF3B30),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('送信する'),
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
