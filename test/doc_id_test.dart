import 'package:echo99/services/doc_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('rejects emails and dotted ids', () {
    expect(isSafeDocId('user@example.com'), isFalse);
    expect(isSafeDocId('a.b'), isFalse);
    expect(isSafeDocId(''), isFalse);
    expect(() => requireDocId('user@example.com'), throwsArgumentError);
  });

  test('guest uid has no dot', () {
    final id = 'guest${const Uuid().v4().replaceAll('-', '')}';
    expect(id.contains('.'), isFalse);
    expect(isSafeDocId(id), isTrue);
  });
}
