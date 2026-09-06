// SupabaseService: handles real Supabase interactions only – no mock data.
// Mock book data removed – books are fetched from external APIs via BookRepository.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../api/rakuten_api.dart';
import '../models/book.dart';
import 'legal_document_versions.dart';
import '../models/user_profile.dart';
import '../models/post.dart';
import '../models/post_reply.dart';
import '../models/social_models.dart';
import '../models/moderation_models.dart';
import '../models/profile_page_color.dart';
import 'content_safety_service.dart';
import 'input_security_service.dart';
import 'timeline_ranking_service.dart';
import '../utils/dev_logger.dart';

// Kept for local troubleshooting. `debugLog` is silent outside debug builds.
void debugPrint(String? message, {int? wrapWidth}) {
  debugLog(message, wrapWidth: wrapWidth);
}

enum FavoriteToggleResult {
  added,
  removed,
  standardLimitReached,
  subscriberLimitReached,
  requiresRead,
  failed,
}

enum WantToReadToggleResult { added, removed, alreadyRead, failed }

extension WantToReadToggleResultLabel on WantToReadToggleResult {
  bool get shouldRestoreOptimisticState =>
      this == WantToReadToggleResult.alreadyRead ||
      this == WantToReadToggleResult.failed;

  String get message {
    switch (this) {
      case WantToReadToggleResult.added:
        return '「読みたい！」に追加しました。';
      case WantToReadToggleResult.removed:
        return '「読みたい！」から解除しました。';
      case WantToReadToggleResult.alreadyRead:
        return 'この本はすでに読了済みです。';
      case WantToReadToggleResult.failed:
        return '「読みたい！」を更新できませんでした。';
    }
  }
}

class SupabaseService extends ChangeNotifier {
  static const int standardFavoriteLimit = 3;
  static const int subscriberFavoriteLimit = 12;

  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  bool _isInitialized = false;
  SupabaseClient? _client;
  StreamSubscription<AuthState>? _authStateSubscription;
  String? _redirectUrl;
  bool? _hasCurrentLegalConsentCache;
  String? _cachedConsentUserId;
  bool? _hasCompletedRegistrationCache;
  String? _cachedRegistrationUserId;
  String _activePageColorKey = ProfilePageColors.defaultKey;
  Timer? _sessionGuardTimer;

  // ----- Initialization ----------------------------------------------------
  Future<void> initialize({
    String? url,
    String? anonKey,
    String? redirectUrl,
  }) async {
    if (url != null &&
        anonKey != null &&
        url.isNotEmpty &&
        anonKey.isNotEmpty) {
      try {
        _redirectUrl = redirectUrl?.trim().isNotEmpty == true
            ? redirectUrl!.trim()
            : null;

        await Supabase.initialize(url: url, publishableKey: anonKey);
        _client = Supabase.instance.client;
        _isInitialized = true;

        _authStateSubscription?.cancel();
        _authStateSubscription = _client!.auth.onAuthStateChange.listen((evt) {
          final user = evt.session?.user;
          if (_cachedConsentUserId != user?.id) {
            _cachedConsentUserId = user?.id;
            _hasCurrentLegalConsentCache = null;
          }
          if (_cachedRegistrationUserId != user?.id) {
            _cachedRegistrationUserId = user?.id;
            _hasCompletedRegistrationCache = null;
          }
          if (user != null) {
            _startSessionGuardLoop();
            unawaited(
              _ensureProfile(
                userId: user.id,
              ).then((_) => refreshActiveProfileAppearance()),
            );
            unawaited(_enforceSessionIpGuard());
          } else {
            _stopSessionGuardLoop();
            _activePageColorKey = ProfilePageColors.defaultKey;
          }
          notifyListeners();
        });

        debugPrint('Supabase initialized successfully.');
      } catch (e) {
        debugPrint('Supabase initialization failed: $e');
      }
    } else {
      debugPrint(
        'Supabase credentials not provided – service remains uninitialized.',
      );
    }
  }

  // ----- Helper -----------------------------------------------------------
  // Returns the current authenticated user ID, or an empty string if not logged in.
  String get activeProfileId => _client?.auth.currentUser?.id ?? '';

  String get activePageColorKey => _activePageColorKey;

  bool get isAuthenticated => _client?.auth.currentSession != null;

  /// Shared write permission gate for authenticated-only actions.
  /// Keep this as a convenience wrapper and keep the RLS boundary enforced in
  /// Supabase itself.
  bool get canWrite => isAuthenticated;

  User? get currentUser => _client?.auth.currentUser;

  // ----- AUTH -------------------------------------------------------------
  Future<String?> sendMagicLink({required String email}) async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      await _client!.auth.signInWithOtp(
        email: email,
        shouldCreateUser: true,
        emailRedirectTo: _authRedirectUrl(),
      );
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return 'マジックリンク送信に失敗しました: $e';
    }
  }

  Future<String?> signInWithGoogle() async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      final started = await _client!.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: _authRedirectUrl(),
        queryParams: const {'prompt': 'select_account'},
      );

      if (!started) {
        return 'Googleログインを開始できませんでした。';
      }
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return 'Googleログインに失敗しました: $e';
    }
  }

  Future<String?> signInWithX() async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      final started = await _client!.auth.signInWithOAuth(
        OAuthProvider.x,
        redirectTo: _authRedirectUrl(),
      );

      if (!started) {
        return 'Xログインを開始できませんでした。';
      }
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return 'Xログインに失敗しました: $e';
    }
  }

  Future<String?> signInWithFacebook({bool privacyRecovery = false}) =>
      _signInWithSocialProvider(
        OAuthProvider.facebook,
        label: 'Facebook',
        privacyRecovery: privacyRecovery,
      );

  Future<String?> signInWithApple({bool privacyRecovery = false}) =>
      _signInWithSocialProvider(
        OAuthProvider.apple,
        label: 'Apple',
        privacyRecovery: privacyRecovery,
      );

  Future<String?> signInWithDiscord({bool privacyRecovery = false}) =>
      _signInWithSocialProvider(
        OAuthProvider.discord,
        label: 'Discord',
        privacyRecovery: privacyRecovery,
      );

  Future<String?> _signInWithSocialProvider(
    OAuthProvider provider, {
    required String label,
    bool privacyRecovery = false,
  }) async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      final redirectTo = privacyRecovery
          ? _privacyRecoveryRedirectUrl()
          : _authRedirectUrl();
      final started = await _client!.auth.signInWithOAuth(
        provider,
        redirectTo: redirectTo,
      );
      return started ? null : '$labelログインを開始できませんでした。';
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '$labelログインに失敗しました: $e';
    }
  }

  String? _privacyRecoveryRedirectUrl() {
    final source = _authRedirectUrl();
    if (source == null || source.isEmpty) return null;
    final uri = Uri.tryParse(source);
    if (uri == null) return source;
    return uri
        .replace(
          queryParameters: const {'privacy_password_recovery': '1'},
          fragment: '',
        )
        .toString();
  }

  /// Returns the URL to which Supabase should send the user after auth.
  ///
  /// On web, always use the origin that is currently serving the app. This
  /// prevents a stale Supabase Site URL from sending production users back to
  /// an old Vercel deployment URL. Native apps continue to use the configured
  /// redirect URL.
  String? _authRedirectUrl() {
    if (!kIsWeb) return _redirectUrl;

    final current = Uri.base;
    if (!current.hasScheme || current.host.isEmpty) return _redirectUrl;

    return Uri(
      scheme: current.scheme,
      host: current.host,
      port: current.hasPort ? current.port : null,
      path: '/',
    ).toString();
  }

  Future<String?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      final response = await _client!.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final user = response.user;
      if (user != null) {
        await _ensureProfile(userId: user.id, preferredUsername: null);
      }
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return 'ログインに失敗しました: $e';
    }
  }

  Future<String?> signUpWithEmail({
    required String email,
    required String password,
    String? username,
  }) async {
    if (!_isInitialized || _client == null) {
      return 'Supabaseが初期化されていません。';
    }

    try {
      final response = await _client!.auth.signUp(
        email: email,
        password: password,
      );
      final user = response.user;
      if (user != null) {
        await _ensureProfile(userId: user.id, preferredUsername: username);
      }
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '新規登録に失敗しました: $e';
    }
  }

  Future<void> signOut() async {
    if (!_isInitialized || _client == null) return;
    try {
      _stopSessionGuardLoop();
      await _client!.auth.signOut();
      _activePageColorKey = ProfilePageColors.defaultKey;
      notifyListeners();
    } catch (e) {
      debugPrint('Error signing out: $e');
    }
  }

  void _startSessionGuardLoop() {
    _sessionGuardTimer?.cancel();
    _sessionGuardTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_enforceSessionIpGuard());
    });
  }

  void _stopSessionGuardLoop() {
    _sessionGuardTimer?.cancel();
    _sessionGuardTimer = null;
  }

  Future<bool> _enforceSessionIpGuard() async {
    if (!_isInitialized || _client == null || !isAuthenticated) return true;
    try {
      final response = await _client!.functions.invoke(
        'session-guard',
        body: const <String, dynamic>{},
      );
      if (response.status < 200 || response.status >= 300) {
        debugPrint(
          'Session guard endpoint returned status ${response.status}.',
        );
        return true;
      }

      final payload = response.data;
      final data = payload is Map<String, dynamic>
          ? payload
          : payload is Map
          ? Map<String, dynamic>.from(payload)
          : const <String, dynamic>{};
      if (data['ipChanged'] == true) {
        debugPrint('IP change detected. Signing out to protect the session.');
        await signOut();
        return false;
      }
      return true;
    } on FunctionException catch (e) {
      debugPrint('Session guard function exception: $e');
      return true;
    } catch (e) {
      debugPrint('Session guard failed: $e');
      return true;
    }
  }

  Future<void> ensureCurrentUserProfile() async {
    final user = currentUser;
    if (user == null) return;
    await _ensureProfile(userId: user.id);
    await refreshActiveProfileAppearance();
  }

  Future<void> refreshActiveProfileAppearance() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) {
      if (_activePageColorKey != ProfilePageColors.defaultKey) {
        _activePageColorKey = ProfilePageColors.defaultKey;
        notifyListeners();
      }
      return;
    }

    try {
      final profile = await _client!
          .from('profiles')
          .select('page_color')
          .eq('id', profileId)
          .maybeSingle();
      final nextKey = ProfilePageColors.normalizeKey(
        profile?['page_color']?.toString(),
      );
      if (_activePageColorKey != nextKey) {
        _activePageColorKey = nextKey;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading active profile appearance: $e');
    }
  }

  Future<void> _ensureProfile({
    required String userId,
    String? preferredUsername,
  }) async {
    if (!_isInitialized || _client == null) return;

    final generatedUsername = preferredUsername?.trim().isNotEmpty == true
        ? preferredUsername!.trim()
        : _anonymousUsername(userId);

    try {
      final existing = await _client!
          .from('profiles')
          .select('id')
          .eq('id', userId)
          .maybeSingle();
      if (existing != null) return;

      await _client!.from('profiles').insert({
        'id': userId,
        'username': generatedUsername,
        'user_id': _anonymousUserId(userId),
        'avatar_url': '',
        'bio': '',
      });
    } catch (e) {
      debugPrint('Error ensuring profile: $e');
    }
  }

  String _anonymousUsername(String userId) {
    final compactId = userId.replaceAll('-', '');
    final suffix = compactId.length >= 10
        ? compactId.substring(0, 10)
        : compactId;
    return 'reader_$suffix';
  }

  String _anonymousUserId(String profileId) {
    final compactId = profileId.replaceAll('-', '').toLowerCase();
    final suffix = compactId.length >= 10
        ? compactId.substring(0, 10)
        : compactId;
    return 'reader_$suffix';
  }

  Future<bool> hasCompletedRegistration({bool forceRefresh = false}) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return false;
    if (!forceRefresh &&
        _cachedRegistrationUserId == profileId &&
        _hasCompletedRegistrationCache != null) {
      return _hasCompletedRegistrationCache!;
    }

    try {
      final profile = await _client!
          .from('profiles')
          .select('user_id, username')
          .eq('id', profileId)
          .maybeSingle();
      final details = await _client!
          .from('account_details')
          .select('profile_id')
          .eq('profile_id', profileId)
          .maybeSingle();
      final completed =
          profile != null &&
          (profile['user_id']?.toString().isNotEmpty ?? false) &&
          (profile['username']?.toString().isNotEmpty ?? false) &&
          details != null;
      _cachedRegistrationUserId = profileId;
      _hasCompletedRegistrationCache = completed;
      return completed;
    } catch (e) {
      debugPrint('Error checking registration status: $e');
      return false;
    }
  }

  Future<bool> hasPrivacyPassword() async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      final result = await _client!.rpc('has_privacy_password');
      return result == true;
    } catch (e) {
      debugPrint('Error checking privacy password: $e');
      return false;
    }
  }

  Future<bool> requiresGuardianConsent() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return false;
    try {
      final details = await _client!
          .from('account_details')
          .select(
            'birth_date, guardian_consent_declared_at, guardian_consent_terms_version',
          )
          .eq('profile_id', profileId)
          .maybeSingle();
      final birthDate = DateTime.tryParse(
        details?['birth_date']?.toString() ?? '',
      );
      if (birthDate == null || ContentSafetyService.isAtLeast18(birthDate)) {
        return false;
      }
      return details?['guardian_consent_declared_at'] == null ||
          details?['guardian_consent_terms_version'] !=
              LegalDocumentVersions.terms;
    } catch (e) {
      debugPrint('Error checking guardian consent: $e');
      return true;
    }
  }

  Future<String?> declareGuardianConsent() async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }
    try {
      await _client!.rpc(
        'declare_guardian_consent',
        params: {'p_terms_version': LegalDocumentVersions.terms},
      );
      return null;
    } catch (e) {
      debugPrint('Error recording guardian consent declaration: $e');
      return '保護者の同意確認を保存できませんでした。データベース更新後に再試行してください。';
    }
  }

  Future<String?> initializePrivacyPassword(String password) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }
    try {
      await _client!.rpc(
        'initialize_privacy_password',
        params: {'p_password': password},
      );
      return null;
    } on PostgrestException catch (e) {
      if (e.code == '23514') return 'パスワードの条件を確認してください。';
      return e.message;
    } catch (e) {
      return 'パスワードを保存できませんでした。';
    }
  }

  Future<bool> isPublicUserIdAvailable(String userId) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return false;

    try {
      final normalized = userId.trim().toLowerCase();
      final existing = await _client!
          .from('profiles')
          .select('id')
          .eq('user_id', normalized)
          .neq('id', profileId)
          .maybeSingle();
      return existing == null;
    } catch (e) {
      debugPrint('Error checking public user ID: $e');
      return false;
    }
  }

  Future<String?> completeRegistration({
    required String fullName,
    required DateTime birthDate,
    required String phoneNumber,
    required String username,
    required String userId,
    required String privacyPassword,
    required bool guardianConsentDeclared,
  }) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) {
      return 'ログイン状態を確認できませんでした。';
    }

    final fullNameError = InputSecurityService.validateSafeText(
      fullName,
      fieldLabel: '氏名',
      maxLength: 100,
    );
    if (fullNameError != null) return fullNameError;

    final usernameError = InputSecurityService.validateSafeText(
      username,
      fieldLabel: 'ユーザー名',
      maxLength: 30,
    );
    if (usernameError != null) return usernameError;

    try {
      await _ensureProfile(userId: profileId);
      await _client!.rpc(
        'complete_registration',
        params: {
          'p_full_name': fullName.trim(),
          'p_birth_date': birthDate.toIso8601String().split('T').first,
          'p_phone_number': _normalizePhoneNumber(phoneNumber),
          'p_username': username.trim(),
          'p_user_id': userId.trim().toLowerCase(),
          'p_privacy_password': privacyPassword,
          'p_guardian_consent': guardianConsentDeclared,
          'p_terms_version': LegalDocumentVersions.terms,
        },
      );
      _cachedRegistrationUserId = profileId;
      _hasCompletedRegistrationCache = true;
      notifyListeners();
      return null;
    } on PostgrestException catch (e) {
      debugPrint('Registration RPC error: $e');
      if (e.message.contains('REGISTRATION_DENIED')) {
        return 'この登録情報では利用登録できません。心当たりがない場合は、お問い合わせフォームからご連絡ください。';
      }
      if (e.code == '23505') {
        return '既に使われているユーザーIDのため、使用できません。他のIDを使用してください。';
      }
      if (e.message.contains('GUARDIAN_CONSENT_REQUIRED')) {
        return '18歳未満の方は、保護者の同意が必要です。';
      }
      if (e.code == '23514') {
        return '入力内容を確認してください。';
      }
      return '登録情報を保存できませんでした。データベース更新後にもう一度お試しください。';
    } catch (e) {
      debugPrint('Error completing registration: $e');
      return '登録情報を保存できませんでした。もう一度お試しください。';
    }
  }

  String _normalizePhoneNumber(String source) {
    return source.trim().replaceAll(RegExp(r'[^0-9+]'), '');
  }

  Future<Map<String, dynamic>?> fetchCurrentAccountDetails() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return null;

    try {
      return await _client!
          .from('account_details')
          .select(
            'full_name, birth_date, phone_number, phone_verified_at, updated_at',
          )
          .eq('profile_id', profileId)
          .maybeSingle();
    } catch (e) {
      debugPrint('Error fetching account details: $e');
      return null;
    }
  }

  /// Users without a verified registration birth date are treated as minors.
  /// This fail-closed behavior also applies to signed-out visitors.
  Future<bool> canViewAdultContent() async {
    if (!isAuthenticated) return false;
    final details = await fetchCurrentAccountDetails();
    final birthDate = DateTime.tryParse(
      details?['birth_date']?.toString() ?? '',
    );
    if (birthDate == null) return false;
    return ContentSafetyService.isAtLeast18(birthDate);
  }

  Future<Map<String, dynamic>?> fetchCurrentSettingsData() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return null;
    try {
      final profile = await _client!
          .from('profiles')
          .select('username, user_id, avatar_url, bio, is_private, page_color')
          .eq('id', profileId)
          .single();
      _activePageColorKey = ProfilePageColors.normalizeKey(
        profile['page_color']?.toString(),
      );
      final details = await fetchCurrentAccountDetails();
      return {...profile, ...?details, 'email': currentUser?.email ?? ''};
    } catch (e) {
      debugPrint('Error fetching settings data: $e');
      return null;
    }
  }

  Future<bool> canUseAllPageColors() async {
    if (!_isInitialized || _client == null || activeProfileId.isEmpty) {
      return false;
    }
    try {
      return await _client!.rpc('current_user_can_use_all_page_colors') == true;
    } catch (e) {
      debugPrint('Error checking page-color entitlement: $e');
      return false;
    }
  }

  Future<String?> updatePublicProfile({
    required String username,
    required String userId,
    required String bio,
    required bool isPrivate,
    required String pageColorKey,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }

    final usernameError = InputSecurityService.validateSafeText(
      username,
      fieldLabel: 'ユーザー名',
      maxLength: 30,
    );
    if (usernameError != null) return usernameError;

    final bioError = InputSecurityService.validateSafeText(
      bio,
      fieldLabel: '自己紹介',
      required: false,
      allowNewLines: true,
      maxLength: 500,
    );
    if (bioError != null) return bioError;

    try {
      final normalizedPageColor = ProfilePageColors.normalizeKey(pageColorKey);
      if (normalizedPageColor != pageColorKey) {
        return 'ページカラーを選択してください。';
      }
      await _client!.rpc(
        'update_public_profile',
        params: {
          'p_username': username.trim(),
          'p_user_id': userId.trim().toLowerCase(),
          'p_bio': bio.trim(),
          'p_is_private': isPrivate,
        },
      );
      await _client!.rpc(
        'update_profile_page_color',
        params: {'p_page_color': normalizedPageColor},
      );
      _activePageColorKey = normalizedPageColor;
      notifyListeners();
      return null;
    } on PostgrestException catch (e) {
      if (e.message.contains('page_color_subscription_required')) {
        return 'このページカラーはサブスク限定です。';
      }
      if (e.message.contains('USER_ID_IMMUTABLE')) {
        return 'ユーザーIDは登録後に変更できません。';
      }
      if (e.code == '23505') {
        return '既に使われているユーザーIDのため、使用できません。他のIDを使用してください。';
      }
      if (e.code == '23514') return '入力内容を確認してください。';
      return e.message;
    } catch (e) {
      return 'アカウント設定を保存できませんでした。';
    }
  }

  Future<String?> uploadProfileAvatar({
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return null;
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) return null;

    const allowedTypes = {'image/jpeg', 'image/png', 'image/webp'};
    final normalizedType = mimeType.toLowerCase();
    if (!allowedTypes.contains(normalizedType)) return null;
    final extension = switch (normalizedType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final path = '$profileId/avatar.$extension';

    try {
      final bucket = _client!.storage.from('avatars');
      await bucket.uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(
          upsert: true,
          contentType: normalizedType,
          cacheControl: '3600',
        ),
      );
      final publicUrl = bucket.getPublicUrl(path);
      final versionedUrl =
          '$publicUrl?v=${DateTime.now().millisecondsSinceEpoch}';
      await _client!
          .from('profiles')
          .update({'avatar_url': versionedUrl})
          .eq('id', profileId);
      notifyListeners();
      return versionedUrl;
    } catch (e) {
      debugPrint('Error uploading profile avatar: $e');
      return null;
    }
  }

  Future<bool> removeProfileAvatar() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return false;
    try {
      final bucket = _client!.storage.from('avatars');
      await bucket.remove([
        '$profileId/avatar.jpg',
        '$profileId/avatar.png',
        '$profileId/avatar.webp',
      ]);
      await _client!
          .from('profiles')
          .update({'avatar_url': ''})
          .eq('id', profileId);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error removing profile avatar: $e');
      return false;
    }
  }

  Future<bool> verifyPrivacyPassword(String password) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      final result = await _client!.rpc(
        'verify_privacy_password',
        params: {'p_password': password},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error verifying privacy password: $e');
      return false;
    }
  }

  Future<String?> updatePrivateAccountDetails({
    required String password,
    required String fullName,
    required DateTime birthDate,
    required String phoneNumber,
    required String email,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }

    final fullNameError = InputSecurityService.validateSafeText(
      fullName,
      fieldLabel: '氏名',
      maxLength: 100,
    );
    if (fullNameError != null) return fullNameError;

    try {
      final verified = await verifyPrivacyPassword(password);
      if (!verified) return 'パスワードが正しくありません。';

      final normalizedEmail = email.trim();
      if (normalizedEmail != (currentUser?.email ?? '')) {
        await _client!.auth.updateUser(
          UserAttributes(email: normalizedEmail),
          emailRedirectTo: _redirectUrl,
        );
      }
      final updated = await _client!.rpc(
        'update_private_account_details',
        params: {
          'p_password': password,
          'p_full_name': fullName.trim(),
          'p_birth_date': birthDate.toIso8601String().split('T').first,
          'p_phone_number': _normalizePhoneNumber(phoneNumber),
        },
      );
      if (updated != true) return 'パスワードが正しくありません。';
      notifyListeners();
      return null;
    } on AuthException catch (e) {
      return e.message;
    } on PostgrestException catch (e) {
      if (e.code == '28P01') return 'パスワードが正しくありません。';
      if (e.code == '23514') return '入力内容を確認してください。';
      return e.message;
    } catch (e) {
      return 'プライバシー設定を保存できませんでした。';
    }
  }

  Future<String?> changePrivacyPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }
    try {
      final changed = await _client!.rpc(
        'change_privacy_password',
        params: {
          'p_current_password': currentPassword,
          'p_new_password': newPassword,
        },
      );
      if (changed != true) return '現在のパスワードが正しくありません。';
      return null;
    } on PostgrestException catch (e) {
      if (e.code == '28P01') return '現在のパスワードが正しくありません。';
      if (e.code == '23514') return '新しいパスワードの条件を確認してください。';
      return e.message;
    } catch (e) {
      return 'パスワードを変更できませんでした。';
    }
  }

  Future<String?> beginPrivacyPasswordRecovery() async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }
    try {
      final provider = currentUser?.appMetadata['provider']?.toString() ?? '';
      await _client!.rpc('begin_privacy_password_recovery');
      switch (provider) {
        case 'google':
          return _signInWithSocialProvider(
            OAuthProvider.google,
            label: 'Google',
            privacyRecovery: true,
          );
        case 'twitter':
        case 'x':
          return _signInWithSocialProvider(
            OAuthProvider.x,
            label: 'X',
            privacyRecovery: true,
          );
        case 'facebook':
          return signInWithFacebook(privacyRecovery: true);
        case 'apple':
          return signInWithApple(privacyRecovery: true);
        case 'discord':
          return signInWithDiscord(privacyRecovery: true);
        default:
          return 'このログイン方法では再認証できません。お問い合わせからご連絡ください。';
      }
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return '本人確認を開始できませんでした。';
    }
  }

  Future<String?> resetPrivacyPasswordAfterReauthentication(
    String newPassword,
  ) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }
    try {
      await _client!.rpc(
        'reset_privacy_password_after_reauthentication',
        params: {'p_new_password': newPassword},
      );
      return null;
    } on PostgrestException catch (e) {
      if (e.code == '42501') return '本人確認の有効期限が切れました。もう一度お試しください。';
      if (e.code == '23514') return '新しいパスワードの条件を確認してください。';
      return e.message;
    } catch (e) {
      return 'パスワードを再設定できませんでした。';
    }
  }

  Future<List<UserProfile>> fetchBlockedProfiles() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return [];
    try {
      final response = await _client!
          .from('blocks')
          .select(
            'blocked:profiles!blocks_blocked_id_fkey('
            'id, username, user_id, avatar_url, bio, followers_count, '
            'following_count, read_count, is_private)',
          )
          .eq('blocker_id', profileId)
          .order('created_at', ascending: false);
      return (response as List<dynamic>)
          .map((row) => row['blocked'])
          .whereType<Map<String, dynamic>>()
          .map(UserProfile.fromJson)
          .toList();
    } catch (e) {
      debugPrint('Error fetching blocked profiles: $e');
      return [];
    }
  }

  Future<bool?> fetchCurrentProfilePrivacy() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return null;

    try {
      final profile = await _client!
          .from('profiles')
          .select('is_private')
          .eq('id', profileId)
          .maybeSingle();
      return profile?['is_private'] as bool? ?? false;
    } catch (e) {
      debugPrint('Error fetching profile privacy: $e');
      return null;
    }
  }

  Future<String?> updateCurrentProfilePrivacy({required bool isPrivate}) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) {
      return 'ログイン状態を確認できませんでした。';
    }

    try {
      await _client!
          .from('profiles')
          .update({'is_private': isPrivate})
          .eq('id', profileId);
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('Error updating profile privacy: $e');
      return '鍵アカウント設定を保存できませんでした。データベース更新後にもう一度お試しください。';
    }
  }

  Future<ProfileRelationship> fetchProfileRelationship(
    String targetProfileId,
  ) async {
    final viewerId = activeProfileId;
    if (!_isInitialized || _client == null || viewerId.isEmpty) {
      return const ProfileRelationship(
        isOwnProfile: false,
        followStatus: FollowRelationshipStatus.none,
        blockedByMe: false,
        blockedEitherDirection: false,
      );
    }
    if (viewerId == targetProfileId) {
      return const ProfileRelationship(
        isOwnProfile: true,
        followStatus: FollowRelationshipStatus.none,
        blockedByMe: false,
        blockedEitherDirection: false,
      );
    }

    try {
      final follow = await _client!
          .from('follows')
          .select('status')
          .eq('follower_id', viewerId)
          .eq('following_id', targetProfileId)
          .maybeSingle();
      final ownBlock = await _client!
          .from('blocks')
          .select('blocked_id')
          .eq('blocker_id', viewerId)
          .eq('blocked_id', targetProfileId)
          .maybeSingle();
      final blockedBetween = await _client!.rpc(
        'is_blocked_between',
        params: {'first_profile': viewerId, 'second_profile': targetProfileId},
      );

      final rawStatus = follow?['status']?.toString();
      final followStatus = rawStatus == 'accepted'
          ? FollowRelationshipStatus.accepted
          : rawStatus == 'pending'
          ? FollowRelationshipStatus.pending
          : FollowRelationshipStatus.none;
      return ProfileRelationship(
        isOwnProfile: false,
        followStatus: followStatus,
        blockedByMe: ownBlock != null,
        blockedEitherDirection: blockedBetween == true,
      );
    } catch (e) {
      debugPrint('Error fetching profile relationship: $e');
      return const ProfileRelationship(
        isOwnProfile: false,
        followStatus: FollowRelationshipStatus.none,
        blockedByMe: false,
        blockedEitherDirection: false,
      );
    }
  }

  Future<Map<String, FollowRelationshipStatus>> fetchCurrentFollowStatuses(
    Iterable<String> targetProfileIds,
  ) async {
    final viewerId = activeProfileId;
    final targets = targetProfileIds
        .where((id) => id.isNotEmpty && id != viewerId)
        .toSet()
        .toList(growable: false);
    if (!_isInitialized ||
        _client == null ||
        viewerId.isEmpty ||
        targets.isEmpty) {
      return const <String, FollowRelationshipStatus>{};
    }

    try {
      final response = await _client!
          .from('follows')
          .select('following_id, status')
          .eq('follower_id', viewerId)
          .inFilter('following_id', targets);
      final statuses = <String, FollowRelationshipStatus>{};
      for (final row in response as List<dynamic>) {
        final data = row as Map<String, dynamic>;
        final profileId = data['following_id']?.toString() ?? '';
        final rawStatus = data['status']?.toString();
        if (profileId.isEmpty) continue;
        statuses[profileId] = rawStatus == 'accepted'
            ? FollowRelationshipStatus.accepted
            : rawStatus == 'pending'
            ? FollowRelationshipStatus.pending
            : FollowRelationshipStatus.none;
      }
      return statuses;
    } catch (e) {
      debugPrint('Error fetching follow statuses: $e');
      return const <String, FollowRelationshipStatus>{};
    }
  }

  Future<FollowRelationshipStatus?> followProfile(
    String targetProfileId,
  ) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return null;
    try {
      final result = await _client!.rpc(
        'request_follow',
        params: {'target_profile': targetProfileId},
      );
      notifyListeners();
      return result?.toString() == 'accepted'
          ? FollowRelationshipStatus.accepted
          : FollowRelationshipStatus.pending;
    } catch (e) {
      debugPrint('Error following profile: $e');
      return null;
    }
  }

  Future<bool> unfollowProfile(String targetProfileId) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      await _client!.rpc(
        'unfollow_profile',
        params: {'target_profile': targetProfileId},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error unfollowing profile: $e');
      return false;
    }
  }

  Future<List<UserProfile>> fetchProfileFollowList({
    required String profileId,
    required bool followers,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return [];
    try {
      final response = await _client!.rpc(
        'get_profile_follow_list',
        params: {
          'target_profile': profileId,
          'list_type': followers ? 'followers' : 'following',
        },
      );
      return (response as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(UserProfile.fromJson)
          .toList(growable: false);
    } catch (e) {
      debugPrint('Error fetching profile follow list: $e');
      return [];
    }
  }

  Future<List<UserProfile>> searchProfiles(String query) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return [];
    final normalized = query.trim();
    if (normalized.isEmpty) return [];
    try {
      final response = await _client!.rpc(
        'search_profiles_by_public_identity',
        params: {'search_query': normalized},
      );
      return (response as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(UserProfile.fromJson)
          .toList(growable: false);
    } catch (e) {
      debugPrint('Error searching profiles: $e');
      return [];
    }
  }

  Future<bool> respondToFollowRequest({
    required String requesterProfileId,
    required bool approve,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      await _client!.rpc(
        'respond_follow_request',
        params: {'requester_profile': requesterProfileId, 'approve': approve},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error responding to follow request: $e');
      return false;
    }
  }

  Future<bool> blockProfile(String targetProfileId) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      await _client!.rpc(
        'block_profile',
        params: {'target_profile': targetProfileId},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error blocking profile: $e');
      return false;
    }
  }

  Future<bool> unblockProfile(String targetProfileId) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      await _client!.rpc(
        'unblock_profile',
        params: {'target_profile': targetProfileId},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error unblocking profile: $e');
      return false;
    }
  }

  Future<List<SocialNotification>> fetchNotifications() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return [];

    try {
      final response = await _client!
          .from('notifications')
          .select(
            'id, type, actor_id, post_id, reply_id, read_at, created_at, '
            'actor:profiles!notifications_actor_id_fkey(username, user_id, avatar_url), '
            'post:posts!notifications_post_id_fkey(book_id, book_title)',
          )
          .eq('recipient_id', profileId)
          .order('created_at', ascending: false)
          .limit(100);
      final pendingResponse = await _client!
          .from('follows')
          .select('follower_id')
          .eq('following_id', profileId)
          .eq('status', 'pending');
      final pendingActorIds = (pendingResponse as List<dynamic>)
          .map((row) => row['follower_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      final notifications = <SocialNotification>[];
      final bookCache = <String, String>{};
      for (final raw in response as List<dynamic>) {
        final row = raw as Map<String, dynamic>;
        final actor = row['actor'] as Map<String, dynamic>?;
        final post = row['post'] as Map<String, dynamic>?;
        final rawType = row['type']?.toString();
        final type = switch (rawType) {
          'reaction' => SocialNotificationType.reaction,
          'want_to_read' => SocialNotificationType.wantToRead,
          'reply' => SocialNotificationType.reply,
          'follow_request' => SocialNotificationType.followRequest,
          'new_post' => SocialNotificationType.newPost,
          _ => SocialNotificationType.follow,
        };
        final actorId = row['actor_id']?.toString() ?? '';
        final bookId = post?['book_id']?.toString();
        String? bookTitle;
        bookTitle = post?['book_title']?.toString();
        if ((bookTitle == null || bookTitle.isEmpty) &&
            bookId != null &&
            bookId.isNotEmpty) {
          bookTitle = bookCache[bookId];
          if (bookTitle == null) {
            final book = await RakutenApi.fetchBookById(bookId);
            bookTitle = book?.title ?? bookId;
            bookCache[bookId] = bookTitle;
          }
        }
        notifications.add(
          SocialNotification(
            id: (row['id'] as num).toInt(),
            type: type,
            actorId: actorId,
            actorUsername: actor?['username']?.toString() ?? 'ユーザー',
            actorUserId: actor?['user_id']?.toString() ?? '',
            actorAvatarUrl: actor?['avatar_url']?.toString() ?? '',
            postId: row['post_id']?.toString(),
            replyId: row['reply_id']?.toString(),
            bookId: bookId,
            bookTitle: bookTitle,
            isRead: row['read_at'] != null,
            followRequestPending:
                type == SocialNotificationType.followRequest &&
                pendingActorIds.contains(actorId),
            createdAt:
                DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                DateTime.now(),
          ),
        );
      }
      return notifications;
    } catch (e) {
      debugPrint('Error fetching notifications: $e');
      return [];
    }
  }

  Future<int> fetchUnreadNotificationCount() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return 0;
    try {
      final response = await _client!
          .from('notifications')
          .select('id')
          .eq('recipient_id', profileId)
          .isFilter('read_at', null);
      return (response as List<dynamic>).length;
    } catch (e) {
      debugPrint('Error fetching unread notification count: $e');
      return 0;
    }
  }

  Future<void> markNotificationsRead() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) return;
    try {
      await _client!
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('recipient_id', profileId)
          .isFilter('read_at', null);
      notifyListeners();
    } catch (e) {
      debugPrint('Error marking notifications read: $e');
    }
  }

  Future<bool> hasCurrentLegalConsent({bool forceRefresh = false}) async {
    final userId = activeProfileId;
    if (!_isInitialized || _client == null || userId.isEmpty) return false;
    if (!forceRefresh &&
        _cachedConsentUserId == userId &&
        _hasCurrentLegalConsentCache != null) {
      return _hasCurrentLegalConsentCache!;
    }

    try {
      final consent = await _client!
          .from('legal_consents')
          .select('id')
          .eq('profile_id', userId)
          .eq('bundle_version', LegalDocumentVersions.bundle)
          .maybeSingle();
      _cachedConsentUserId = userId;
      _hasCurrentLegalConsentCache = consent != null;
      return consent != null;
    } catch (e) {
      debugPrint('Error checking legal consent: $e');
      return false;
    }
  }

  Future<String?> acceptCurrentLegalDocuments() async {
    final user = currentUser;
    if (!_isInitialized || _client == null || user == null) {
      return 'ログイン状態を確認できませんでした。';
    }

    try {
      await _ensureProfile(userId: user.id);
      final provider = user.appMetadata['provider']?.toString();
      await _client!.from('legal_consents').insert({
        'profile_id': user.id,
        'bundle_version': LegalDocumentVersions.bundle,
        'terms_version': LegalDocumentVersions.terms,
        'privacy_version': LegalDocumentVersions.privacy,
        'community_guidelines_version':
            LegalDocumentVersions.communityGuidelines,
        'infringement_policy_version': LegalDocumentVersions.infringementPolicy,
        'external_transmission_version':
            LegalDocumentVersions.externalTransmission,
        'auth_provider': provider,
      });
      _cachedConsentUserId = user.id;
      _hasCurrentLegalConsentCache = true;
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('Error saving legal consent: $e');
      return '同意内容を保存できませんでした。データベース更新後にもう一度お試しください。';
    }
  }

  Future<String?> submitContactRequest({
    required String email,
    required String category,
    required String subject,
    required String message,
  }) async {
    if (!_isInitialized || _client == null) {
      return 'お問い合わせ機能を初期化できませんでした。';
    }

    final subjectError = InputSecurityService.validateSafeText(
      subject,
      fieldLabel: '件名',
      maxLength: 120,
    );
    if (subjectError != null) return subjectError;

    final messageError = InputSecurityService.validateSafeText(
      message,
      fieldLabel: 'お問い合わせ内容',
      allowNewLines: true,
      maxLength: 4000,
    );
    if (messageError != null) return messageError;

    try {
      final profileId = activeProfileId;
      await _client!.from('contact_requests').insert({
        'profile_id': profileId.isEmpty ? null : profileId,
        'email': email.trim(),
        'category': category,
        'subject': InputSecurityService.normalizeText(subject, maxLength: 120),
        'message': InputSecurityService.normalizeText(
          message,
          allowNewLines: true,
          maxLength: 4000,
        ),
      });
      return null;
    } catch (e) {
      debugPrint('Error submitting contact request: $e');
      return 'お問い合わせを送信できませんでした。データベース更新後にもう一度お試しください。';
    }
  }

  Future<String?> deleteCurrentAccount() async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return 'ログイン状態を確認できませんでした。';
    }

    try {
      final response = await _client!.functions.invoke(
        'delete-account',
        body: const {'confirmation': true},
      );
      if (response.status < 200 || response.status >= 300) {
        return '退会処理に失敗しました。お問い合わせフォームからご連絡ください。';
      }
      await signOut();
      _cachedConsentUserId = null;
      _hasCurrentLegalConsentCache = null;
      _cachedRegistrationUserId = null;
      _hasCompletedRegistrationCache = null;
      return null;
    } on FunctionException catch (e) {
      debugPrint('Delete account function error: $e');
      return '退会処理に失敗しました。Edge Functionの配備状況を確認してください。';
    } catch (e) {
      debugPrint('Error deleting account: $e');
      return '退会処理に失敗しました。もう一度お試しください。';
    }
  }

  // ----- BOOK QUERIES -----------------------------------------------------
  // NOTE: Book data is now fetched via external APIs, not stored in Supabase.
  // These methods are kept for compatibility but return empty lists.
  Future<List<Book>> fetchBooks() async {
    return [];
  }

  // Updated to avoid querying non-existent 'books' table.
  Future<List<Book>> searchBooks(String query) async {
    if (query.isEmpty) return fetchBooks();
    // No direct books table; return empty list.
    return [];
  }

  Future<List<Book>> fetchBooksByGenre(String genre) async {
    // No direct books table; return empty list.
    return [];
  }

  Future<List<Post>> fetchTimelinePosts() async {
    if (_isInitialized && _client != null) {
      try {
        final response = await _client!
            .from('posts')
            .select(
              '*, profiles:profiles!posts_profile_id_fkey(username, avatar_url, page_color)',
            )
            .order('created_at', ascending: false);
        final data = response as List<dynamic>;
        final posts = _parsePostsSafely(data);
        final enriched = await _enrichPostsWithBookMetadata(posts);
        final visible = await _filterPostsForCurrentViewer(enriched);
        return _arrangeTimelinePosts(visible);
      } catch (e) {
        debugPrint('Error fetching timeline posts with profile join: $e');
        try {
          // Fallback: if relation join fails due RLS/schema mismatch, still show posts.
          final fallback = await _client!
              .from('posts')
              .select('*')
              .order('created_at', ascending: false);
          final posts = _parsePostsSafely(fallback as List<dynamic>);
          final enriched = await _enrichPostsWithBookMetadata(posts);
          final visible = await _filterPostsForCurrentViewer(enriched);
          return _arrangeTimelinePosts(visible);
        } catch (fallbackError) {
          debugPrint('Error fetching timeline posts fallback: $fallbackError');
        }
      }
    }
    return [];
  }

  Future<List<Post>> fetchPostsForBook(
    String bookId, {
    bool excludeCurrentUser = false,
  }) async {
    final normalizedBookId = bookId.trim();
    if (!_isInitialized || _client == null || normalizedBookId.isEmpty) {
      return [];
    }

    Future<List<Post>> prepare(List<dynamic> rows) async {
      final parsed = _parsePostsSafely(rows);
      final enriched = await _enrichPostsWithBookMetadata(parsed);
      final visible = await _filterPostsForCurrentViewer(enriched);
      final viewerId = activeProfileId;
      final otherUsersPosts = viewerId.isNotEmpty
          ? visible
                .where((post) => post.profileId != viewerId)
                .toList(growable: false)
          : <Post>[];
      if (excludeCurrentUser || viewerId.isEmpty) {
        return _arrangeTimelinePosts(
          excludeCurrentUser ? otherUsersPosts : visible,
        );
      }

      final ownPosts =
          visible
              .where((post) => post.profileId == viewerId)
              .toList(growable: false)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final rankedOtherUsersPosts = await _arrangeTimelinePosts(
        otherUsersPosts,
      );
      return [...ownPosts, ...rankedOtherUsersPosts];
    }

    try {
      final response = await _client!
          .from('posts')
          .select(
            '*, profiles:profiles!posts_profile_id_fkey(username, avatar_url, page_color)',
          )
          .eq('book_id', normalizedBookId)
          .order('created_at', ascending: false);
      return prepare(response as List<dynamic>);
    } catch (e) {
      debugPrint('Error fetching posts for book with profile join: $e');
      try {
        final fallback = await _client!
            .from('posts')
            .select('*')
            .eq('book_id', normalizedBookId)
            .order('created_at', ascending: false);
        return prepare(fallback as List<dynamic>);
      } catch (fallbackError) {
        debugPrint('Error fetching posts for book fallback: $fallbackError');
        return [];
      }
    }
  }

  Future<Post?> fetchPostById(String postId) async {
    if (!_isInitialized || _client == null || postId.trim().isEmpty) {
      return null;
    }

    Future<Post?> parseResponse(Map<String, dynamic> row) async {
      final parsed = _parsePostsSafely(<dynamic>[row]);
      if (parsed.isEmpty) return null;
      final enriched = await _enrichPostsWithBookMetadata(parsed);
      final visible = await _filterPostsForCurrentViewer(enriched);
      return visible.isEmpty ? null : visible.first;
    }

    try {
      final response = await _client!
          .from('posts')
          .select(
            '*, profiles:profiles!posts_profile_id_fkey(username, avatar_url, page_color)',
          )
          .eq('id', postId)
          .maybeSingle();
      if (response == null) return null;
      return parseResponse(response);
    } catch (e) {
      debugPrint('Error fetching post by id with profile join: $e');
      try {
        final fallback = await _client!
            .from('posts')
            .select('*')
            .eq('id', postId)
            .maybeSingle();
        if (fallback == null) return null;
        return parseResponse(fallback);
      } catch (fallbackError) {
        debugPrint('Error fetching post by id fallback: $fallbackError');
        return null;
      }
    }
  }

  Future<Map<String, List<PostReply>>> fetchRepliesForPosts(
    List<String> postIds,
  ) async {
    final grouped = <String, List<PostReply>>{};
    if (!_isInitialized || _client == null || postIds.isEmpty) return grouped;

    final filteredIds = postIds.where((id) => id.trim().isNotEmpty).toList();
    if (filteredIds.isEmpty) return grouped;

    try {
      final response = await _client!
          .from('post_replies')
          .select(
            'id, post_id, profile_id, parent_reply_id, message, has_spoiler, created_at, '
            'profiles:profiles!post_replies_profile_id_fkey(username, user_id, avatar_url)',
          )
          .inFilter('post_id', filteredIds)
          .order('created_at', ascending: true);

      final rows = (response as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final blockedProfileIds = await _blockedProfileIdsForCurrentViewer(
        rows.map((row) => row['profile_id']?.toString() ?? ''),
      );

      for (final raw in rows) {
        final reply = PostReply.fromJson(raw);
        if (reply.id.isEmpty || reply.postId.isEmpty) continue;
        if (blockedProfileIds.contains(reply.profileId)) continue;
        grouped.putIfAbsent(reply.postId, () => <PostReply>[]).add(reply);
      }
    } catch (e) {
      debugPrint('Error fetching post replies: $e');
    }

    return grouped;
  }

  Future<String?> createPostReply({
    required String postId,
    required String message,
    String? parentReplyId,
    bool hasSpoiler = false,
  }) async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) {
      return 'ログイン状態を確認できませんでした。';
    }

    final messageError = InputSecurityService.validateReplyMessage(message);
    if (messageError != null) return messageError;

    try {
      await _client!.rpc(
        'create_post_reply',
        params: {
          'target_post': postId,
          'reply_message': InputSecurityService.normalizeReplyMessage(message),
          'target_reply': parentReplyId == null
              ? null
              : int.tryParse(parentReplyId),
          'reply_has_spoiler': hasSpoiler,
        },
      );
      return null;
    } on PostgrestException catch (e) {
      debugPrint(
        'Error creating post reply: code=${e.code}, message=${e.message}, '
        'details=${e.details}, hint=${e.hint}',
      );
      if (e.code == '42501') {
        if (e.message.contains('entitlement')) {
          return '返信は限定コンテンツです';
        }
        return '返信する権限を確認できませんでした。';
      }
      if (e.code == '23514') {
        return '返信内容が制限に抵触しました。本文を見直してください。';
      }
      if (e.code == 'P0002' || e.code == '23503' || e.code == '22P02') {
        return '対象の投稿を確認できませんでした。画面を更新してください。';
      }
      return '返信を投稿できませんでした（${e.code}）。';
    } catch (e) {
      debugPrint('Error creating post reply: $e');
      return '返信を投稿できませんでした。';
    }
  }

  Future<bool> canCreatePostReplies() async {
    if (!_isInitialized ||
        _client == null ||
        activeProfileId.isEmpty ||
        !isAuthenticated) {
      return false;
    }

    try {
      return await _client!.rpc('current_user_can_reply') == true;
    } catch (e) {
      debugPrint('Error checking post reply access: $e');
      return false;
    }
  }

  // Removed duplicate fetchBooksByGenre (books table no longer exists).

  // Duplicate fetchTimelinePosts removed; retained version earlier.

  // ----- USER PROFILE ------------------------------------------------------
  Future<UserProfile> fetchUserProfile(String profileId) async {
    if (_isInitialized && _client != null) {
      try {
        var query = _client!.from('profiles').select();
        query = _looksLikeUuid(profileId)
            ? query.eq('id', profileId)
            : query.eq('user_id', profileId.trim().toLowerCase());
        final response = await query.single();
        final profile = UserProfile.fromJson(response);
        if (profileId == activeProfileId) {
          _activePageColorKey = ProfilePageColors.normalizeKey(
            profile.pageColorKey,
          );
        }
        return profile;
      } catch (e) {
        debugPrint('Error fetching user profile in Supabase: $e');
      }
    }
    // Return a minimal placeholder profile if not initialized.
    return UserProfile(
      id: profileId,
      username: 'unknown',
      userId: '',
      avatarUrl: '',
      bio: '',
      followersCount: 0,
      followingCount: 0,
      readCount: 0,
      isPrivate: false,
    );
  }

  bool _looksLikeUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value.trim());
  }

  // ----- USER COLLECTIONS & FAVORITES --------------------------------------
  // Updated to fetch only book IDs; actual Book details are retrieved via external APIs.
  Future<List<Book>> fetchUserCollections(String profileId) async {
    if (_isInitialized && _client != null) {
      try {
        // A posted review is the source of truth for a completed book. Ordering
        // by the newest post first also defines the bookshelf display order.
        final postRes = await _client!
            .from('posts')
            .select('book_id, created_at')
            .eq('profile_id', profileId)
            .order('created_at', ascending: false);

        final bookIds = <String>[];
        final seenBookIds = <String>{};
        for (final row in (postRes as List<dynamic>)) {
          final id = (row['book_id'] ?? '').toString().trim();
          if (id.isNotEmpty && seenBookIds.add(id)) bookIds.add(id);
        }

        if (bookIds.isEmpty) return [];
        return _resolveBooksByIds(bookIds);
      } catch (e) {
        debugPrint('Error fetching user collection in Supabase: $e');
      }
    }
    return [];
  }

  Future<List<Book>> fetchUserFavorites(String profileId) async {
    if (_isInitialized && _client != null) {
      try {
        final response = await _client!
            .from('favorites')
            .select('book_id, created_at')
            .eq('profile_id', profileId)
            .order('created_at', ascending: false)
            .limit(12);
        final bookIds = (response as List<dynamic>)
            .map((row) => (row['book_id'] ?? '').toString().trim())
            .where((id) => id.isNotEmpty)
            .toList();
        return _resolveBooksByIds(bookIds);
      } catch (e) {
        debugPrint('Error fetching user favorites in Supabase: $e');
      }
    }
    return [];
  }

  Future<List<Book>> fetchUserWantToRead(String profileId) async {
    if (!_isInitialized || _client == null || profileId.isEmpty) return [];
    try {
      final response = await _client!
          .from('want_to_read_books')
          .select(
            'book_id, book_title, book_author, book_cover_url, created_at',
          )
          .eq('profile_id', profileId)
          .order('created_at', ascending: false);
      final rows = (response as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final resolved = await Future.wait(
        rows.map((row) async {
          final id = row['book_id']?.toString() ?? '';
          final apiBook = await RakutenApi.fetchBookById(id);
          if (apiBook != null) return apiBook;
          return Book(
            id: id,
            title: row['book_title']?.toString() ?? id,
            author: row['book_author']?.toString() ?? '',
            publisher: '',
            pubDate: '',
            isbn: id,
            coverUrl: row['book_cover_url']?.toString() ?? '',
          );
        }),
      );
      return resolved.where((book) => book.id.isNotEmpty).toList();
    } catch (e) {
      debugPrint('Error fetching want-to-read shelf: $e');
      return [];
    }
  }

  // 該当箇所（105行目付近から始まるメソッド）をこれに差し替えてください
  Future<List<Post>> fetchUserPosts(String uid) async {
    if (!_isInitialized || _client == null) return [];

    try {
      // 1. Supabaseからは「レビューデータ」と「本のID（book_id）」だけを取得する
      final response = await _client!
          .from('posts')
          .select(
            '*, profiles:profiles!posts_profile_id_fkey(username, avatar_url, page_color)',
          )
          .eq('profile_id', uid)
          .order('created_at', ascending: false);

      // 2. 返ってきた生データを、正しくPostモデルの形に変換する
      final List<dynamic> data = response as List<dynamic>;
      final posts = _parsePostsSafely(data);
      final enriched = await _enrichPostsWithBookMetadata(posts);
      return _filterPostsForCurrentViewer(enriched);
    } catch (e) {
      debugPrint('fetchUserPostsで結合取得エラーが発生しました: $e');
      try {
        final fallback = await _client!
            .from('posts')
            .select('*')
            .eq('profile_id', uid)
            .order('created_at', ascending: false);
        final posts = _parsePostsSafely(fallback as List<dynamic>);
        final enriched = await _enrichPostsWithBookMetadata(posts);
        return _filterPostsForCurrentViewer(enriched);
      } catch (fallbackError) {
        debugPrint('fetchUserPostsフォールバック取得エラー: $fallbackError');
        return [];
      }
    }
  }

  List<Post> _parsePostsSafely(List<dynamic> data) {
    final posts = <Post>[];
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        posts.add(Post.fromJson(raw));
      } catch (e) {
        debugPrint('Skipping malformed post row: $e');
      }
    }
    return posts;
  }

  Future<List<Post>> _enrichPostsWithBookMetadata(List<Post> posts) async {
    if (posts.isEmpty) return posts;

    final cache = <String, Book?>{};

    Future<Book?> getBook(String bookId) async {
      if (cache.containsKey(bookId)) return cache[bookId];
      final found = await RakutenApi.fetchBookById(bookId);
      cache[bookId] = found;
      return found;
    }

    final enriched = <Post>[];
    for (final post in posts) {
      final resolved = await getBook(post.bookId);
      if (resolved == null) {
        enriched.add(post);
        continue;
      }

      enriched.add(
        post.copyWith(
          bookTitle: post.bookTitle.trim().isNotEmpty
              ? post.bookTitle
              : resolved.title,
          bookAuthor: post.bookAuthor.trim().isNotEmpty
              ? post.bookAuthor
              : resolved.author,
          bookCoverUrl: resolved.coverUrl,
        ),
      );
    }
    return _attachReactionState(enriched);
  }

  Future<List<Post>> _filterPostsForCurrentViewer(List<Post> posts) async {
    if (posts.isEmpty) return posts;

    final blockedProfileIds = await _blockedProfileIdsForCurrentViewer(
      posts.map((post) => post.profileId),
    );
    final withoutBlocked = posts
        .where((post) => !blockedProfileIds.contains(post.profileId))
        .toList(growable: false);

    if (await canViewAdultContent()) return withoutBlocked;
    return withoutBlocked
        .where((post) {
          return !post.isAgeRestricted &&
              !ContentSafetyService.containsAdultContentTerms([
                post.bookTitle,
                post.bookAuthor,
                post.comment,
              ]);
        })
        .toList(growable: false);
  }

  Future<Set<String>> _blockedProfileIdsForCurrentViewer(
    Iterable<String> candidateProfileIds,
  ) async {
    final viewerId = activeProfileId;
    if (!_isInitialized || _client == null || viewerId.isEmpty) {
      return const <String>{};
    }

    final candidates = candidateProfileIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && id != viewerId)
        .toSet()
        .toList(growable: false);
    if (candidates.isEmpty) return const <String>{};

    try {
      final blockedByMeResponse = await _client!
          .from('blocks')
          .select('blocked_id')
          .eq('blocker_id', viewerId)
          .inFilter('blocked_id', candidates);

      final blockedMeResponse = await _client!
          .from('blocks')
          .select('blocker_id')
          .eq('blocked_id', viewerId)
          .inFilter('blocker_id', candidates);

      final blockedIds = <String>{};
      for (final row in blockedByMeResponse as List<dynamic>) {
        final id = row['blocked_id']?.toString() ?? '';
        if (id.isNotEmpty) blockedIds.add(id);
      }
      for (final row in blockedMeResponse as List<dynamic>) {
        final id = row['blocker_id']?.toString() ?? '';
        if (id.isNotEmpty) blockedIds.add(id);
      }
      return blockedIds;
    } catch (e) {
      debugPrint('Error loading blocked profile IDs: $e');
      return const <String>{};
    }
  }

  Future<List<Post>> _arrangeTimelinePosts(Iterable<Post> posts) async {
    final followedProfileIds = await _acceptedFollowingProfileIds();
    return TimelineRankingService.arrange(
      posts: posts,
      followedProfileIds: followedProfileIds,
    );
  }

  Future<Set<String>> _acceptedFollowingProfileIds() async {
    final viewerId = activeProfileId;
    if (!_isInitialized ||
        _client == null ||
        viewerId.isEmpty ||
        !isAuthenticated) {
      return const <String>{};
    }

    try {
      final response = await _client!
          .from('follows')
          .select('following_id')
          .eq('follower_id', viewerId)
          .eq('status', 'accepted');
      return (response as List<dynamic>)
          .map((row) => row['following_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (e) {
      debugPrint('Error loading followed profiles for timeline: $e');
      return const <String>{};
    }
  }

  Future<List<Post>> _attachReactionState(List<Post> posts) async {
    if (posts.isEmpty || !_isInitialized || _client == null) return posts;

    try {
      final postIds = posts.map((post) => post.id).toList();
      final response = await _client!
          .from('post_reactions')
          .select('post_id, profile_id, reaction_type')
          .inFilter('post_id', postIds);
      final counts = <String, Map<PostReactionType, int>>{};
      final currentReactions = <String, PostReactionType>{};
      final currentProfileId = activeProfileId;
      for (final raw in response as List<dynamic>) {
        final row = raw as Map<String, dynamic>;
        final postId = row['post_id']?.toString() ?? '';
        if (postId.isEmpty) continue;
        final reaction =
            PostReactionType.fromDatabase(row['reaction_type']?.toString()) ??
            PostReactionType.like;
        final postCounts = counts.putIfAbsent(postId, () => {});
        postCounts[reaction] = (postCounts[reaction] ?? 0) + 1;
        if (row['profile_id']?.toString() == currentProfileId) {
          currentReactions[postId] = reaction;
        }
      }
      var enrichedPosts = posts
          .map(
            (post) => post.copyWith(
              reactionCounts: counts[post.id] ?? const {},
              currentUserReaction: currentReactions[post.id],
            ),
          )
          .toList();
      try {
        final wantResponse = await _client!
            .from('post_want_to_reads')
            .select('post_id, profile_id')
            .inFilter('post_id', postIds);
        final wantCounts = <String, int>{};
        final wantedPostIds = <String>{};
        for (final raw in wantResponse as List<dynamic>) {
          final row = raw as Map<String, dynamic>;
          final postId = row['post_id']?.toString() ?? '';
          if (postId.isEmpty) continue;
          wantCounts[postId] = (wantCounts[postId] ?? 0) + 1;
          if (row['profile_id']?.toString() == currentProfileId) {
            wantedPostIds.add(postId);
          }
        }
        enrichedPosts = enrichedPosts
            .map(
              (post) => post.copyWith(
                wantToReadCount: wantCounts[post.id] ?? 0,
                wantedByCurrentUser: wantedPostIds.contains(post.id),
              ),
            )
            .toList();
      } catch (e) {
        // Keep ordinary reactions available while a new migration is pending.
        debugPrint('Error attaching want-to-read state: $e');
      }
      return enrichedPosts;
    } catch (e) {
      debugPrint('Error attaching reaction state: $e');
      return posts;
    }
  }

  Future<List<Book>> _resolveBooksByIds(List<String> bookIds) async {
    if (bookIds.isEmpty) return [];

    final results = await Future.wait(
      bookIds.map((id) => RakutenApi.fetchBookById(id)),
    );

    final books = <Book>[];
    for (var i = 0; i < bookIds.length; i++) {
      final id = bookIds[i];
      final resolved = results[i];
      if (resolved != null) {
        books.add(resolved);
        continue;
      }

      // Keep unresolved items visible in collections instead of dropping them.
      books.add(
        Book(
          id: id,
          title: id,
          author: '著者情報なし',
          publisher: '',
          pubDate: '',
          isbn: id,
          coverUrl: '',
          ratingAvg: 0,
          genre: '',
          description: '書誌情報を取得できませんでした。',
        ),
      );
    }
    return books;
  }

  Future<void> _upsertReadCollection({
    required String profileId,
    required String bookId,
  }) async {
    await _client!.from('collections').upsert({
      'profile_id': profileId,
      'book_id': bookId,
      'status': 'read',
    }, onConflict: 'profile_id,book_id');
  }

  // ----- ACTIONS -----------------------------------------------------------
  Future<bool> setPostReaction(String postId, PostReactionType reaction) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty || !_isInitialized || _client == null) return false;

    try {
      final existing = await _client!
          .from('post_reactions')
          .select('reaction_type')
          .eq('post_id', postId)
          .eq('profile_id', profileId)
          .maybeSingle();
      if (existing?['reaction_type']?.toString() == reaction.databaseValue) {
        await _client!
            .from('post_reactions')
            .delete()
            .eq('post_id', postId)
            .eq('profile_id', profileId);
      } else {
        await _client!.from('post_reactions').upsert({
          'post_id': postId,
          'profile_id': profileId,
          'reaction_type': reaction.databaseValue,
        }, onConflict: 'post_id,profile_id');
      }
      return true;
    } catch (e) {
      debugPrint('Error setting post reaction: $e');
      return false;
    }
  }

  Future<WantToReadToggleResult> toggleWantToRead({
    required Book book,
    String? sourcePostId,
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) {
      return WantToReadToggleResult.failed;
    }
    try {
      final result = await _client!.rpc(
        'toggle_want_to_read',
        params: {
          'target_book_id': book.id,
          'target_book_title': book.title,
          'target_book_author': book.author,
          'target_book_cover_url': book.coverUrl,
          'source_post_id': sourcePostId,
        },
      );
      notifyListeners();
      switch (result?.toString()) {
        case 'added':
          return WantToReadToggleResult.added;
        case 'removed':
          return WantToReadToggleResult.removed;
        case 'already_read':
          return WantToReadToggleResult.alreadyRead;
        default:
          return WantToReadToggleResult.failed;
      }
    } catch (e) {
      debugPrint('Error toggling want-to-read: $e');
      return WantToReadToggleResult.failed;
    }
  }

  Future<bool> isBookWantedByCurrentUser(String bookId) async {
    if (!_isInitialized || _client == null || activeProfileId.isEmpty) {
      return false;
    }
    try {
      final row = await _client!
          .from('want_to_read_books')
          .select('book_id')
          .eq('profile_id', activeProfileId)
          .eq('book_id', bookId)
          .maybeSingle();
      return row != null;
    } catch (e) {
      debugPrint('Error checking want-to-read state: $e');
      return false;
    }
  }

  Future<List<UserProfile>> fetchPostEngagementUsers({
    required String postId,
    PostReactionType? reaction,
    bool wantToRead = false,
  }) async {
    if (!_isInitialized || _client == null || postId.isEmpty) return [];
    try {
      final List<dynamic> rows;
      if (wantToRead) {
        rows = await _client!
            .from('post_want_to_reads')
            .select('profile_id, created_at')
            .eq('post_id', postId)
            .order('created_at', ascending: false);
      } else {
        if (reaction == null) return [];
        rows = await _client!
            .from('post_reactions')
            .select('profile_id, created_at')
            .eq('post_id', postId)
            .eq('reaction_type', reaction.databaseValue)
            .order('created_at', ascending: false);
      }
      final ids = rows
          .map((row) => row['profile_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (ids.isEmpty) return [];
      final profiles = await _client!
          .from('profiles')
          .select(
            'id, username, user_id, avatar_url, bio, followers_count, '
            'following_count, read_count, is_private, page_color',
          )
          .inFilter('id', ids);
      final byId = <String, UserProfile>{
        for (final raw in profiles as List<dynamic>)
          if (raw is Map<String, dynamic>)
            raw['id'].toString(): UserProfile.fromJson(raw),
      };
      return ids.map((id) => byId[id]).whereType<UserProfile>().toList();
    } catch (e) {
      debugPrint('Error fetching post engagement users: $e');
      return [];
    }
  }

  Future<bool> submitPostReport({
    required String postId,
    required ReportCategory category,
    String details = '',
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    final detailsError = InputSecurityService.validateSafeText(
      details,
      fieldLabel: '報告詳細',
      required: false,
      allowNewLines: true,
      maxLength: 1000,
    );
    if (detailsError != null) return false;
    try {
      final normalizedDetails = InputSecurityService.normalizeText(
        details,
        allowNewLines: true,
        maxLength: 1000,
      );
      await _client!.rpc(
        'submit_post_report',
        params: {
          'target_post': postId,
          'report_category': category.databaseValue,
          'report_details': normalizedDetails.isEmpty
              ? null
              : normalizedDetails,
        },
      );
      return true;
    } catch (e) {
      debugPrint('Error submitting post report: $e');
      return false;
    }
  }

  Future<bool> submitReplyReport({
    required String replyId,
    required ReportCategory category,
    String details = '',
  }) async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    final numericReplyId = int.tryParse(replyId);
    if (numericReplyId == null) return false;
    final detailsError = InputSecurityService.validateSafeText(
      details,
      fieldLabel: '報告詳細',
      required: false,
      allowNewLines: true,
      maxLength: 1000,
    );
    if (detailsError != null) return false;
    try {
      final normalizedDetails = InputSecurityService.normalizeText(
        details,
        allowNewLines: true,
        maxLength: 1000,
      );
      await _client!.rpc(
        'submit_reply_report',
        params: {
          'target_reply': numericReplyId,
          'report_category': category.databaseValue,
          'report_details': normalizedDetails.isEmpty
              ? null
              : normalizedDetails,
        },
      );
      return true;
    } catch (e) {
      debugPrint('Error submitting reply report: $e');
      return false;
    }
  }

  Future<bool> isCurrentUserAdmin() async {
    if (!_isInitialized || _client == null || !isAuthenticated) return false;
    try {
      return await _client!.rpc('is_current_user_admin') == true;
    } catch (e) {
      debugPrint('Error checking administrator access: $e');
      return false;
    }
  }

  Future<AccountSuspensionStatus> fetchCurrentAccountSuspension() async {
    final profileId = activeProfileId;
    if (!_isInitialized || _client == null || profileId.isEmpty) {
      return const AccountSuspensionStatus(
        isSuspended: false,
        reason: '',
        suspendedAt: null,
      );
    }
    try {
      final profile = await _client!
          .from('profiles')
          .select('is_suspended')
          .eq('id', profileId)
          .single();
      final suspension = await _client!
          .from('account_suspensions')
          .select('reason, suspended_at')
          .eq('profile_id', profileId)
          .maybeSingle();
      return AccountSuspensionStatus(
        isSuspended: profile['is_suspended'] == true,
        reason: suspension?['reason']?.toString() ?? '',
        suspendedAt: DateTime.tryParse(
          suspension?['suspended_at']?.toString() ?? '',
        ),
      );
    } catch (e) {
      debugPrint('Error fetching account suspension: $e');
      return const AccountSuspensionStatus(
        isSuspended: false,
        reason: '',
        suspendedAt: null,
      );
    }
  }

  Future<List<ModerationReport>> fetchModerationReports() async {
    if (!await isCurrentUserAdmin() || _client == null) return [];
    try {
      final response = await _client!
          .from('moderation_reports')
          .select(
            'id, post_id, reply_id, category, details, status, resolution, created_at, '
            'post_snapshot, reply_snapshot, '
            'reporter:profiles!moderation_reports_reporter_id_fkey(username), '
            'reported:profiles!moderation_reports_reported_profile_id_fkey('
            'id, username, user_id, is_suspended)',
          )
          .order('created_at', ascending: false)
          .limit(200);

      return (response as List<dynamic>).map((raw) {
        final row = raw as Map<String, dynamic>;
        final reporter = row['reporter'] as Map<String, dynamic>?;
        final reported = row['reported'] as Map<String, dynamic>?;
        final snapshot = row['post_snapshot'] as Map<String, dynamic>? ?? {};
        final replySnapshot =
            row['reply_snapshot'] as Map<String, dynamic>? ?? {};
        return ModerationReport(
          id: (row['id'] as num).toInt(),
          reporterUsername: reporter?['username']?.toString() ?? '退会済みユーザー',
          reportedProfileId:
              reported?['id']?.toString() ??
              snapshot['profile_id']?.toString() ??
              '',
          reportedUsername: reported?['username']?.toString() ?? '退会済みユーザー',
          reportedUserId: reported?['user_id']?.toString() ?? '',
          reportedAccountSuspended: reported?['is_suspended'] == true,
          postId: row['post_id']?.toString(),
          replyId: row['reply_id']?.toString(),
          bookId: snapshot['book_id']?.toString() ?? '',
          review: snapshot['review']?.toString() ?? '',
          replyMessage: replySnapshot['message']?.toString() ?? '',
          category: ReportCategory.fromDatabase(row['category']?.toString()),
          details: row['details']?.toString() ?? '',
          status: row['status']?.toString() ?? 'open',
          resolution: row['resolution']?.toString() ?? '',
          createdAt:
              DateTime.tryParse(row['created_at']?.toString() ?? '') ??
              DateTime.now(),
        );
      }).toList();
    } catch (e) {
      debugPrint('Error fetching moderation reports: $e');
      return [];
    }
  }

  Future<bool> adminResolveReport(int reportId) async {
    if (!_isInitialized || _client == null) return false;
    try {
      await _client!.rpc(
        'admin_resolve_report',
        params: {'target_report': reportId, 'resolution_note': 'dismissed'},
      );
      return true;
    } catch (e) {
      debugPrint('Error resolving report: $e');
      return false;
    }
  }

  Future<bool> adminDeleteReportedPost(int reportId) async {
    if (!_isInitialized || _client == null) return false;
    try {
      await _client!.rpc(
        'admin_delete_reported_post',
        params: {'target_report': reportId},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error deleting reported post: $e');
      return false;
    }
  }

  Future<bool> adminDeleteReportedReply(int reportId) async {
    if (!_isInitialized || _client == null) return false;
    try {
      await _client!.rpc(
        'admin_delete_reported_reply',
        params: {'target_report': reportId},
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error deleting reported reply: $e');
      return false;
    }
  }

  Future<bool> adminSetAccountSuspension({
    required String profileId,
    required bool suspended,
    String reason = '',
  }) async {
    if (!_isInitialized || _client == null || profileId.isEmpty) return false;
    final reasonError = InputSecurityService.validateSafeText(
      reason,
      fieldLabel: '停止理由',
      required: false,
      allowNewLines: true,
      maxLength: 500,
    );
    if (reasonError != null) return false;
    try {
      final normalizedReason = InputSecurityService.normalizeText(
        reason,
        allowNewLines: true,
        maxLength: 500,
      );
      await _client!.rpc(
        'admin_set_account_suspension',
        params: {
          'target_profile': profileId,
          'suspend': suspended,
          'reason': normalizedReason.isEmpty ? null : normalizedReason,
        },
      );
      return true;
    } catch (e) {
      debugPrint('Error changing account suspension: $e');
      return false;
    }
  }

  Future<bool> adminDeleteAccount({
    required String profileId,
    required String reason,
  }) async {
    if (!_isInitialized ||
        _client == null ||
        !isAuthenticated ||
        profileId.isEmpty) {
      return false;
    }
    try {
      final reasonError = InputSecurityService.validateSafeText(
        reason,
        fieldLabel: '削除理由',
        allowNewLines: true,
        maxLength: 500,
      );
      if (reasonError != null) return false;

      final normalizedReason = InputSecurityService.normalizeText(
        reason,
        allowNewLines: true,
        maxLength: 500,
      );
      final response = await _client!.functions.invoke(
        'admin-delete-account',
        body: {
          'targetProfileId': profileId,
          'reason': normalizedReason,
          'confirmation': 'DELETE',
        },
      );
      if (response.status < 200 || response.status >= 300) return false;
      notifyListeners();
      return true;
    } on FunctionException catch (e) {
      debugPrint('Admin delete account function error: $e');
      return false;
    } catch (e) {
      debugPrint('Error deleting account as administrator: $e');
      return false;
    }
  }

  Future<bool> markBookAsRead({required String bookId}) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty) {
      debugPrint('Cannot mark book as read: no authenticated user.');
      return false;
    }
    if (_isInitialized && _client != null) {
      try {
        await _upsertReadCollection(profileId: profileId, bookId: bookId);
        notifyListeners();
        return true;
      } catch (e) {
        debugPrint('Error marking book as read in Supabase: $e');
      }
    }
    debugPrint('Supabase not initialized – collection not updated.');
    return false;
  }

  Future<bool> isBookReadByCurrentUser({required String bookId}) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty || !_isInitialized || _client == null) {
      return false;
    }

    try {
      final collectionRes = await _client!
          .from('collections')
          .select('book_id')
          .eq('profile_id', profileId)
          .eq('book_id', bookId)
          .eq('status', 'read')
          .limit(1);

      if ((collectionRes as List<dynamic>).isNotEmpty) {
        return true;
      }

      // Fallback for legacy data where read books may exist only as posts.
      final postRes = await _client!
          .from('posts')
          .select('book_id')
          .eq('profile_id', profileId)
          .eq('book_id', bookId)
          .limit(1);

      return (postRes as List<dynamic>).isNotEmpty;
    } catch (e) {
      debugPrint('Error checking read status in Supabase: $e');
      return false;
    }
  }

  Future<bool> createPost({
    required Book book,
    required double rating,
    required String comment,
    required bool isSpoiler,
  }) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty) {
      debugPrint('Cannot create post: no authenticated user.');
      return false;
    }
    if (await isBookReadByCurrentUser(bookId: book.id)) {
      debugPrint('Cannot create post: this user already posted this book.');
      return false;
    }
    final commentError = InputSecurityService.validateSafeText(
      comment,
      fieldLabel: '感想',
      allowNewLines: true,
      maxLength: 3000,
    );
    if (commentError != null) {
      debugPrint(commentError);
      return false;
    }

    final normalizedComment = InputSecurityService.normalizeText(
      comment,
      allowNewLines: true,
      maxLength: 3000,
    );

    final isAgeRestricted =
        ContentSafetyService.isAdultBook(book) ||
        ContentSafetyService.containsAdultContentTerms([normalizedComment]);
    if (isAgeRestricted && !await canViewAdultContent()) {
      debugPrint('Cannot create an age-restricted post for a minor.');
      return false;
    }
    if (_isInitialized && _client != null) {
      try {
        await _client!.from('posts').insert({
          'profile_id': profileId,
          'book_id': book.id,
          'book_title': book.title,
          'book_author': book.author,
          'book_publisher': book.publisher,
          'book_description': book.description,
          'is_age_restricted': isAgeRestricted,
          'rating': rating,
          'comment': normalizedComment,
          'is_spoiler': isSpoiler,
        });

        // Any completed post is also tracked in collections as 'read'.
        await _upsertReadCollection(profileId: profileId, bookId: book.id);

        notifyListeners();
        return true;
      } catch (e) {
        debugPrint('Error inserting post in Supabase: $e');
      }
    }
    debugPrint('Supabase not initialized – post not created.');
    return false;
  }

  Future<bool> deleteOwnPost(String postId) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty || !_isInitialized || _client == null) return false;

    try {
      final deletedRows = await _client!
          .from('posts')
          .delete()
          .eq('id', postId)
          .eq('profile_id', profileId)
          .select('id');
      final deleted = (deletedRows as List<dynamic>).isNotEmpty;
      if (deleted) notifyListeners();
      return deleted;
    } catch (e) {
      debugPrint('Error deleting own post in Supabase: $e');
      return false;
    }
  }

  Future<bool> updateOwnPost({
    required Post post,
    required double rating,
    required String comment,
    required bool isSpoiler,
  }) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty ||
        post.profileId != profileId ||
        !_isInitialized ||
        _client == null) {
      return false;
    }

    final commentError = InputSecurityService.validateSafeText(
      comment,
      fieldLabel: '感想',
      allowNewLines: true,
      maxLength: 3000,
    );
    if (commentError != null) return false;

    final trimmedComment = InputSecurityService.normalizeText(
      comment,
      allowNewLines: true,
      maxLength: 3000,
    );
    if (trimmedComment.isEmpty || rating < 1 || rating > 5) return false;

    final isAgeRestricted =
        post.isAgeRestricted ||
        ContentSafetyService.containsAdultContentTerms([trimmedComment]);
    if (isAgeRestricted && !await canViewAdultContent()) return false;

    try {
      final editedAt = DateTime.now().toUtc().toIso8601String();
      final updatedRows = await _client!
          .from('posts')
          .update({
            'rating': rating,
            'comment': trimmedComment,
            'is_spoiler': isSpoiler,
            'is_age_restricted': isAgeRestricted,
            'edited_at': editedAt,
          })
          .eq('id', post.id)
          .eq('profile_id', profileId)
          .select('id');
      final updated = (updatedRows as List<dynamic>).isNotEmpty;
      if (updated) notifyListeners();
      return updated;
    } catch (e) {
      debugPrint('Error updating own post in Supabase: $e');
      return false;
    }
  }

  Future<bool> isBookFavoritedByCurrentUser(String bookId) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty || !_isInitialized || _client == null) return false;
    try {
      final response = await _client!
          .from('favorites')
          .select('book_id')
          .eq('profile_id', profileId)
          .eq('book_id', bookId)
          .maybeSingle();
      return response != null;
    } catch (e) {
      debugPrint('Error checking favorite in Supabase: $e');
      return false;
    }
  }

  Future<FavoriteToggleResult> toggleFavorite(String bookId) async {
    final profileId = activeProfileId;
    if (profileId.isEmpty) {
      debugPrint('Cannot toggle favorite: no authenticated user.');
      return FavoriteToggleResult.failed;
    }
    var favoriteLimit = standardFavoriteLimit;
    if (_isInitialized && _client != null) {
      try {
        // Determine if already favorited
        final favRes = await _client!
            .from('favorites')
            .select('book_id')
            .eq('profile_id', profileId)
            .eq('book_id', bookId);
        final isFav = (favRes as List).isNotEmpty;
        if (isFav) {
          await _client!
              .from('favorites')
              .delete()
              .eq('profile_id', profileId)
              .eq('book_id', bookId);
          notifyListeners();
          return FavoriteToggleResult.removed;
        } else {
          final postRows = await _client!
              .from('posts')
              .select('id')
              .eq('profile_id', profileId)
              .eq('book_id', bookId)
              .limit(1);
          if ((postRows as List<dynamic>).isEmpty) {
            return FavoriteToggleResult.requiresRead;
          }
          favoriteLimit = await fetchCurrentFavoriteLimit();
          final existingFavorites = await _client!
              .from('favorites')
              .select('book_id')
              .eq('profile_id', profileId)
              .limit(favoriteLimit);
          if ((existingFavorites as List<dynamic>).length >= favoriteLimit) {
            return favoriteLimit == subscriberFavoriteLimit
                ? FavoriteToggleResult.subscriberLimitReached
                : FavoriteToggleResult.standardLimitReached;
          }
          await _client!.from('favorites').insert({
            'profile_id': profileId,
            'book_id': bookId,
          });
          notifyListeners();
          return FavoriteToggleResult.added;
        }
      } catch (e) {
        debugPrint('Error toggling favorite in Supabase: $e');
        if (e.toString().contains('favorite_limit_reached')) {
          return favoriteLimit == subscriberFavoriteLimit
              ? FavoriteToggleResult.subscriberLimitReached
              : FavoriteToggleResult.standardLimitReached;
        }
        if (e.toString().contains('favorite_requires_post')) {
          return FavoriteToggleResult.requiresRead;
        }
      }
    }
    debugPrint('Supabase not initialized – favorite not toggled.');
    return FavoriteToggleResult.failed;
  }

  Future<int> fetchCurrentFavoriteLimit() async {
    if (!_isInitialized || _client == null || activeProfileId.isEmpty) {
      return standardFavoriteLimit;
    }
    try {
      final response = await _client!.rpc('current_user_favorite_limit');
      final parsed = response is num
          ? response.toInt()
          : int.tryParse(response?.toString() ?? '');
      return parsed == subscriberFavoriteLimit
          ? subscriberFavoriteLimit
          : standardFavoriteLimit;
    } catch (e) {
      debugPrint('Error fetching favorite limit from Supabase: $e');
      return standardFavoriteLimit;
    }
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }
}
