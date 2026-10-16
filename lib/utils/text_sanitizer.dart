import 'package:characters/characters.dart';

/// Extension on nullable [String] to provide UTF-16 well-formedness validation and sanitization.
extension SafeStringExtension on String? {
  /// Returns a well-formed UTF-16 string by replacing any isolated/unpaired
  /// surrogates with the Unicode replacement character (\uFFFD).
  ///
  /// This prevents "Invalid argument(s): string is not well-formed UTF-16"
  /// crashes inside Flutter's `TextSpan` and `_NativeParagraphBuilder`.
  String toWellFormed() {
    final s = this;
    if (s == null || s.isEmpty) return '';
    final units = s.codeUnits;
    final len = units.length;
    bool hasIsolated = false;

    for (int i = 0; i < len; i++) {
      final unit = units[i];
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 < len) {
          final next = units[i + 1];
          if (next >= 0xDC00 && next <= 0xDFFF) {
            i++; // Valid surrogate pair
            continue;
          }
        }
        hasIsolated = true;
        break;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        hasIsolated = true;
        break;
      }
    }

    if (!hasIsolated) return s;

    final buffer = StringBuffer();
    for (int i = 0; i < len; i++) {
      final unit = units[i];
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 < len) {
          final next = units[i + 1];
          if (next >= 0xDC00 && next <= 0xDFFF) {
            buffer.writeCharCode(unit);
            buffer.writeCharCode(next);
            i++;
            continue;
          }
        }
        buffer.writeCharCode(0xFFFD);
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        buffer.writeCharCode(0xFFFD);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }
}

/// Sanitizes strings that may contain isolated UTF-16 surrogates.
///
/// Some notification payloads (notably from apps like WhatsApp) can contain
/// malformed UTF-16 sequences. If those strings are passed directly into Flutter
/// Text widgets, they trigger "string is not well-formed UTF-16" crashes.
String sanitizeText(String? text) => text.toWellFormed();

/// Safely truncates a string by grapheme clusters (characters) instead of raw
/// UTF-16 code units, preventing cut-in-half surrogate pairs (which cause UTF-16 crashes).
String truncateText(String? text, int maxLength) {
  if (text == null || text.isEmpty) return '';
  final wellFormed = text.toWellFormed();
  final chars = wellFormed.characters;
  if (chars.length <= maxLength) {
    return wellFormed;
  }
  return '${chars.take(maxLength)}...'.toWellFormed();
}
