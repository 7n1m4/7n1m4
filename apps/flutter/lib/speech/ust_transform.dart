// SPDX-License-Identifier: GPL-3.0-or-later

// Vendor-neutral Universal Speech Transformations (UST) applied before TTS.
//
// Port of `applyUSTTransformations` in
// `packages/stage-ui/src/stores/modules/speech.ts:147-434` (behavioral spec:
// `packages/stage-ui/src/stores/modules/README-speech-transformer.md`).
// Only the engine-agnostic steps are ported: math and chemical notation and
// their locale packs stay in a separate scope. Settings are only parsed (by
// [UstOptions.fromSpeechSettings]); nothing here ever writes settings back.

/// Action for a bracket pair. `token` rewrites `<aside>` to `<|aside|>`.
enum UstBracketAction { mute, flatten, passThrough, ignore, token }

enum UstCodeBlockAction { mute, passThrough, ignore }

enum UstLinkMode { extractText, mute, raw }

/// Legacy profile migration mode, kept for older saved voice profiles.
enum UstLegacyMode { mute, flatten, custom }

/// Defaults mirror the no-settings starter voice profile: UST on, bracket
/// muting, code blocks muted, raw HTML stripped, links reduced to their label,
/// emoji removed, `~` removed. `null` bracket fields mean "not configured" and
/// fall back to [legacyMode] (or pass-through when another bracket is set),
/// matching the TypeScript migration path.
class UstOptions {
  const UstOptions({
    this.enabled = true,
    this.asterisks,
    this.squareBrackets,
    this.parentheses,
    this.angleBrackets,
    this.customBracketEnabled = false,
    this.customBracketStart = '',
    this.customBracketEnd = '',
    this.customBracketAction = UstBracketAction.passThrough,
    this.codeBlocks = UstCodeBlockAction.mute,
    this.stripHtml = true,
    this.preserveMarkdownLinks = UstLinkMode.extractText,
    this.normalizeBlockPauses = true,
    this.preserveMathOperators = true,
    this.stripEmojis = true,
    this.stripSymbols = false,
    this.tildeReplacement = '',
    this.legacyMode,
    this.legacyCustomStripChars = '',
  });

  /// Select the active voice profile from a decoded `settings/speech` map and
  /// read its UST settings, mirroring `transformTextForSpeech`'s precedence in
  /// `packages/stage-ui/src/stores/modules/speech.ts:659-681`:
  ///  - a virtual profile (or one whose `baseVoice`/`baseProvider` matches the
  ///    active voice and provider) wins;
  ///  - a missing/unreadable profile, section or `enabled` flag is an exact
  ///    passthrough (`enabled: false`), as in the TS early return;
  ///  - configured fields fall back to the starter [UstOptions] defaults when
  ///    absent or of the wrong type; providers that speak raw text bypass UST.
  factory UstOptions.fromSpeechSettings(Map<String, dynamic> settings) {
    const defaults = UstOptions();
    final rawProfiles = settings['voiceProfiles'];
    if (rawProfiles is! List) return const UstOptions(enabled: false);
    final profiles = rawProfiles.whereType<Map<String, dynamic>>().toList();
    if (profiles.isEmpty) return const UstOptions(enabled: false);

    final provider = settings['activeProvider'];
    final voice = settings['voice'];
    if (provider == 'chatterbox' || provider == 'airi-audio-server') {
      return const UstOptions(enabled: false);
    }

    Map<String, dynamic>? profile;
    if (provider == 'virtual-audio-studio' &&
        voice is String &&
        voice.isNotEmpty) {
      for (final candidate in profiles) {
        if (candidate['id'] == voice || candidate['name'] == voice) {
          profile = candidate;
          break;
        }
      }
    }
    if (profile == null) {
      for (final candidate in profiles) {
        if (candidate['baseVoice'] == voice &&
            candidate['baseProvider'] == provider) {
          profile = candidate;
          break;
        }
      }
    }
    if (profile == null) return const UstOptions(enabled: false);

    final ust = profile['ust'];
    if (ust is! Map<String, dynamic>) return const UstOptions(enabled: false);
    final enabled = ust['enabled'];
    if (enabled is! bool || !enabled) return const UstOptions(enabled: false);

    final codeBlocksRaw = ust['codeBlocks'];
    final codeBlocks = codeBlocksRaw is String
        ? _codeBlockActions[codeBlocksRaw] ?? defaults.codeBlocks
        : ust['stripCodeBlocks'] == false
            ? UstCodeBlockAction.passThrough
            : defaults.codeBlocks;

    return UstOptions(
      enabled: enabled,
      asterisks: _bracketAction(ust['asterisks'], defaults.asterisks),
      squareBrackets:
          _bracketAction(ust['squareBrackets'], defaults.squareBrackets),
      parentheses: _bracketAction(ust['parentheses'], defaults.parentheses),
      angleBrackets:
          _bracketAction(ust['angleBrackets'], defaults.angleBrackets),
      customBracketEnabled:
          _bool(ust['customBracketEnabled'], defaults.customBracketEnabled),
      customBracketStart:
          _string(ust['customBracketStart'], defaults.customBracketStart),
      customBracketEnd:
          _string(ust['customBracketEnd'], defaults.customBracketEnd),
      customBracketAction: _bracketAction(
        ust['customBracketAction'],
        defaults.customBracketAction,
      )!,
      codeBlocks: codeBlocks,
      stripHtml: _bool(ust['stripHtml'], defaults.stripHtml),
      preserveMarkdownLinks: _linkMode(
        ust['preserveMarkdownLinks'],
        defaults.preserveMarkdownLinks,
      )!,
      normalizeBlockPauses:
          _bool(ust['normalizeBlockPauses'], defaults.normalizeBlockPauses),
      preserveMathOperators:
          _bool(ust['preserveMathOperators'], defaults.preserveMathOperators),
      stripEmojis: _bool(ust['stripEmojis'], defaults.stripEmojis),
      stripSymbols: _bool(ust['stripSymbols'], defaults.stripSymbols),
      tildeReplacement: _stringOrNull(ust['tildeReplacement']),
      legacyMode: _legacyMode(ust['mode'], defaults.legacyMode),
      legacyCustomStripChars:
          _string(ust['customStripChars'], defaults.legacyCustomStripChars),
      // customReplacements is deferred: it needs an ordered rule list with
      // regex/text flags, which UstOptions does not model yet.
    );
  }

  final bool enabled;
  final UstBracketAction? asterisks;
  final UstBracketAction? squareBrackets;
  final UstBracketAction? parentheses;
  final UstBracketAction? angleBrackets;
  final bool customBracketEnabled;
  final String customBracketStart;
  final String customBracketEnd;
  final UstBracketAction customBracketAction;
  final UstCodeBlockAction codeBlocks;
  final bool stripHtml;
  final UstLinkMode preserveMarkdownLinks;
  final bool normalizeBlockPauses;
  final bool preserveMathOperators;
  final bool stripEmojis;
  final bool stripSymbols;
  /// `null` leaves `~` untouched; an empty string removes it.
  final String? tildeReplacement;
  final UstLegacyMode? legacyMode;
  final String legacyCustomStripChars;
}

const Map<String, UstBracketAction> _bracketActions =
    <String, UstBracketAction>{
  'mute': UstBracketAction.mute,
  'flatten': UstBracketAction.flatten,
  'passThrough': UstBracketAction.passThrough,
  'ignore': UstBracketAction.ignore,
  'token': UstBracketAction.token,
};
const Map<String, UstCodeBlockAction> _codeBlockActions =
    <String, UstCodeBlockAction>{
  'mute': UstCodeBlockAction.mute,
  'passThrough': UstCodeBlockAction.passThrough,
  'ignore': UstCodeBlockAction.ignore,
};
const Map<String, UstLinkMode> _linkModes = <String, UstLinkMode>{
  'extract_text': UstLinkMode.extractText,
  'mute': UstLinkMode.mute,
  'raw': UstLinkMode.raw,
};
const Map<String, UstLegacyMode> _legacyModes = <String, UstLegacyMode>{
  'mute': UstLegacyMode.mute,
  'flatten': UstLegacyMode.flatten,
  'custom': UstLegacyMode.custom,
};

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;
String _string(Object? value, String fallback) =>
    value is String ? value : fallback;
String? _stringOrNull(Object? value) => value is String ? value : null;
UstBracketAction? _bracketAction(Object? value, UstBracketAction? fallback) =>
    value is String ? _bracketActions[value] ?? fallback : fallback;
UstLegacyMode? _legacyMode(Object? value, UstLegacyMode? fallback) =>
    value is String ? _legacyModes[value] ?? fallback : fallback;
UstLinkMode? _linkMode(Object? value, UstLinkMode? fallback) =>
    value is String ? _linkModes[value] ?? fallback : fallback;

final RegExp _imageEmbed = RegExp(r'!\[.*?\]\(.*?\)');
final RegExp _codeBlock = RegExp(r'```[\s\S]*?```');
final RegExp _htmlTag = RegExp(r'<\/?[a-z][^>]*>', caseSensitive: false);
final RegExp _markdownLink = RegExp(r'\[([^\]]+)\]\([^)]+\)');
final RegExp _header = RegExp(r'^#{1,6}\s+', multiLine: true);
final RegExp _quote = RegExp(r'^>\s+', multiLine: true);
final RegExp _listItem = RegExp(r'^[-*+]\s+', multiLine: true);
final RegExp _orderedItem = RegExp(r'^\d+\.\s+', multiLine: true);
final RegExp _horizontalSpace = RegExp(r'[^\S\r\n]+');

// Dart RegExp operates on UTF-16 units, so astral emoji ranges are matched by
// rune instead of by a character-class regex (a regex range throws here).
const List<List<int>> _emojiRanges = <List<int>>[
  <int>[0x1F600, 0x1F64F],
  <int>[0x1F300, 0x1F5FF],
  <int>[0x1F680, 0x1F6FF],
  <int>[0x1F700, 0x1F77F],
  <int>[0x1F780, 0x1F7FF],
  <int>[0x1F800, 0x1F8FF],
  <int>[0x1F900, 0x1F9FF],
  <int>[0x1FA00, 0x1FA6F],
  <int>[0x1FA70, 0x1FAFF],
  <int>[0x2600, 0x26FF],
  <int>[0x2700, 0x27BF],
];
final RegExp _symbol = RegExp(r'''[^\p{L}\p{N}\s.,!?;:"'-]''', unicode: true);
final RegExp _orchestrationToken = RegExp(r'<\|[^<>]*\|>');

// Lookbehind is unavailable in Dart RegExp: consume the leading character and
// put the whole operator expression into the placeholder instead.
final RegExp _mathExponent = RegExp(
  r'(\d+\s*\*{2}\s*\d+|\b\w+\s+\*{2}\s+\w+\b|\b[a-z]\*{2}\d+\b)',
  caseSensitive: false,
);
final RegExp _mathMultiply = RegExp(r'(\d+\s*\*\s*\d+|\b\w+\s+\*\s+\w+\b)');

/// Transform [text] for speech. A null [options] (or [UstOptions.enabled]
/// false) is an exact passthrough.
String applyUstTransform(String text, [UstOptions? options]) {
  if (options == null || !options.enabled) return text;

  var transformed = text.replaceAll(_imageEmbed, '');

  if (options.codeBlocks == UstCodeBlockAction.mute) {
    transformed = transformed.replaceAll(_codeBlock, '');
  }
  if (options.stripHtml) {
    transformed = transformed.replaceAll(_htmlTag, '');
  }
  switch (options.preserveMarkdownLinks) {
    case UstLinkMode.extractText:
      transformed = transformed.replaceAllMapped(
          _markdownLink, (match) => match.group(1) ?? '');
    case UstLinkMode.mute:
      transformed = transformed.replaceAll(_markdownLink, '');
    case UstLinkMode.raw:
      break;
  }
  if (options.normalizeBlockPauses) {
    transformed = transformed.replaceAll(_header, '');
    transformed = transformed.replaceAll(_quote, '');
    transformed = transformed.replaceAll(_listItem, '');
    transformed = transformed.replaceAll(_orderedItem, '');
  }

  final tokens = <String>[];
  // NOTICE: protect existing <|ACTOR:…|> / <|ACT:…|> tokens verbatim before
  // bracket processing. The TS token action re-wraps them as <||…||>; the spec
  // (README:34-35) requires them to survive unchanged, so we do not reproduce
  // that double-pipe behavior.
  transformed = transformed.replaceAllMapped(
      _orchestrationToken, (match) => _protect(tokens, match.group(0)!));

  final math = <String>[];
  if (options.preserveMathOperators) {
    transformed = transformed.replaceAllMapped(
        _mathExponent, (match) => _protect(math, match.group(0)!, 'MATH'));
    transformed = transformed.replaceAllMapped(
        _mathMultiply, (match) => _protect(math, match.group(0)!, 'MATH'));
  }

  final anyBracketConfigured = options.asterisks != null ||
      options.squareBrackets != null ||
      options.parentheses != null ||
      options.angleBrackets != null;
  UstBracketAction resolve(UstBracketAction? action) {
    if (action != null) return action;
    if (anyBracketConfigured) return UstBracketAction.passThrough;
    return switch (options.legacyMode ?? UstLegacyMode.mute) {
      UstLegacyMode.mute => UstBracketAction.mute,
      UstLegacyMode.flatten => UstBracketAction.flatten,
      UstLegacyMode.custom => UstBracketAction.passThrough,
    };
  }

  transformed = _processBracket(
      transformed, '*', '*', resolve(options.asterisks), tokens);
  transformed = _processBracket(
      transformed, '[', ']', resolve(options.squareBrackets), tokens);
  transformed = _processBracket(
      transformed, '(', ')', resolve(options.parentheses), tokens);
  transformed = _processBracket(
      transformed, '<', '>', resolve(options.angleBrackets), tokens);
  if (options.customBracketEnabled) {
    transformed = _processBracket(
      transformed,
      options.customBracketStart,
      options.customBracketEnd,
      options.customBracketAction,
      tokens,
    );
  }
  if (options.legacyMode == UstLegacyMode.custom &&
      options.legacyCustomStripChars.isNotEmpty) {
    for (final rune in options.legacyCustomStripChars.runes) {
      transformed = transformed.replaceAll(String.fromCharCode(rune), '');
    }
  }

  if (options.stripEmojis) transformed = _stripEmojis(transformed);
  if (options.stripSymbols) {
    transformed = transformed.replaceAll(_symbol, '');
  }

  transformed = _restoreAll(transformed, math, tokens);

  final tilde = options.tildeReplacement;
  if (tilde != null) {
    final replacement = tilde.trim();
    transformed = transformed.replaceAll(
      '~',
      replacement.isEmpty ? '' : ' $replacement ',
    );
  }

  return _normalizeWhitespace(transformed);
}

// Private-use delimiters plus a per-isolate nonce make collisions with real
// dialogue text (which may itself contain literal `__UST_TOKEN_0__` strings)
// effectively impossible.
final String _ustNonce = Object().hashCode.toRadixString(36);
final RegExp _ustSentinel = RegExp(
  '\uE000UST_${_ustNonce}_([A-Z]+)_(\\d+)\uE001',
);

String _protect(List<String> store, String value, [String prefix = 'TOKEN']) {
  final id = '\uE000UST_${_ustNonce}_${prefix}_${store.length}\uE001';
  store.add(value);
  return id;
}

/// Restore in one pass over the original text: a restored value containing a
/// sentinel is never re-scanned, so nested protected fragments survive too.
String _restoreAll(String text, List<String> math, List<String> tokens) {
  return text.replaceAllMapped(_ustSentinel, (match) {
    final store = match.group(1) == 'MATH' ? math : tokens;
    final index = int.parse(match.group(2)!);
    return index < store.length ? store[index] : match.group(0)!;
  });
}

String _processBracket(String input, String start, String end,
    UstBracketAction action, List<String> tokens) {
  if (action == UstBracketAction.ignore ||
      action == UstBracketAction.passThrough ||
      start.isEmpty ||
      end.isEmpty) {
    return input;
  }
  final pattern = '${RegExp.escape(start)}.*?${RegExp.escape(end)}';
  switch (action) {
    case UstBracketAction.mute:
      return input
          .replaceAll(RegExp(pattern), '')
          .replaceAll(start, '')
          .replaceAll(end, '');
    case UstBracketAction.flatten:
      return input.replaceAll(start, '').replaceAll(end, '');
    case UstBracketAction.token:
      return input.replaceAllMapped(RegExp('${RegExp.escape(start)}(.*?)'
          '${RegExp.escape(end)}'), (match) {
        return _protect(tokens, '<|${match.group(1) ?? ''}|>');
      });
    case UstBracketAction.passThrough:
    case UstBracketAction.ignore:
      return input;
  }
}

String _stripEmojis(String input) => String.fromCharCodes(
      input.runes.where(
        (rune) => rune != 0x200D &&
            !_emojiRanges.any((range) => rune >= range[0] && rune <= range[1]),
      ),
    );

String _normalizeWhitespace(String input) {
  final lines = input
      .split('\n')
      .map((line) => line.replaceAll(_horizontalSpace, ' ').trim())
      .toList(growable: false);
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].isNotEmpty || (i > 0 && lines[i - 1].isNotEmpty)) {
      kept.add(lines[i]);
    }
  }
  return kept.join('\n').trim();
}
