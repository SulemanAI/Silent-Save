import 'package:flutter_test/flutter_test.dart';
import 'package:silentsave/utils/text_sanitizer.dart';

void main() {
  group('text sanitization', () {
    test('removes isolated UTF-16 surrogates from a message', () {
      const text = 'Hi\uD800 there';

      expect(sanitizeText(text), 'Hi\uFFFD there');
    });

    test('preserves valid surrogate pairs', () {
      const text = '😀 hello';

      expect(sanitizeText(text), '😀 hello');
    });
  });
}
