import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Emits diagnostics only in Flutter debug builds.
///
/// `kDebugMode` is a compile-time constant, so these calls do not emit
/// internal API or Supabase details in profile/release web builds.
void debugLog(String? message, {int? wrapWidth}) {
  if (!kDebugMode) {
    return;
  }

  developer.log(message ?? '', name: 'Sharemarium');
}
