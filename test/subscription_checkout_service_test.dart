import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharemarium/services/subscription_checkout_service.dart';

void main() {
  test('checkout request IDs are RFC 4122 version 4 UUIDs', () {
    final id = createCheckoutRequestId(random: Random(12345));

    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  test('checkout request IDs are unique across attempts', () {
    final random = Random(67890);
    final first = createCheckoutRequestId(random: random);
    final second = createCheckoutRequestId(random: random);

    expect(second, isNot(first));
  });
}
