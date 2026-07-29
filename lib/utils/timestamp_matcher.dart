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

    // FIRST FILTER: Only consider messages that are actually of this media type!
    final mediaType = mediaEvent['mediaType'] as String? ?? 'unknown';
    final validCandidates = candidates.where((candidate) {
      final msgText = (candidate['message'] as String? ?? '').toLowerCase();
      
      if (mediaType == 'image' && (msgText.contains('photo') || msgText.contains('image') || msgText.contains('📷') || msgText.contains('🖼'))) {
        return true;
      } else if (mediaType == 'video' && (msgText.contains('video') || msgText.contains('📹') || msgText.contains('🎥') || msgText.contains('🎞'))) {
        return true;
      } else if (mediaType == 'audio' && (msgText.contains('audio') || msgText.contains('voice') || msgText.contains('🎤') || msgText.contains('🎵') || msgText.contains('🎙'))) {
        return true;
      }
      return false;
    }).toList();

    if (validCandidates.isEmpty) {
      return MatchResult.unmatched();
    }

    if (validCandidates.length == 1) {
      return MatchResult.matched(validCandidates.first);
    }

    // Multiple candidates found, calculate absolute deltas
    final sortedCandidates = List<Map<String, dynamic>>.from(validCandidates);
    sortedCandidates.sort((a, b) {
      final int tsA = a['timestamp'] as int;
      final int tsB = b['timestamp'] as int;
      
      // We expect file timestamp to be AFTER message timestamp (due to download time)
      // but absolute delta is safest for handling clock skew.
      final deltaA = (tsA - fileTimestampMs).abs();
      final deltaB = (tsB - fileTimestampMs).abs();
      return deltaA.compareTo(deltaB);
    });

    final int bestTs = sortedCandidates[0]['timestamp'] as int;
    final int secondBestTs = sortedCandidates[1]['timestamp'] as int;
    
    final bestDelta = (bestTs - fileTimestampMs).abs();
    final secondBestDelta = (secondBestTs - fileTimestampMs).abs();
    
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
