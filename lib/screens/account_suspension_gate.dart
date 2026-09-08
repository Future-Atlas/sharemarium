import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/moderation_models.dart';
import '../services/supabase_service.dart';
import 'contact_screen.dart';
import 'legal_consent_screen.dart';
import 'post_detail_screen.dart';
import 'profile_onboarding_screen.dart';
import 'public_posts_screen.dart';

class AccountSuspensionGate extends StatefulWidget {
  const AccountSuspensionGate({super.key, required this.child});

  final Widget child;

  @override
  State<AccountSuspensionGate> createState() => _AccountSuspensionGateState();
}

class _AccountSuspensionGateState extends State<AccountSuspensionGate> {
  String? _checkedUserId;
  Future<AccountSuspensionStatus>? _statusFuture;

  void _refresh(SupabaseService service) {
    setState(() {
      _statusFuture = service.fetchCurrentAccountSuspension();
    });
  }

  String _currentAppPath() {
    final uri = Uri.base;
    if (uri.fragment.startsWith('/')) {
      return Uri.tryParse(uri.fragment)?.path ?? uri.path;
    }
    return uri.path;
  }

  Widget _withAppUsageGates(Widget child) {
    return LegalConsentGate(
      child: ProfileOnboardingGate(child: child),
    );
  }

  Widget _routeAwareChild() {
    final path = _currentAppPath();
    if (path == '/posts' || path == '/posts/') {
      return _withAppUsageGates(const PublicPostsScreen());
    }

    const prefix = '/posts/';
    if (path.startsWith(prefix)) {
      final encodedPostId = path.substring(prefix.length);
      if (encodedPostId.isNotEmpty && !encodedPostId.contains('/')) {
        try {
          return _withAppUsageGates(
            PostDetailScreen(postId: Uri.decodeComponent(encodedPostId)),
          );
        } on FormatException {
          // Fall through to the ordinary app route for malformed paths.
        }
      }
    }

    return widget.child;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SupabaseService>(
      builder: (context, service, _) {
        final routedChild = _routeAwareChild();
        if (!service.isAuthenticated) {
          _checkedUserId = null;
          _statusFuture = null;
          return routedChild;
        }

        final userId = service.activeProfileId;
        if (_checkedUserId != userId || _statusFuture == null) {
          _checkedUserId = userId;
          _statusFuture = service.fetchCurrentAccountSuspension();
        }

        return FutureBuilder<AccountSuspensionStatus>(
          future: _statusFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            final status = snapshot.data;
            if (status == null || !status.isSuspended) return routedChild;
            return _SuspendedAccountScreen(
              status: status,
              onRefresh: () => _refresh(service),
            );
          },
        );
      },
    );
  }
}

class _SuspendedAccountScreen extends StatelessWidget {
  const _SuspendedAccountScreen({
    required this.status,
    required this.onRefresh,
  });

  final AccountSuspensionStatus status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_off_outlined, size: 58),
                      const SizedBox(height: 16),
                      const Text(
                        'アカウントは停止されています',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        status.reason.isEmpty
                            ? '利用状況を確認しています。異議がある場合はお問い合わせください。'
                            : '理由：${status.reason}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ContactScreen(),
                          ),
                        ),
                        icon: const Icon(Icons.contact_support_outlined),
                        label: const Text('お問い合わせ・異議申立て'),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('状態を再確認'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final service = Provider.of<SupabaseService>(
                            context,
                            listen: false,
                          );
                          await service.signOut();
                        },
                        child: const Text('ログアウト'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
