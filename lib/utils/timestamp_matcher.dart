import '../services/database_helper.dart';

class TimestampMatcher {
  /// Match result wrapper
  static Future<MatchResult> matchMediaToNotification(
      Map<String, dynamic> mediaEvent, int windowMs) async {
    final int fileTimestampMs = mediaEvent['fileTimestampMs'] as int? ?? 0;
    if (fileTimestampMs == 0) return MatchResult.unmatched();

    // Fetch candidate WhatsApp messages within window
    final candidates = await DatabaseHelper.instance.getRecentWhatsAppMessages(windowMs, fileTimestampMs);
    if (candidates.isEmpty) {
      return MatchResult.unmatched();
    }

    // Filter by targetSender if specified
    final targetSender = mediaEvent['targetSender'] as String?;
    var effectiveCandidates = candidates;
    if (targetSender != null && targetSender.isNotEmpty) {
      final senderFiltered = candidates.where((c) {
        final s = (c['sender'] as String? ?? '').toLowerCase();
        final sn = (c['senderName'] as String? ?? '').toLowerCase();
        final ts = targetSender.toLowerCase();
        return s == ts || sn == ts;
      }).toList();
      if (senderFiltered.isNotEmpty) {
        effectiveCandidates = senderFiltered;
      }
    }

    // FIRST FILTER: Only consider messages that are actually of this media type or blank placeholders!
    final mediaType = mediaEvent['mediaType'] as String? ?? 'unknown';
    final displayName = (mediaEvent['displayName'] as String? ?? '').toLowerCase();
    final cleanBase = displayName.contains('.') ? displayName.substring(0, displayName.lastIndexOf('.')) : displayName;

    var targetCandidates = effectiveCandidates.where((candidate) {
      final msgText = (candidate['message'] as String? ?? '').toLowerCase().trim();
      if (msgText.startsWith('reacted ') || msgText.startsWith('reacted to ')) return false;
      
      if (mediaType == 'image' && (msgText.contains('photo') || msgText.contains('image') || msgText.contains('📷') || msgText.contains('🖼') || msgText.contains('sticker') || msgText.contains('gif') || msgText.contains('👾') || msgText.contains('💟') || displayName.startsWith('stk-') || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'video' && (msgText.contains('video') || msgText.contains('📹') || msgText.contains('🎥') || msgText.contains('🎞') || msgText.contains('gif') || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'audio' && (msgText.contains('audio') || msgText.contains('voice') || msgText.contains('🎤') || msgText.contains('🎵') || msgText.contains('🎙') || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'document') {
        if (msgText.contains('document') || msgText.contains('📄') || msgText.contains('📎') || msgText.contains('file') ||
            msgText.contains('.pdf') || msgText.contains('.doc') || msgText.contains('.csv') || msgText.contains('.xls') ||
            msgText.contains('.txt') || msgText.contains('.ppt') || msgText.contains('.zip') ||
            (cleanBase.length >= 3 && msgText.contains(cleanBase)) || msgText.isEmpty) {
          return true;
        }
      }
      return false;
    }).toList();

    // Plain text messages like "Tu bata" or "Sett" must NEVER be matched to media
    if (targetCandidates.isEmpty) {
      return MatchResult.unmatched();
    }

    if (targetCandidates.length == 1) {
      return MatchResult.matched(targetCandidates.first);
    }

    // Multiple candidates found, calculate absolute deltas
    final sortedCandidates = List<Map<String, dynamic>>.from(targetCandidates);
    sortedCandidates.sort((a, b) {
      final int tsA = a['timestamp'] as int;
      final int tsB = b['timestamp'] as int;
      
      // We expect file timestamp to be AFTER message timestamp (due to download time)
      // but absolute delta is safest for handling clock skew.
      final deltaA = (tsA - fileTimestampMs).abs();
      final deltaB = (tsB - fileTimestampMs).abs();
      return deltaA.compareTo(deltaB);
    });

    // Since fulfilled candidates are now filtered out by getRecentWhatsAppMessages,
    // we can safely take the best remaining match even if multiple messages arrived at the exact same time (e.g. photo albums).
    return MatchResult.matched(sortedCandidates[0]);
  }
}

class MatchResult {
  final Map<String, dynamic>? matchedMessage;
  final List<Map<String, dynamic>>? ambiguousCandidates;
  final bool isMatched;
  final bool isAmbiguous;
  final bool isUnmatched;

  MatchResult._({
    this.matchedMessage,
    this.ambiguousCandidates,
    this.isMatched = false,
    this.isAmbiguous = false,
    this.isUnmatched = false,
  });

  factory MatchResult.matched(Map<String, dynamic> msg) =>
      MatchResult._(matchedMessage: msg, isMatched: true);

  factory MatchResult.ambiguous(List<Map<String, dynamic>> candidates) =>
      MatchResult._(ambiguousCandidates: candidates, isAmbiguous: true);

  factory MatchResult.unmatched() => MatchResult._(isUnmatched: true);
}
