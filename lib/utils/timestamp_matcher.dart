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
    if (targetSender != null && targetSender.trim().isNotEmpty) {
      final ts = targetSender.toLowerCase().trim();
      final senderFiltered = candidates.where((c) {
        final s = (c['sender'] as String? ?? '').toLowerCase().trim();
        final sn = (c['senderName'] as String? ?? '').toLowerCase().trim();
        return s == ts || sn == ts;
      }).toList();
      // Strict sender enforcement: Never fall back to other users' messages
      // when targetSender is specified. This eliminates cross-chat misattribution.
      effectiveCandidates = senderFiltered;
      if (effectiveCandidates.isEmpty) {
        return MatchResult.unmatched();
      }
    }

    // FIRST FILTER: Only consider messages that are actually of this media type or blank placeholders!
    final mediaType = mediaEvent['mediaType'] as String? ?? 'unknown';
    final displayName = (mediaEvent['displayName'] as String? ?? '').toLowerCase();
    final cleanBase = displayName.contains('.') ? displayName.substring(0, displayName.lastIndexOf('.')) : displayName;
    final cleanBaseNorm = cleanBase.replaceAll('_', ' ');
    final cleanBaseUnderscore = cleanBase.replaceAll(' ', '_');

    var targetCandidates = effectiveCandidates.where((candidate) {
      final msgText = (candidate['message'] as String? ?? '').toLowerCase().trim();
      if (msgText.startsWith('reacted ') || msgText.startsWith('reacted to ')) return false;

      // ── CALL NOTIFICATION EXCLUSION ─────────────────────────────────────
      // "Missed voice call" contains "voice", which previously matched
      // the audio media check below. Call notifications are NOT messages
      // and must NEVER have media attached to them.
      if (msgText.contains('call') && (msgText.contains('missed') || msgText.contains('incoming') ||
          msgText.contains('ongoing') || msgText.contains('ringing') || msgText.contains('ended'))) {
        return false;
      }
      if (msgText == 'voice call' || msgText == 'video call' || msgText == 'group call') {
        return false;
      }

      final matchesBase = cleanBase.length >= 3 && (
        msgText.contains(cleanBase) ||
        msgText.contains(cleanBaseNorm) ||
        msgText.contains(cleanBaseUnderscore) ||
        (displayName.isNotEmpty && msgText.contains(displayName))
      );
      
      if (mediaType == 'image' && (msgText.contains('photo') || msgText.contains('image') || msgText.contains('📷') || msgText.contains('🖼') || msgText.contains('sticker') || msgText.contains('gif') || msgText.contains('👾') || msgText.contains('💟') || displayName.startsWith('stk-') || matchesBase || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'video' && (msgText.contains('video') || msgText.contains('📹') || msgText.contains('🎥') || msgText.contains('🎞') || msgText.contains('gif') || matchesBase || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'audio' && (msgText.contains('audio') || msgText.contains('voice') || msgText.contains('🎤') || msgText.contains('🎵') || msgText.contains('🎙') || matchesBase || msgText.isEmpty)) {
        return true;
      } else if (mediaType == 'document') {
        if (msgText.contains('document') || msgText.contains('📄') || msgText.contains('📎') || msgText.contains('file') ||
            msgText.contains('.pdf') || msgText.contains('.doc') || msgText.contains('.csv') || msgText.contains('.xls') ||
            msgText.contains('.txt') || msgText.contains('.ppt') || msgText.contains('.zip') ||
            matchesBase || msgText.isEmpty) {
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

    // Multiple candidates found:
    // Tier 1: Candidate message contains the specific filename/cleanBase
    // Tier 2: Absolute timestamp delta proximity
    final sortedCandidates = List<Map<String, dynamic>>.from(targetCandidates);
    sortedCandidates.sort((a, b) {
      final msgA = (a['message'] as String? ?? '').toLowerCase();
      final msgB = (b['message'] as String? ?? '').toLowerCase();

      final aHasName = cleanBase.length >= 3 && (
        msgA.contains(cleanBase) ||
        msgA.contains(cleanBaseNorm) ||
        msgA.contains(cleanBaseUnderscore) ||
        (displayName.isNotEmpty && msgA.contains(displayName))
      );
      final bHasName = cleanBase.length >= 3 && (
        msgB.contains(cleanBase) ||
        msgB.contains(cleanBaseNorm) ||
        msgB.contains(cleanBaseUnderscore) ||
        (displayName.isNotEmpty && msgB.contains(displayName))
      );

      if (aHasName && !bHasName) return -1;
      if (!aHasName && bHasName) return 1;

      final int tsA = a['timestamp'] as int;
      final int tsB = b['timestamp'] as int;
      
      final deltaA = (tsA - fileTimestampMs).abs();
      final deltaB = (tsB - fileTimestampMs).abs();
      return deltaA.compareTo(deltaB);
    });

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
