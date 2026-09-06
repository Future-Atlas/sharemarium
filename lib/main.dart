import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'config/app_environment.dart';
import 'services/supabase_service.dart';
import 'services/theme_service.dart';
import 'models/profile_page_color.dart';
import 'screens/book_list_screen.dart';
import 'screens/user_profile_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/terms_screen.dart';
import 'screens/privacy_policy_screen.dart';
import 'screens/community_guidelines_screen.dart';
import 'screens/infringement_policy_screen.dart';
import 'screens/external_transmission_screen.dart';
import 'screens/legal_consent_screen.dart';
import 'screens/account_settings_screen.dart';
import 'screens/contact_screen.dart';
import 'screens/profile_onboarding_screen.dart';
import 'screens/moderation_screen.dart';
import 'screens/account_suspension_gate.dart';
import 'screens/notifications_screen.dart';

enum _HeaderMenuAction { home, myPage, settings, help, moderation, logout }

final supabaseService = SupabaseService();
final themeService = ThemeService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await themeService.initialize();

  // Initialize Supabase service
  await supabaseService.initialize(
    url: AppEnvironmentConfig.supabaseUrl,
    anonKey: AppEnvironmentConfig.supabaseAnonKey,
    redirectUrl: AppEnvironmentConfig.supabaseRedirectUrl,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SupabaseService>.value(value: supabaseService),
        ChangeNotifierProvider<ThemeService>.value(value: themeService),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isDarkMode = context.watch<ThemeService>().isDarkMode;

    return MaterialApp(
      title: 'Sharemarium',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.unknown,
        },
      ),

      // Premium Light Theme Design System
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSansJp().fontFamily,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        primaryColor: const Color(0xFFD00303), // Brand Red
        cardColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD00303),
          brightness: Brightness.light,
          primary: const Color(0xFFD00303),
          secondary: const Color(0xFF264653), // Slate blue
          surface: Colors.white,
        ),
        textTheme: GoogleFonts.notoSansJpTextTheme(ThemeData.light().textTheme)
            .copyWith(
              titleLarge: TextStyle(
                fontFamily: GoogleFonts.notoSansJp().fontFamily,
                fontWeight: FontWeight.w900,
                color: const Color(0xFF212529),
              ),
              bodyMedium: TextStyle(
                fontFamily: GoogleFonts.notoSansJp().fontFamily,
                color: const Color(0xFF495057),
              ),
            ),
        dividerColor: const Color(0xFFE9ECEF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
        ),
      ),

      // Premium Dark Theme Design System
      darkTheme: ThemeData(
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSansJp().fontFamily,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: const Color(0xFFD00303),
        cardColor: const Color(0xFF121212),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD00303),
          brightness: Brightness.dark,
          primary: const Color(0xFFD00303),
          secondary: const Color(0xFF4EA8DE),
          surface: Colors.black,
        ),
        textTheme: GoogleFonts.notoSansJpTextTheme(ThemeData.dark().textTheme)
            .copyWith(
              titleLarge: TextStyle(
                fontFamily: GoogleFonts.notoSansJp().fontFamily,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
              bodyMedium: TextStyle(
                fontFamily: GoogleFonts.notoSansJp().fontFamily,
                color: const Color(0xFFCED4DA),
              ),
            ),
        dividerColor: const Color(0xFF2A3447),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      routes: {
        '/login': (context) => const AuthScreen(),
        '/terms': (context) => const TermsScreen(),
        '/privacy': (context) => const PrivacyPolicyScreen(),
        '/community-guidelines': (context) => const CommunityGuidelinesScreen(),
        '/infringement-policy': (context) => const InfringementPolicyScreen(),
        '/external-transmission': (context) =>
            const ExternalTransmissionScreen(),
        '/contact': (context) => const ContactScreen(),
      },
      onUnknownRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const AccountSuspensionGate(
          child: LegalConsentGate(
            child: ProfileOnboardingGate(child: MainNavigationShell()),
          ),
        ),
      ),
      home: const AccountSuspensionGate(
        child: LegalConsentGate(
          child: ProfileOnboardingGate(child: MainNavigationShell()),
        ),
      ),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell>
    with WidgetsBindingObserver {
  static const Set<String> _transientQueryKeys = {
    'code',
    'state',
    'error',
    'error_code',
    'error_description',
    'provider_token',
    'refresh_token',
    'token_type',
    'expires_in',
    'privacy_password_recovery',
  };

  late int _currentScreenIndex;
  late bool _openPrivacyPasswordRecovery;
  String? _adminCheckedUserId;
  bool _isAdmin = false;
  String? _viewedProfileId;
  String? _viewedProfileUserId;
  String? _viewedProfileColorKey;

  String? _genreFromPath(String path) {
    if (path == '/genre/recommended') return 'recommended';
    if (path == '/genre/western') return 'western';
    if (path == '/genre/popular') return 'popular';
    return null;
  }

  bool _isOpeningLogin = false;

  Uri _normalizedFragmentUri(String fragment) {
    var value = fragment;
    if (value.startsWith('/#/')) {
      value = value.substring(2);
    }
    if (value == '/#' || value == '/#/') {
      value = '/';
    }
    if (value.isEmpty) {
      value = '/';
    }
    if (!value.startsWith('/')) {
      value = '/$value';
    }
    return Uri.parse(value);
  }

  String _currentAppPathFromUri(Uri uri) {
    final fragment = uri.fragment;
    if (fragment.startsWith('/')) {
      return _normalizedFragmentUri(fragment).path;
    }
    return uri.path;
  }

  bool _hasTransientQuery(Uri uri) {
    for (final key in uri.queryParameters.keys) {
      if (_transientQueryKeys.contains(key)) return true;
    }
    if (uri.fragment.startsWith('/')) {
      for (final key in _normalizedFragmentUri(
        uri.fragment,
      ).queryParameters.keys) {
        if (_transientQueryKeys.contains(key)) return true;
      }
    }
    return false;
  }

  Map<String, String> _sanitizedQuery(Uri uri) {
    final sanitized = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      if (_transientQueryKeys.contains(key)) return;
      sanitized[key] = value;
    });
    return sanitized;
  }

  Map<String, String> _sanitizedFragmentQuery(Uri uri) {
    final sanitized = <String, String>{};
    if (!uri.fragment.startsWith('/')) return sanitized;
    _normalizedFragmentUri(uri.fragment).queryParameters.forEach((key, value) {
      if (_transientQueryKeys.contains(key)) return;
      sanitized[key] = value;
    });
    return sanitized;
  }

  int _screenIndexFromPath(String path) {
    if ((path.startsWith('/users/') ||
            path.startsWith('/user/') ||
            path.startsWith('/profile/')) &&
        path.length > '/users/'.length) {
      return 5;
    }
    if (path.startsWith('/book/') || path.startsWith('/genre/')) {
      return 0;
    }
    switch (path) {
      case '/mypage':
      case '/profile':
      case '/user':
        return 1;
      case '/settings':
        return 2;
      case '/help':
        return 3;
      case '/moderation':
        return 4;
      case '/terms':
        return 6;
      case '/privacy':
        return 7;
      case '/community-guidelines':
        return 8;
      case '/infringement-policy':
        return 9;
      case '/external-transmission':
        return 10;
      case '/contact':
        return 11;
      default:
        return _openPrivacyPasswordRecovery ? 2 : 0;
    }
  }

  String _pathForScreenIndex(int index) {
    switch (index) {
      case 1:
        return '/mypage';
      case 2:
        return '/settings';
      case 3:
        return '/help';
      case 4:
        return '/moderation';
      case 5:
        final profileId = _viewedProfileId;
        final publicUserId = _viewedProfileUserId;
        final urlId = publicUserId == null || publicUserId.isEmpty
            ? profileId
            : publicUserId;
        return urlId == null || urlId.isEmpty
            ? '/'
            : '/users/${Uri.encodeComponent(urlId)}';
      case 6:
        return '/terms';
      case 7:
        return '/privacy';
      case 8:
        return '/community-guidelines';
      case 9:
        return '/infringement-policy';
      case 10:
        return '/external-transmission';
      case 11:
        return '/contact';
      default:
        return '/';
    }
  }

  void _syncBrowserUrlForScreen(int index, {bool replace = false}) {
    final targetPath = _pathForScreenIndex(index);
    final currentUri = Uri.base;
    final currentAppPath = _currentAppPathFromUri(currentUri);
    final hasTransientQuery = _hasTransientQuery(currentUri);
    if (currentAppPath == targetPath && !hasTransientQuery) return;

    final sanitizedQuery = _sanitizedQuery(currentUri);
    final sanitizedFragmentQuery = _sanitizedFragmentQuery(currentUri);

    final targetUri = currentUri.fragment.startsWith('/')
        ? Uri(
            path: currentUri.path.isEmpty ? '/' : currentUri.path,
            queryParameters: sanitizedQuery.isEmpty ? null : sanitizedQuery,
            fragment: Uri(
              path: targetPath,
              queryParameters: sanitizedFragmentQuery.isEmpty
                  ? null
                  : sanitizedFragmentQuery,
            ).toString(),
          )
        : Uri(
            path: targetPath,
            queryParameters: sanitizedQuery.isEmpty ? null : sanitizedQuery,
          );

    SystemNavigator.routeInformationUpdated(uri: targetUri, replace: replace);
  }

  void _setCurrentScreenIndex(
    int index, {
    bool replaceUrl = false,
    bool syncUrl = true,
  }) {
    if (_currentScreenIndex != index) {
      setState(() {
        _currentScreenIndex = index;
      });
    }
    if (syncUrl) {
      _syncBrowserUrlForScreen(index, replace: replaceUrl);
    }
  }

  void _applyScreenStateFromPath(
    String path, {
    bool replaceUrl = false,
    bool syncUrl = true,
  }) {
    final index = _screenIndexFromPath(path);
    String? nextViewedProfileId;
    if (index == 5) {
      final prefix = path.startsWith('/profile/')
          ? '/profile/'
          : path.startsWith('/user/')
          ? '/user/'
          : '/users/';
      final encodedProfileId = path.substring(prefix.length);
      if (encodedProfileId.isNotEmpty) {
        nextViewedProfileId = Uri.decodeComponent(encodedProfileId);
      }
    }

    if (_currentScreenIndex != index ||
        _viewedProfileId != nextViewedProfileId) {
      setState(() {
        _currentScreenIndex = index;
        _viewedProfileId = nextViewedProfileId;
        if (index != 5) {
          _viewedProfileUserId = null;
          _viewedProfileColorKey = null;
        } else {
          _viewedProfileUserId = null;
          _viewedProfileColorKey = null;
        }
      });
    }

    if (syncUrl) {
      _syncBrowserUrlForScreen(index, replace: replaceUrl);
    }

    if (index == 5 && nextViewedProfileId != null) {
      _loadViewedProfileHeader(nextViewedProfileId);
    }
  }

  void _applyRouteFromUri(Uri uri, {bool replaceUrl = false}) {
    final currentPath = _currentAppPathFromUri(uri);
    _applyScreenStateFromPath(currentPath, replaceUrl: replaceUrl);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final currentUri = Uri.base;
    final fragmentQuery = currentUri.fragment.startsWith('/')
        ? _normalizedFragmentUri(currentUri.fragment).queryParameters
        : const <String, String>{};
    _openPrivacyPasswordRecovery =
        (currentUri.queryParameters['privacy_password_recovery'] == '1') ||
        (fragmentQuery['privacy_password_recovery'] == '1');
    _currentScreenIndex = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyRouteFromUri(currentUri, replaceUrl: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final uri = routeInformation.uri;
    _applyRouteFromUri(uri, replaceUrl: _hasTransientQuery(uri));
    return true;
  }

  Future<void> _loadViewedProfileHeader(String profileId) async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    final profile = await service.fetchUserProfile(profileId);
    if (!mounted || _viewedProfileId != profileId) return;
    setState(() {
      _viewedProfileUserId = profile.userId;
      _viewedProfileColorKey = profile.pageColorKey;
    });
    _syncBrowserUrlForScreen(5, replace: true);
  }

  Future<void> _openUserProfile(String profileId) async {
    if (profileId.isEmpty) return;
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (profileId == service.activeProfileId) {
      await _goToProfile();
      return;
    }
    setState(() {
      _viewedProfileId = profileId;
      _viewedProfileUserId = null;
      _viewedProfileColorKey = null;
      _currentScreenIndex = 5;
    });
    _syncBrowserUrlForScreen(5);
    await _loadViewedProfileHeader(profileId);
  }

  Future<void> _goToProfile() async {
    final service = Provider.of<SupabaseService>(context, listen: false);
    if (!service.isAuthenticated) {
      if (_isOpeningLogin) return;
      _isOpeningLogin = true;
      final result = await Navigator.of(context).pushNamed('/login');
      _isOpeningLogin = false;
      if (!mounted) return;
      if (result != true && !service.isAuthenticated) {
        if (_currentScreenIndex == 1) _goToBookList();
        return;
      }
    }

    await service.ensureCurrentUserProfile();
    if (!mounted) return;
    _viewedProfileId = null;
    _viewedProfileUserId = null;
    _viewedProfileColorKey = null;
    _setCurrentScreenIndex(1);
  }

  void _goToBookList() {
    _viewedProfileId = null;
    _viewedProfileUserId = null;
    _viewedProfileColorKey = null;
    _setCurrentScreenIndex(0);
  }

  void _openHelpPath(String path) {
    _applyScreenStateFromPath(path);
  }

  Future<void> _onMenuAction(_HeaderMenuAction action) async {
    switch (action) {
      case _HeaderMenuAction.home:
        _goToBookList();
        break;
      case _HeaderMenuAction.myPage:
        await _goToProfile();
        break;
      case _HeaderMenuAction.settings:
        _setCurrentScreenIndex(2);
        break;
      case _HeaderMenuAction.help:
        _setCurrentScreenIndex(3);
        break;
      case _HeaderMenuAction.moderation:
        if (_isAdmin) _setCurrentScreenIndex(4);
        break;
      case _HeaderMenuAction.logout:
        final service = Provider.of<SupabaseService>(context, listen: false);
        await service.signOut();
        if (!mounted) return;
        _goToBookList();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ログアウトしました。')));
        break;
    }
  }

  String _currentHeaderTitle() {
    switch (_currentScreenIndex) {
      case 1:
        return 'マイページ';
      case 2:
        return '設定';
      case 3:
        return 'ヘルプ';
      case 4:
        return '管理';
      case 5:
        final userId = _viewedProfileUserId;
        return userId == null || userId.isEmpty ? 'プロフィール' : '@$userId';
      case 6:
        return '利用規約';
      case 7:
        return 'プライバシーポリシー';
      case 8:
        return 'コミュニティガイドライン';
      case 9:
        return '権利侵害・通報ポリシー';
      case 10:
        return '外部送信に関する公表事項';
      case 11:
        return 'お問い合わせ';
      default:
        return 'ホーム';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SupabaseService>(
      builder: (context, service, _) {
        final currentUserId = service.activeProfileId;
        if (_adminCheckedUserId != currentUserId) {
          _adminCheckedUserId = currentUserId;
          _isAdmin = false;
          if (currentUserId.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              service.refreshActiveProfileAppearance();
            });
          }
        }
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        final ownHeaderColor = ProfilePageColors.colorFor(
          service.activePageColorKey,
        );
        final headerColor = _currentScreenIndex == 5
            ? ProfilePageColors.colorFor(_viewedProfileColorKey)
            : ownHeaderColor;
        final menuIconColor = isDarkMode ? Colors.white : Colors.black;
        final popupMenuTextColor = isDarkMode ? Colors.black : Colors.black;
        final headerSideWidth = service.isAuthenticated ? 146.0 : 104.0;

        if (!service.isAuthenticated &&
            _currentScreenIndex == 1 &&
            !_isOpeningLogin) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _goToProfile();
          });
        }

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  height: 60,
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: isDarkMode ? Colors.black : Colors.white,
                    border: Border.all(color: headerColor, width: 3),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: headerSideWidth,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: PopupMenuButton<_HeaderMenuAction>(
                            tooltip: 'メニュー',
                            icon: Icon(
                              Icons.menu,
                              size: 38,
                              color: menuIconColor,
                            ),
                            position: PopupMenuPosition.under,
                            color: Colors.white,
                            onSelected: _onMenuAction,
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: _HeaderMenuAction.home,
                                child: Text(
                                  'ホーム',
                                  style: TextStyle(
                                    fontSize: 28 / 2,
                                    color: popupMenuTextColor,
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: _HeaderMenuAction.myPage,
                                child: Text(
                                  'マイページ',
                                  style: TextStyle(
                                    fontSize: 28 / 2,
                                    color: popupMenuTextColor,
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: _HeaderMenuAction.settings,
                                child: Text(
                                  '設定',
                                  style: TextStyle(
                                    fontSize: 28 / 2,
                                    color: popupMenuTextColor,
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: _HeaderMenuAction.help,
                                child: Text(
                                  'ヘルプ',
                                  style: TextStyle(
                                    fontSize: 28 / 2,
                                    color: popupMenuTextColor,
                                  ),
                                ),
                              ),
                              if (_isAdmin)
                                PopupMenuItem(
                                  value: _HeaderMenuAction.moderation,
                                  child: Text(
                                    '管理',
                                    style: TextStyle(
                                      fontSize: 28 / 2,
                                      color: popupMenuTextColor,
                                    ),
                                  ),
                                ),
                              if (service.isAuthenticated)
                                PopupMenuItem(
                                  value: _HeaderMenuAction.logout,
                                  child: Text(
                                    'ログアウト',
                                    style: TextStyle(
                                      fontSize: 28 / 2,
                                      color: popupMenuTextColor,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _currentHeaderTitle(),
                              style: TextStyle(
                                color: headerColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: headerSideWidth,
                        height: 36,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (service.isAuthenticated)
                              SizedBox(
                                width: 42,
                                child: NotificationBellButton(
                                  onOpenProfile: _openUserProfile,
                                ),
                              ),
                            SizedBox(
                              width: 104,
                              height: 36,
                              child: ElevatedButton.icon(
                                onPressed: _goToProfile,
                                icon: const Icon(
                                  Icons.person_outline,
                                  size: 16,
                                ),
                                label: const Text(
                                  'マイページ',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDarkMode
                                      ? Colors.black
                                      : Colors.white,
                                  foregroundColor: ownHeaderColor,
                                  side: BorderSide(
                                    color: ownHeaderColor,
                                    width: 1.5,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  elevation: 0,
                                  shape: const StadiumBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _currentScreenIndex == 0
                        ? BookListScreen(
                            key: const ValueKey('BookListScreen'),
                            onOpenUserProfile: _openUserProfile,
                            initialGenre: _genreFromPath(
                              _currentAppPathFromUri(Uri.base),
                            ),
                          )
                        : _currentScreenIndex == 1
                        ? UserProfileScreen(
                            key: const ValueKey('UserProfileScreen'),
                            onBack: _goToBookList,
                            showAppBar: false,
                          )
                        : _currentScreenIndex == 2
                        ? AccountSettingsScreen(
                            key: const ValueKey('SettingsScreen'),
                            onAccountDeleted: _goToBookList,
                            openPrivacyPasswordRecovery:
                                _openPrivacyPasswordRecovery,
                          )
                        : _currentScreenIndex == 3
                        ? _HelpScreen(
                            key: const ValueKey('HelpScreen'),
                            onSelectPath: _openHelpPath,
                          )
                        : _currentScreenIndex == 5 && _viewedProfileId != null
                        ? UserProfileScreen(
                            key: ValueKey(
                              'ViewedUserProfile-${_viewedProfileId!}',
                            ),
                            profileId: _viewedProfileId,
                            onBack: _goToBookList,
                            onOpenProfile: _openUserProfile,
                            showAppBar: false,
                          )
                        : _currentScreenIndex == 6
                        ? TermsScreen(
                            key: const ValueKey('TermsScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : _currentScreenIndex == 7
                        ? PrivacyPolicyScreen(
                            key: const ValueKey('PrivacyPolicyScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : _currentScreenIndex == 8
                        ? CommunityGuidelinesScreen(
                            key: const ValueKey('CommunityGuidelinesScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : _currentScreenIndex == 9
                        ? InfringementPolicyScreen(
                            key: const ValueKey('InfringementPolicyScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : _currentScreenIndex == 10
                        ? ExternalTransmissionScreen(
                            key: const ValueKey('ExternalTransmissionScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : _currentScreenIndex == 11
                        ? ContactScreen(
                            key: const ValueKey('ContactScreen'),
                            onClose: () => _setCurrentScreenIndex(3),
                          )
                        : const ModerationScreen(
                            key: ValueKey('ModerationScreen'),
                          ),
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

class _HelpScreen extends StatelessWidget {
  const _HelpScreen({super.key, this.onSelectPath});

  final ValueChanged<String>? onSelectPath;

  @override
  Widget build(BuildContext context) {
    final items = <_HelpItem>[
      _HelpItem(
        title: '利用規約',
        path: '/terms',
        screenBuilder: (_) => const TermsScreen(),
      ),
      _HelpItem(
        title: 'プライバシーポリシー',
        path: '/privacy',
        screenBuilder: (_) => const PrivacyPolicyScreen(),
      ),
      _HelpItem(
        title: 'コミュニティガイドライン',
        path: '/community-guidelines',
        screenBuilder: (_) => const CommunityGuidelinesScreen(),
      ),
      _HelpItem(
        title: '権利侵害・通報ポリシー',
        path: '/infringement-policy',
        screenBuilder: (_) => const InfringementPolicyScreen(),
      ),
      _HelpItem(
        title: '外部送信に関する公表事項',
        path: '/external-transmission',
        screenBuilder: (_) => const ExternalTransmissionScreen(),
      ),
      _HelpItem(
        title: 'お問い合わせ',
        path: '/contact',
        screenBuilder: (_) => const ContactScreen(),
      ),
    ];

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: items.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '規約・ポリシー',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              );
            }

            final item = items[index - 1];
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                title: Text(item.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  if (onSelectPath != null) {
                    onSelectPath!(item.path);
                    return;
                  }
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: item.screenBuilder));
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HelpItem {
  const _HelpItem({
    required this.title,
    required this.path,
    required this.screenBuilder,
  });

  final String title;
  final String path;
  final WidgetBuilder screenBuilder;
}
