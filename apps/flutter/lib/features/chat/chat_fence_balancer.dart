// SPDX-License-Identifier: GPL-3.0-or-later

// Display-only balancing of unterminated Markdown code fences in chat bubbles.
// Pure and stateless: no Flutter imports, no widget or clock dependencies.
// The single entry point is `balanceChatCodeFences`.

/// Mirrors markdown 7.3.1's `codeFencePattern`: a backtick info string may not
/// contain backticks, while a tilde info string may contain anything. Leading
/// blockquote markers are part of the prefix so a quoted fence gets a quoted
/// closer. Precompiled once because it is matched against every line.
final RegExp _fencePattern = RegExp(
  r'^((?:[ ]{0,3}>[ ]?)*[ ]{0,3})(?:(`{3,})([^`]*)|(~{3,})(.*))$',
);

/// Number of blockquote markers in a fence prefix.
int _quoteDepth(String prefix) => prefix.split('>').length - 1;

/// Parsed components of one fence line, or `null` when [line] is not a fence.
({String prefix, String marker, String info})? _parseFence(String line) {
  final match = _fencePattern.firstMatch(line);
  if (match == null) return null;
  final backticks = match.group(2);
  return (
    prefix: match.group(1)!,
    marker: backticks ?? match.group(4)!,
    info: (backticks != null ? match.group(3)! : match.group(5)!).trim(),
  );
}

/// Whether [line] closes [opener]: empty info, the same blockquote depth, and
/// a marker of the same character with at least the opener's length.
bool _closes(
  String line,
  ({String prefix, String marker, String info}) opener,
) {
  final fence = _parseFence(line);
  if (fence == null || fence.info.isNotEmpty) return false;
  return _quoteDepth(fence.prefix) == _quoteDepth(opener.prefix) &&
      fence.marker.startsWith(opener.marker);
}

/// Closes unterminated fences right after their opener so GitHub-flavored
/// Markdown does not swallow the prose that follows them.
String balanceChatCodeFences(String text) {
  // Dart's RegExp `.` and `$` do not see a trailing `\r`, so normalize before
  // matching: a `\r\n` fence would otherwise never be recognized.
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var lines = normalized.split('\n');

  // Clamp pathological pastes to a bounded preview instead of failing open:
  // the same loop balances the preview, then a visible marker records the cut.
  // A single trailing newline is a terminator, not an extra content line:
  // 2000 lines joined with '\n' and ending in '\n' must not be "truncated".
  final contentLines = normalized.endsWith('\n')
      ? lines.length - 1
      : lines.length;
  final truncated = contentLines > 2000 || normalized.length > 256 * 1024;
  if (truncated) {
    var charCap = normalized.length > 256 * 1024
        ? 256 * 1024
        : normalized.length;
    // Never end the clamp on a lone UTF-16 high surrogate.
    final lastUnit = normalized.codeUnitAt(charCap - 1);
    if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) charCap--;
    lines = normalized.substring(0, charCap).split('\n').take(2000).toList();
  }

  final out = <String>[];
  var closersAdded = 0;
  var i = 0;
  while (i < lines.length) {
    final opener = _parseFence(lines[i]);
    if (opener == null) {
      out.add(lines[i]);
      i++;
      continue;
    }

    out.add(lines[i]);
    final closerSlot = out.length;
    i++;

    // O(n) segment scan: find this opener's first matching closer. Every line
    // of a matched segment is copied verbatim, so fences inside it are never
    // revisited as openers — the same break-on-all-matched behavior as the
    // original pass loop. An unmatched opener re-scans the remaining lines
    // from `i`, which is where a later fence can become a fresh opener.
    var j = i;
    for (; j < lines.length && !_closes(lines[j], opener); j++) {}
    if (j < lines.length) {
      for (; i <= j; i++) {
        out.add(lines[i]);
      }
      continue;
    }

    // Insert the synthetic closer immediately after its opener. The cap keeps
    // a hostile input from producing unbounded inserted lines.
    if (closersAdded < 256) {
      out.insert(closerSlot, '${opener.prefix}${opener.marker}');
      closersAdded++;
    }
  }
  final balanced = out.join('\n');
  return truncated ? '$balanced\n\n… (truncated)' : balanced;
}
