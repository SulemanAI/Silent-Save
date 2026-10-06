/// Sanitizes strings that may contain isolated UTF-16 surrogates.
///
/// Some notification payloads (notably from apps like WhatsApp) can contain
/// malformed UTF-16 sequences. If those strings are passed directly into Flutter
/// Text widgets, they trigger "string is not well-formed UTF-16" crashes.
String sanitizeText(String? text) {
  if (text == null || text.isEmpty) return '';

  final buffer = StringBuffer();

  for (int i = 0; i < text.length; i++) {
    final codeUnit = text.codeUnitAt(i);

    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      if (i + 1 < text.length) {
        final nextCodeUnit = text.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          buffer.writeCharCode(codeUnit);
          buffer.writeCharCode(nextCodeUnit);
          i++;
          continue;
        }
      }
      buffer.write('\uFFFD');
      continue;
    }

    if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      buffer.write('\uFFFD');
      continue;
    }

    buffer.writeCharCode(codeUnit);
  }

  return buffer.toString();
}
