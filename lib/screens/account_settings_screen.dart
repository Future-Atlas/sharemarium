import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/user_profile.dart';
import '../models/profile_page_color.dart';
import '../services/supabase_service.dart';
import '../services/theme_service.dart';
import 'community_guidelines_screen.dart';
import 'contact_screen.dart';
import 'external_transmission_screen.dart';
import 'infringement_policy_screen.dart';
import 'privacy_policy_screen.dart';
import 'profile_onboarding_screen.dart';
import 'subscription_status_screen.dart';
import 'terms_screen.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({
    super.key,
    required this.onAccountDeleted,
    this.openPrivacyPasswordRecovery = false,
  });

  final VoidCallback onAccountDeleted;
  final bool openPrivacyPasswordRecovery;

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  late bool _showRecovery = widget.openPrivacyPasswordRecovery;
  bool _deleting = false;

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _openPrivacySettings() async {
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PrivacyPasswordDialog(onForgot: _startRecovery),
    );
    if (!mounted || password == null) return;
    final service = Provider.of<SupabaseService>(context, listen: false);
    final verified = await service.verifyPrivacyPassword(password);
    if (!mounted) return;
    if (!verified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('パスワードが正しくないか、一時的にロックされています。')),
      );
      return;
    }
    _push(_PrivacySettingsScreen(password: password));
  }

  Future<void> _startRecovery() async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final error = await service.beginPrivacyPasswordRecovery();
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本当に退会しますか？'),
        content: const Text('アカウントと関連データが削除されます。この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('退会する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final error = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).deleteCurrentAccount();
    if (!mounted) return;
    setState(() => _deleting = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    widget.onAccountDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SupabaseService>(context);
    if (!service.isAuthenticated) {
      return const Center(child: Text('設定を利用するにはログインしてください。'));
    }
    if (_showRecovery) {
      return _PrivacyPasswordRecoveryScreen(
        onCompleted: () => setState(() => _showRecovery = false),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionTitle('ユーザー設定'),
            _SettingsCard(
              children: [
                ListTile(
                  leading: const Icon(Icons.manage_accounts_outlined),
                  title: const Text('アカウント設定'),
                  subtitle: const Text('ユーザー名・ユーザーID（変更不可）・鍵アカウント'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(const _PublicAccountSettingsScreen()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('プライバシー設定'),
                  subtitle: const Text('氏名・生年月日・電話番号・メールアドレス'),
                  trailing: const Icon(Icons.lock_outline),
                  onTap: _openPrivacySettings,
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 40, right: 16),
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('ブロックしているアカウント'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(const _BlockedAccountsScreen()),
                ),
                const Divider(height: 1),
                Consumer<ThemeService>(
                  builder: (context, themeService, _) => ListTile(
                    contentPadding: const EdgeInsets.only(left: 40, right: 16),
                    leading: const Icon(Icons.dark_mode_outlined),
                    title: const Text('ダークモード'),
                    trailing: Switch(
                      value: themeService.isDarkMode,
                      onChanged: themeService.setDarkMode,
                    ),
                    onTap: () =>
                        themeService.setDarkMode(!themeService.isDarkMode),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const _SectionTitle('プラン・契約'),
            _SettingsCard(
              children: [
                ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: const Text('プラン・契約'),
                  subtitle: const Text('現在のプラン・無料体験・次回更新日を確認'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(const SubscriptionStatusScreen()),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const _SectionTitle('各種ポリシー'),
            _SettingsCard(
              children: [
                _policyTile('利用規約', const TermsScreen()),
                _policyTile('プライバシーポリシー', const PrivacyPolicyScreen()),
                _policyTile('コミュニティガイドライン', const CommunityGuidelinesScreen()),
                _policyTile('権利侵害・通報ポリシー', const InfringementPolicyScreen()),
                _policyTile(
                  '外部送信に関する公表事項',
                  const ExternalTransmissionScreen(),
                  last: true,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const _SectionTitle('お問い合わせ'),
            _SettingsCard(
              children: [
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: const Text('お問い合わせフォーム'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(const ContactScreen()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined),
                  iconColor: Colors.red,
                  textColor: Colors.red,
                  title: const Text('退会'),
                  trailing: _deleting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _deleting ? null : _deleteAccount,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const _SectionTitle('アプリ情報'),
            const _SettingsCard(
              children: [
                ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Sharemarium'),
                  subtitle: Text('バージョン 1.1.0+2'),
                ),
              ],
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  Widget _policyTile(String title, Widget screen, {bool last = false}) =>
      Column(
        children: [
          ListTile(
            title: Text(title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(screen),
          ),
          if (!last) const Divider(height: 1),
        ],
      );
}

class _PublicAccountSettingsScreen extends StatefulWidget {
  const _PublicAccountSettingsScreen();

  @override
  State<_PublicAccountSettingsScreen> createState() =>
      _PublicAccountSettingsScreenState();
}

class _PublicAccountSettingsScreenState
    extends State<_PublicAccountSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _userIdController = TextEditingController();
  final _bioController = TextEditingController();
  bool _isPrivate = false;
  String _pageColorKey = ProfilePageColors.defaultKey;
  String _avatarUrl = '';
  bool _loading = true;
  bool _saving = false;
  bool _updatingAvatar = false;
  bool _canUseAllPageColors = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final results = await Future.wait<dynamic>([
      service.fetchCurrentSettingsData(),
      service.canUseAllPageColors(),
    ]);
    final data = results[0] as Map<String, dynamic>?;
    final canUseAllPageColors = results[1] == true;
    if (!mounted) return;
    _usernameController.text = data?['username']?.toString() ?? '';
    _userIdController.text = data?['user_id']?.toString() ?? '';
    _bioController.text = data?['bio']?.toString() ?? '';
    setState(() {
      _avatarUrl = data?['avatar_url']?.toString() ?? '';
      _isPrivate = data?['is_private'] == true;
      _pageColorKey = ProfilePageColors.normalizeKey(
        data?['page_color']?.toString(),
      );
      _canUseAllPageColors = canUseAllPageColors;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _userIdController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final error = await Provider.of<SupabaseService>(context, listen: false)
        .updatePublicProfile(
          username: _usernameController.text,
          userId: _userIdController.text,
          bio: _bioController.text,
          isPrivate: _isPrivate,
          pageColorKey: _pageColorKey,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'アカウント設定を保存しました。')));
  }

  Future<void> _chooseAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    if (bytes.lengthInBytes > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画像は5MB以下にしてください。')));
      return;
    }

    final croppedBytes = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AvatarCropDialog(imageBytes: bytes),
    );
    if (croppedBytes == null || !mounted) return;
    if (croppedBytes.lengthInBytes > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('編集後の画像は5MB以下にしてください。')));
      return;
    }

    final mimeType = picked.mimeType ?? _mimeTypeFromName(picked.name);
    setState(() => _updatingAvatar = true);
    final url = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).uploadProfileAvatar(bytes: croppedBytes, mimeType: mimeType);
    if (!mounted) return;
    setState(() {
      _updatingAvatar = false;
      if (url != null) _avatarUrl = url;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(url == null ? '画像を保存できませんでした。' : 'プロフィール画像を更新しました。'),
      ),
    );
  }

  String _mimeTypeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Widget _buildPageColorPicker() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ページカラー',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'ヘッダーと投稿の外枠に使用され、他のユーザーにも表示されます。全14色はPremium特典です。',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 12,
          children: ProfilePageColors.options.map((option) {
            final selected = option.key == _pageColorKey;
            final locked =
                !_canUseAllPageColors &&
                !ProfilePageColors.standardKeys.contains(option.key);
            return Semantics(
              button: true,
              selected: selected,
              enabled: !locked,
              label: locked ? '${option.label}はPremium限定' : '${option.label}を選択',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  if (locked) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('このページカラーはPremium限定です。')),
                    );
                    return;
                  }
                  setState(() => _pageColorKey = option.key);
                },
                child: SizedBox(
                  width: 70,
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: option.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.25,
                                  ),
                            width: selected ? 3 : 1,
                          ),
                        ),
                        child: locked
                            ? const Icon(
                                Icons.lock,
                                color: Colors.white,
                                size: 21,
                                shadows: [
                                  Shadow(color: Colors.black87, blurRadius: 4),
                                ],
                              )
                            : selected
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 24,
                                shadows: [
                                  Shadow(color: Colors.black54, blurRadius: 3),
                                ],
                              )
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        option.label,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _removeAvatar() async {
    setState(() => _updatingAvatar = true);
    final removed = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).removeProfileAvatar();
    if (!mounted) return;
    setState(() {
      _updatingAvatar = false;
      if (removed) _avatarUrl = '';
    });
    if (!removed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('プロフィール画像を削除できませんでした。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('アカウント設定')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Center(
                        child: Column(
                          children: [
                            CircleAvatar(
                              radius: 52,
                              backgroundImage: _avatarUrl.isEmpty
                                  ? null
                                  : NetworkImage(_avatarUrl),
                              child: _avatarUrl.isEmpty
                                  ? const Icon(Icons.person, size: 52)
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: _updatingAvatar
                                      ? null
                                      : _chooseAvatar,
                                  icon: _updatingAvatar
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.photo_camera_outlined),
                                  label: Text(
                                    _avatarUrl.isEmpty
                                        ? 'デバイスから画像を選択'
                                        : 'デバイスから画像を変更',
                                  ),
                                ),
                                if (_avatarUrl.isNotEmpty)
                                  TextButton(
                                    onPressed: _updatingAvatar
                                        ? null
                                        : _removeAvatar,
                                    child: const Text('画像を削除'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'JPEG・PNG・WebP／5MB以下',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _usernameController,
                        maxLength: 30,
                        decoration: const InputDecoration(
                          labelText: 'ユーザー名',
                          helperText: 'プロフィールに表示される名前です。いつでも変更できます。',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value?.trim().isEmpty ?? true)
                            ? 'ユーザー名を入力してください。'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _userIdController,
                        readOnly: true,
                        canRequestFocus: false,
                        enableInteractiveSelection: false,
                        mouseCursor: SystemMouseCursors.basic,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          labelText: 'ユーザーID',
                          prefixText: '@',
                          helperText: 'ユーザーIDは変更できません。',
                          hoverColor: Colors.transparent,
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            RegExp(
                              r'^[a-z0-9_]{3,20}$',
                            ).hasMatch((value ?? '').trim().toLowerCase())
                            ? null
                            : 'ユーザーIDの形式を確認してください。',
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _bioController,
                        minLines: 4,
                        maxLines: 7,
                        maxLength: 300,
                        decoration: const InputDecoration(
                          labelText: '自己紹介文',
                          hintText: '好きな本や読書について入力してください。',
                          helperText: 'プロフィール上で公開されます。',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _buildPageColorPicker(),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('鍵アカウント'),
                        subtitle: Text(
                          _isPrivate
                              ? '承認したフォロワーだけが投稿を閲覧できます。'
                              : '誰でも投稿を閲覧できます。',
                        ),
                        value: _isPrivate,
                        onChanged: (value) =>
                            setState(() => _isPrivate = value),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const CircularProgressIndicator()
                            : const Text('保存する'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _PrivacySettingsScreen extends StatefulWidget {
  const _PrivacySettingsScreen({required this.password});

  final String password;

  @override
  State<_PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<_PrivacySettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  DateTime? _birthDate;
  bool _loading = true;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final data = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).fetchCurrentSettingsData();
    if (!mounted) return;
    _nameController.text = data?['full_name']?.toString() ?? '';
    _phoneController.text = data?['phone_number']?.toString() ?? '';
    _emailController.text = data?['email']?.toString() ?? '';
    _birthDate = DateTime.tryParse(data?['birth_date']?.toString() ?? '');
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 20),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (selected != null && mounted) setState(() => _birthDate = selected);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _birthDate == null) return;
    setState(() => _saving = true);
    final error = await Provider.of<SupabaseService>(context, listen: false)
        .updatePrivateAccountDetails(
          password: widget.password,
          fullName: _nameController.text,
          birthDate: _birthDate!,
          phoneNumber: _phoneController.text,
          email: _emailController.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'プライバシー設定を保存しました。')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('プライバシー設定')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      const Text(
                        '以下の情報は公開されません。',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _nameController,
                        maxLength: 100,
                        decoration: const InputDecoration(
                          labelText: '氏名',
                          border: OutlineInputBorder(),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('生年月日'),
                        subtitle: Text(
                          _birthDate == null
                              ? '未登録'
                              : '${_birthDate!.year}/${_birthDate!.month.toString().padLeft(2, '0')}/${_birthDate!.day.toString().padLeft(2, '0')}',
                        ),
                        trailing: const Icon(Icons.calendar_month),
                        onTap: _selectDate,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: '電話番号',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final phone = (value ?? '').replaceAll(
                            RegExp(r'[^0-9+]'),
                            '',
                          );
                          return RegExp(r'^\+?[0-9]{7,15}$').hasMatch(phone)
                              ? null
                              : '有効な電話番号を入力してください。';
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'メールアドレス',
                          helperText: '変更時は新しいメールアドレスでの確認が必要になる場合があります。',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value ?? '').contains('@')
                            ? null
                            : '有効なメールアドレスを入力してください。',
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const CircularProgressIndicator()
                            : const Text('変更を保存する'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _ChangePrivacyPasswordScreen(
                              currentPassword: widget.password,
                            ),
                          ),
                        ),
                        child: const Text('個人情報変更用パスワードを変更'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  static String? _required(String? value) =>
      (value?.trim().isEmpty ?? true) ? '入力してください。' : null;
}

class _BlockedAccountsScreen extends StatefulWidget {
  const _BlockedAccountsScreen();

  @override
  State<_BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<_BlockedAccountsScreen> {
  late Future<List<UserProfile>> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = Provider.of<SupabaseService>(
      context,
      listen: false,
    ).fetchBlockedProfiles();
  }

  Future<void> _unblock(UserProfile profile) async {
    final success = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).unblockProfile(profile.id);
    if (!mounted) return;
    if (success) {
      setState(() {
        _future = Provider.of<SupabaseService>(
          context,
          listen: false,
        ).fetchBlockedProfiles();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ブロックしているアカウント')),
      body: FutureBuilder<List<UserProfile>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final profiles = snapshot.data!;
          if (profiles.isEmpty) {
            return const Center(child: Text('ブロックしているアカウントはありません。'));
          }
          return ListView.separated(
            itemCount: profiles.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final profile = profiles[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: profile.avatarUrl.isEmpty
                      ? null
                      : NetworkImage(profile.avatarUrl),
                  child: profile.avatarUrl.isEmpty
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                title: Text(profile.username),
                subtitle: Text('@${profile.userId}'),
                trailing: OutlinedButton(
                  onPressed: () => _unblock(profile),
                  child: const Text('解除'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PrivacyPasswordDialog extends StatefulWidget {
  const _PrivacyPasswordDialog({required this.onForgot});

  final VoidCallback onForgot;

  @override
  State<_PrivacyPasswordDialog> createState() => _PrivacyPasswordDialogState();
}

class _PrivacyPasswordDialogState extends State<_PrivacyPasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('パスワードを入力'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: _obscure,
        onSubmitted: (value) {
          if (value.isNotEmpty) Navigator.of(context).pop(value);
        },
        decoration: InputDecoration(
          labelText: '個人情報変更用パスワード',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'パスワードを表示' : 'パスワードを隠す',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onForgot();
            });
          },
          child: const Text('パスワードを忘れた方'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            if (_controller.text.isNotEmpty) {
              Navigator.of(context).pop(_controller.text);
            }
          },
          child: const Text('確認'),
        ),
      ],
    );
  }
}

class _ChangePrivacyPasswordScreen extends StatefulWidget {
  const _ChangePrivacyPasswordScreen({required this.currentPassword});

  final String currentPassword;

  @override
  State<_ChangePrivacyPasswordScreen> createState() =>
      _ChangePrivacyPasswordScreenState();
}

class _ChangePrivacyPasswordScreenState
    extends State<_ChangePrivacyPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final error = await Provider.of<SupabaseService>(context, listen: false)
        .changePrivacyPassword(
          currentPassword: widget.currentPassword,
          newPassword: _passwordController.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('パスワード変更')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _passwordController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '新しいパスワード',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              validator: validatePrivacyPassword,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmationController,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: '新しいパスワード（確認）',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value != _passwordController.text ? 'パスワードが一致しません。' : null,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('変更する'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyPasswordRecoveryScreen extends StatefulWidget {
  const _PrivacyPasswordRecoveryScreen({required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<_PrivacyPasswordRecoveryScreen> createState() =>
      _PrivacyPasswordRecoveryScreenState();
}

class _PrivacyPasswordRecoveryScreenState
    extends State<_PrivacyPasswordRecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final error = await Provider.of<SupabaseService>(
      context,
      listen: false,
    ).resetPrivacyPasswordAfterReauthentication(_passwordController.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    widget.onCompleted();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('パスワードを再設定しました。')));
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'パスワードを再設定',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('連携サービスでの本人確認が完了しました。15分以内に再設定してください。'),
              const SizedBox(height: 20),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '新しいパスワード',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
                validator: validatePrivacyPassword,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmationController,
                obscureText: _obscure,
                decoration: const InputDecoration(
                  labelText: '新しいパスワード（確認）',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value != _passwordController.text ? 'パスワードが一致しません。' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('再設定する'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

class _AvatarCropDialog extends StatefulWidget {
  const _AvatarCropDialog({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  final CropController _controller = CropController();
  bool _ready = false;
  bool _cropping = false;

  void _onCropped(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop(croppedImage);
      case CropFailure():
        setState(() => _cropping = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('画像を編集できませんでした。もう一度お試しください。')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final editorSize = math
        .min(size.width - 48, size.height - 240)
        .clamp(220.0, 520.0)
        .toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'プロフィール画像を調整',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              const Text('画像をドラッグして移動し、ピンチまたはマウスホイールで拡大・縮小できます。'),
              const SizedBox(height: 16),
              SizedBox.square(
                dimension: editorSize,
                child: ClipRect(
                  child: Crop(
                    image: widget.imageBytes,
                    controller: _controller,
                    onCropped: _onCropped,
                    onStatusChanged: (status) {
                      if (!mounted) return;
                      setState(() {
                        _ready = status == CropStatus.ready;
                        _cropping = status == CropStatus.cropping;
                      });
                    },
                    aspectRatio: 1,
                    initialRectBuilder: InitialRectBuilder.withSizeAndRatio(
                      size: 0.88,
                      aspectRatio: 1,
                    ),
                    interactive: true,
                    fixCropRect: true,
                    maskColor: Colors.black54,
                    baseColor: Colors.black,
                    scrollZoomSensitivity: 0.06,
                    filterQuality: FilterQuality.high,
                    progressIndicator: const Center(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _cropping
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('キャンセル'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: !_ready || _cropping
                        ? null
                        : () {
                            setState(() => _cropping = true);
                            _controller.crop();
                          },
                    icon: _cropping
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('この範囲で保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
