import 'package:supabase_flutter/supabase_flutter.dart';

import 'input_security_service.dart';
import '../utils/dev_logger.dart';

class ReplyEditingService {
  ReplyEditingService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<bool> canEditReplies() async {
    if (_client.auth.currentUser == null) return false;
    try {
      final response = await _client.rpc('current_user_can_edit_replies');
      return response == true;
    } catch (error) {
      debugLog('Error checking reply edit entitlement: $error');
      return false;
    }
  }

  static Future<String?> updateReply({
    required String replyId,
    required String message,
    required bool hasSpoiler,
  }) async {
    final numericReplyId = int.tryParse(replyId);
    if (_client.auth.currentUser == null || numericReplyId == null) {
      return '返信を確認できませんでした。画面を更新してください。';
    }

    final normalized = InputSecurityService.normalizeReplyMessage(message);
    final validationError = InputSecurityService.validateReplyMessage(normalized);
    if (validationError != null) return validationError;

    try {
      await _client.rpc(
        'update_current_user_post_reply',
        params: {
          'target_reply': numericReplyId,
          'reply_message': normalized,
          'reply_has_spoiler': hasSpoiler,
        },
      );
      return null;
    } on PostgrestException catch (error) {
      debugLog(
        'Error editing post reply: code=${error.code}, message=${error.message}',
      );
      if (error.code == '42501') {
        if (error.message.contains('Premium')) {
          return '返信の編集はPremium限定です。';
        }
        return '現在のアカウントでは返信を編集できません。';
      }
      if (error.code == 'P0002' || error.code == '22P02') {
        return '返信を確認できませんでした。画面を更新してください。';
      }
      if (error.code == '23514') {
        return '返信内容を確認してください。';
      }
      return '返信を編集できませんでした（${error.code}）。';
    } catch (error) {
      debugLog('Error editing post reply: $error');
      return '返信を編集できませんでした。';
    }
  }

  static Future<String?> deleteOwnReply(String replyId) async {
    final numericReplyId = int.tryParse(replyId);
    final profileId = _client.auth.currentUser?.id;
    if (profileId == null || numericReplyId == null) {
      return '返信を確認できませんでした。画面を更新してください。';
    }

    try {
      await _client
          .from('post_replies')
          .delete()
          .eq('id', numericReplyId)
          .eq('profile_id', profileId);
      return null;
    } on PostgrestException catch (error) {
      debugLog(
        'Error deleting post reply: code=${error.code}, message=${error.message}',
      );
      return '返信を削除できませんでした（${error.code}）。';
    } catch (error) {
      debugLog('Error deleting post reply: $error');
      return '返信を削除できませんでした。';
    }
  }
}
