// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local render state for the stage's parity surfaces: caption overlay,
// background layers, control-strip host state, idle/ambient motion and
// emotion/motion cue rendering. Ported in behavior from the Vue reference
// (`packages/stage-ui/src/components/scenes/CaptionPanel.vue`,
// `RendererStage.vue`, `ControlStripHost.vue`) but reduced to what a thin
// remote client can own: nothing here is persisted and nothing is written
// back to the daemon. The daemon owns cards, sessions and settings.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../daemon_client/daemon_client.dart';
import '../../speech/lip_sync_rms_data.dart';
import 'model_expression.dart';
import 'stage_atmosphere.dart';
import 'stage_background.dart';

/// One sentence-sync segment of an assistant turn (Vue `CaptionSegment`).
class CaptionSegment {
  const CaptionSegment({
    required this.text,
    this.color = '',
    this.actorId = '',
    this.isActive = false,
  });

  final String text;

  /// Accent color as `#RRGGBB`; empty means "use the default on-screen
  /// color". The stage never invents one.
  final String color;

  final String actorId;
  final bool isActive;

  CaptionSegment copyWith({bool? isActive}) => CaptionSegment(
    text: text,
    color: color,
    actorId: actorId,
    isActive: isActive ?? this.isActive,
  );
}

/// Immutable caption overlay snapshot.
class StageCaptionSnapshot {
  const StageCaptionSnapshot({
    this.speakerText = '',
    this.segments = const <CaptionSegment>[],
  });

  /// Speaker nameplate text (Vue `caption-speaker`).
  final String speakerText;

  /// Assistant segments of the turn being captioned.
  final List<CaptionSegment> segments;

  bool get isEmpty => speakerText.isEmpty && segments.isEmpty;
}

/// Client-local caption accumulator.
///
/// A turn is keyed by the daemon's `message_id`: the first delta of a turn
/// resets the buffer (Vue clears on the user turn), later deltas append, and
/// the terminal marker (`final: true`) splits it into sentences with the first
/// active, which stay on screen until the next turn starts.
class StageCaptionController extends ChangeNotifier {
  /// One amplitude window from `speech/lip_sync_generator.dart`.
  static const int _rmsWindowMs = 50;
  static final RegExp _sentenceEnd = RegExp(r'[.!?。！？]');
  static final RegExp _cjk =
      RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF]');

  StageCaptionSnapshot _snapshot = const StageCaptionSnapshot();
  String? _messageId;
  final StringBuffer _buffer = StringBuffer();
  int? _lastSeq;

  /// Timestamp of the first local TTS frame of this turn. Wall-clock RMS
  /// timestamps avoid drift when frames are dropped or arrive late (there is
  /// no AudioContext clock in this client).
  int? _captionStartTs;

  StageCaptionSnapshot get snapshot => _snapshot;

  /// Apply one decoded `token.delta` payload. Malformed or replayed frames
  /// are ignored so junk on the topic cannot spoof a caption.
  void applyTokenDelta(Map<String, dynamic> data) {
    final delta = data['delta'];
    if (delta is! String) return;
    final seq = data['seq'];
    if (seq is int) {
      final last = _lastSeq;
      if (last != null && seq <= last) return;
      _lastSeq = seq;
    }
    final messageId = data['message_id'];
    final id = messageId is String && messageId.isNotEmpty ? messageId : null;
    if (id != null && id != _messageId) {
      _messageId = id;
      _buffer.clear();
      _captionStartTs = null;
    }
    if (delta.isNotEmpty) _buffer.write(delta);
    final isFinal = data['final'] == true;
    final reason = data['reason'];
    // The publisher marks cancelled/error turns terminal even on a non-final
    // frame (gateway.rs:1307,1361); mirror chat_screen.dart:176-182 so a failed
    // or cancelled turn is never shown as a completed caption.
    final terminal = isFinal || reason == 'cancelled' || reason == 'error';
    final failedTurn = terminal && reason != null && reason != 'complete';
    if (terminal) {
      _messageId = null;
      _lastSeq = null;
      _captionStartTs = null;
    }
    final buffer = _buffer.toString();
    // Split only on the terminal marker: splitting per delta would re-chunk
    // the line as punctuation arrives mid-stream. Failed turns are dropped.
    final texts = failedTurn
        ? const <String>[]
        : terminal
            ? _splitSentences(buffer)
            : buffer.isEmpty
                ? const <String>[]
                : <String>[buffer];
    final color = _snapshot.segments.isEmpty ? '' : _snapshot.segments.first.color;
    final actorId =
        _snapshot.segments.isEmpty ? '' : _snapshot.segments.first.actorId;
    _snapshot = StageCaptionSnapshot(
      speakerText: _snapshot.speakerText,
      segments: <CaptionSegment>[
        for (var i = 0; i < texts.length; i++)
          CaptionSegment(
            text: texts[i],
            color: color,
            actorId: actorId,
            isActive: terminal && i == 0,
          ),
      ],
    );
    notifyListeners();
  }

  /// Split on `[.!?。！？]`, keeping the terminator. The trailing fragment is
  /// also a sentence, so a turn without punctuation still captions.
  static List<String> _splitSentences(String text) {
    final sentences = <String>[];
    final current = StringBuffer();
    final chars = text.runes.toList();
    for (var i = 0; i < chars.length; i++) {
      current.writeCharCode(chars[i]);
      if (!_sentenceEnd.hasMatch(String.fromCharCode(chars[i]))) continue;
      // Absorb runs like "!!!" / "..." into this sentence so they do not
      // become junk segments.
      while (i + 1 < chars.length &&
          _sentenceEnd.hasMatch(String.fromCharCode(chars[i + 1]))) {
        i++;
        current.writeCharCode(chars[i]);
      }
      final sentence = current.toString().trim();
      if (sentence.isNotEmpty) sentences.add(sentence);
      current.clear();
    }
    final tail = current.toString().trim();
    if (tail.isNotEmpty) sentences.add(tail);
    return sentences;
  }

  /// Rough phonetic length from `pause-aligner.ts`: a CJK glyph counts ~1.8
  /// syllables, a Latin word ~1.3, with a floor of one unit.
  static double _phoneticWeight(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 1;
    final cjkCount = _cjk.allMatches(trimmed).length;
    final latinWords = trimmed
        .replaceAll(_cjk, ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .length;
    final total = cjkCount * 1.8 + latinWords * 1.3;
    return total < 1 ? 1 : total;
  }

  /// Set the speaker nameplate.
  void setSpeaker(String text) {
    _snapshot = StageCaptionSnapshot(
      speakerText: text,
      segments: _snapshot.segments,
    );
    notifyListeners();
  }

  /// Replace the segment list; an empty list clears the overlay.
  void setSegments(List<CaptionSegment> segments) {
    _snapshot = StageCaptionSnapshot(
      speakerText: _snapshot.speakerText,
      segments: segments,
    );
    notifyListeners();
  }

  /// Mark the active sentence-sync phrase.
  void setActiveSentence(int index) {
    if (index < 0 || index >= _snapshot.segments.length) return;
    _snapshot = StageCaptionSnapshot(
      speakerText: _snapshot.speakerText,
      segments: <CaptionSegment>[
        for (var i = 0; i < _snapshot.segments.length; i++)
          _snapshot.segments[i].copyWith(isActive: i == index),
      ],
    );
    notifyListeners();
  }

  /// Advance the highlighted sentence from a local TTS RMS frame. With only
  /// 50ms windows and no silence detection, boundaries are the cumulative
  /// phonetic weights of the sentences; without frames the first stays active.
  void advanceCaptionPlayback(LipSyncRmsData frame) {
    final segments = _snapshot.segments;
    if (segments.isEmpty) return;
    final baseline = _captionStartTs ??= frame.tsMs;
    // Count one observation window for the anchoring frame; after that the
    // real RMS timestamps keep timing honest even if frames are dropped.
    final elapsedMs = frame.tsMs - baseline + _rmsWindowMs;
    var cumulativeMs = 0.0;
    var target = segments.length - 1;
    for (var i = 0; i < segments.length; i++) {
      cumulativeMs += _phoneticWeight(segments[i].text) * _rmsWindowMs;
      if (elapsedMs < cumulativeMs) {
        target = i;
        break;
      }
    }
    if (segments.indexWhere((segment) => segment.isActive) != target) {
      setActiveSentence(target);
    }
  }

  /// Clear the overlay.
  void clear() {
    _messageId = null;
    _lastSeq = null;
    _captionStartTs = null;
    _buffer.clear();
    _snapshot = const StageCaptionSnapshot();
    notifyListeners();
  }
}

/// Where the caption bar docks (Vue `settingsStore.captionDocking`).
enum StageCaptionDocking { none, top, bottom }

/// Caption appearance, derived from the daemon's `captions` settings section
/// (`crates/anima-core/src/settings.rs` `CaptionsSettings`). Percentages are
/// stored 50–200 (font) and 0–100 (opacity).
class StageCaptionStyle {
  const StageCaptionStyle({
    this.enabled = true,
    this.docking = StageCaptionDocking.bottom,
    this.fontSize = 100,
    this.opacity = 20,
  });

  /// The daemon's `captions.enabled` switch, independent of docking.
  final bool enabled;
  final StageCaptionDocking docking;
  final double fontSize;
  final double opacity;

  bool get isVisible => enabled && docking != StageCaptionDocking.none;

  bool get isTop => docking == StageCaptionDocking.top;

  double get scale => fontSize.clamp(50, 200) / 100;
  double get alpha => opacity.clamp(0, 100) / 100;

  /// A stored `head` value reads as bottom until a head-tethered renderer
  /// exists; advertising an unimplemented edge would be a silent lie.
  static StageCaptionDocking dockingFrom(Object? value) => switch (value) {
    'top' => StageCaptionDocking.top,
    'none' => StageCaptionDocking.none,
    _ => StageCaptionDocking.bottom,
  };

  static StageCaptionStyle fromSettings(Map<String, dynamic>? settings) {
    if (settings == null) return const StageCaptionStyle();
    final size = settings['fontSize'] ?? settings['font_size'];
    final alpha = settings['opacity'];
    final enabled = settings['enabled'];
    return StageCaptionStyle(
      enabled: enabled is! bool || enabled,
      docking: dockingFrom(settings['docking']),
      fontSize: size is num && size.isFinite ? size.toDouble() : 100,
      opacity: alpha is num && alpha.isFinite ? alpha.toDouble() : 20,
    );
  }
}

/// Client-local idle/ambient motion.
///
/// The Vue stage drives idle cycles and Live2D ambient motion from card
/// metadata plus elapsed time (`RendererStage.vue`,
/// `useLive2DStageAmbientMotion`). No native renderer exists on this client
/// yet, so the state is the one value a renderer needs: a slow 0..1 phase
/// derived from a monotonic clock. It is never fabricated per frame.
class StageIdleMotion {
  const StageIdleMotion({this.period = const Duration(seconds: 6)});

  /// One full ambient cycle.
  final Duration period;

  bool get isEnabled => period.inMicroseconds > 0;

  /// Triangle wave in `[0, 1]` over [elapsed].
  double phaseAt(Duration elapsed) {
    final micros = period.inMicroseconds;
    if (micros <= 0 || elapsed <= Duration.zero) return 0;
    final fraction = (elapsed.inMicroseconds % micros) / micros;
    return (fraction <= 0.5 ? fraction * 2 : (1 - fraction) * 2).clamp(
      0.0,
      1.0,
    );
  }
}

/// Render channel a cue drives. `motion` and `vfx` are never facial morphs
/// (`crates/anima-channel/src/wire.rs` `CueKind`).
enum StageCueChannel { emotion, motion, vfx }

/// The channel for [cue], or null for an unknown kind.
StageCueChannel? stageCueChannel(StageExpressionCue cue) => switch (cue.kind) {
  'emotion' => StageCueChannel.emotion,
  'motion' => StageCueChannel.motion,
  'vfx' => StageCueChannel.vfx,
  _ => null,
};

/// Client-local render state of one stage surface.
///
/// Owns the caption accumulator, the backdrop, idle phase and the latest
/// cue/frame. Every mutation is local; the class never calls the daemon.
class StageRenderState extends ChangeNotifier {
  StageRenderState({
    StageBackground background = StageBackground.none,
    StageCaptionStyle captions = const StageCaptionStyle(),
    bool showModel = true,
    bool paused = false,
    String? actorId,
    StageIdleMotion idle = const StageIdleMotion(),
    StageAtmosphere atmosphere = StageAtmosphere.none,
  }) : _background = background,
       _captions = captions,
       _showModel = showModel,
       _paused = paused,
       _actorId = actorId,
       _idle = idle,
       _atmosphere = atmosphere {
    _captionController.addListener(notifyListeners);
  }

  StageBackground _background;
  StageCaptionStyle _captions;
  final StageCaptionController _captionController = StageCaptionController();
  StageIdleMotion _idle;
  StageAtmosphere _atmosphere;
  bool _showModel;
  bool _paused;
  String? _actorId;
  StageExpressionCue? _cue;
  LipSyncRmsData? _frame;
  int? _lastCueSeq;
  int? _lastFrameSeq;
  final Stopwatch _clock = Stopwatch();
  Duration _elapsed = Duration.zero;

  StageBackground get background => _background;
  StageCaptionStyle get captionStyle => _captions;
  StageCaptionSnapshot get caption => _captionController.snapshot;
  StageCaptionController get captions => _captionController;
  StageIdleMotion get idle => _idle;

  /// Client-local atmosphere preview selection. Defaults to `none`.
  StageAtmosphere get atmosphere => _atmosphere;

  bool get showModel => _showModel;
  bool get paused => _paused;
  String? get actorId => _actorId;
  StageExpressionCue? get cue => _cue;
  LipSyncRmsData? get frame => _frame;

  /// Current ambient phase, or 0 while paused or before the first tick.
  double get idlePhase => _paused ? 0 : _idle.phaseAt(_elapsed);

  /// Advance the ambient clock. The stage shell calls this once per frame so
  /// the phase is derived from elapsed time, never fabricated.
  void tickAmbient(Duration elapsed) {
    _clock.stop();
    _elapsed = elapsed;
    notifyListeners();
  }

  /// Elapsed ambient time since the surface mounted.
  Duration get ambientElapsed => _elapsed;

  /// The channel the latest cue drives, or null when there is none.
  StageCueChannel? get cueChannel =>
      _cue == null ? null : stageCueChannel(_cue!);

  void setBackground(StageBackground background) {
    _background = background;
    notifyListeners();
  }

  void setCaptionStyle(StageCaptionStyle style) {
    _captions = style;
    notifyListeners();
  }

  void setShowModel(bool value) {
    _showModel = value;
    notifyListeners();
  }

  void setPaused(bool value) {
    _paused = value;
    notifyListeners();
  }

  void setIdleMotion(StageIdleMotion motion) {
    _idle = motion;
    notifyListeners();
  }

  /// Select the particle atmosphere for this client-local preview.
  ///
  /// Client-local only: the Vue store also writes the id to the active card
  /// and to localStorage, but this client has no card-write verb and no daemon
  /// field for atmosphere. Persisting the selection is a separate decision.
  void setAtmosphere(StageAtmosphere atmosphere) {
    _atmosphere = atmosphere;
    notifyListeners();
  }

  /// Restrict frames and cues to one actor (Vue multi-actor staging).
  void setActorId(String? value, {bool notify = true}) {
    _actorId = value;
    _lastCueSeq = null;
    _lastFrameSeq = null;
    if (notify) notifyListeners();
  }

  /// Apply one real stamped RMS frame. Stale or wrong-actor frames are
  /// dropped so replayed audio cannot animate the mouth.
  bool applyFrame(LipSyncRmsData frame) {
    final actor = _actorId;
    if (actor != null && frame.actorId != actor) return false;
    final last = _lastFrameSeq;
    if (last != null && frame.seq <= last) return false;
    _lastFrameSeq = frame.seq;
    _frame = frame;
    _captionController.advanceCaptionPlayback(frame);
    notifyListeners();
    return true;
  }

  /// Apply one parsed cue. Stale or wrong-actor cues are dropped.
  bool applyCue(StageExpressionCue cue) {
    final actor = _actorId;
    if (actor != null && cue.actorId != actor) return false;
    final last = _lastCueSeq;
    if (last != null && cue.seq <= last) return false;
    _lastCueSeq = cue.seq;
    _cue = cue;
    notifyListeners();
    return true;
  }

  /// A fresh view of the state for a new card/model mount. The next cue and
  /// frame are accepted regardless of sequence numbers.
  void beginFollowing({String? actorId}) {
    _actorId = actorId;
    _lastCueSeq = null;
    _lastFrameSeq = null;
    _cue = null;
    _frame = null;
    notifyListeners();
  }

  /// Drop turn-scoped render data when the socket drops: a half-written
  /// caption, the latest cue and the latest RMS frame must not linger on a
  /// disconnected stage. Client-owned settings (background, caption style,
  /// model visibility, idle) survive. Sequence baselines stay intact so a
  /// replayed frame or cue cannot resurrect stale data on the next connection.
  void clearTransient() {
    _cue = null;
    _frame = null;
    // `StageCaptionController.clear()` notifies through the listener installed
    // in the constructor, so one notification covers the whole clear.
    _captionController.clear();
  }

  @override
  void dispose() {
    _captionController.removeListener(notifyListeners);
    _captionController.dispose();
    super.dispose();
  }
}

/// Binds [StageRenderState] to the daemon's event lane.
///
/// Subscribes to `emotion.tag` and `token.delta` on the authenticated socket
/// and feeds the local state. Subscription failure is non-fatal: captions and
/// cues degrade quietly, exactly like the chat surface.
class StageRenderStateBinding {
  StageRenderStateBinding({
    required DaemonClient client,
    required StageRenderState state,
    String? boundSessionId,
  }) : _client = client,
       _state = state,
       _boundSessionId =
           boundSessionId != null && boundSessionId.isNotEmpty
               ? boundSessionId
               : null {
    _unsubscribe = client.onEvent(_onEvent);
    _wasConnected = client.snapshot.isConnected;
    // The lane is opt-in: no subscription means no captions or cues. The
    // request is idempotent on the daemon and non-fatal when unsupported.
    _subscribe();
    _statusSubscription = client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      if (connected && !_wasConnected) _subscribe();
      if (!connected && _wasConnected) {
        _learnedSessionId = null;
        _state.clearTransient();
      }
      _wasConnected = connected;
    });
  }

  final DaemonClient _client;
  final StageRenderState _state;

  /// Optional explicit session to caption. When absent, the session is learned
  /// from the stream (mirrors chat_screen.dart:191-192) so production works
  /// without shell plumbing. Kept separate from the learned value so an
  /// explicit binding always wins once one is supplied.
  String? _boundSessionId;
  String? _learnedSessionId;

  StreamSubscription<DaemonStatus>? _statusSubscription;
  void Function()? _unsubscribe;
  Future<void> _eventRpc = Future<void>.value();
  bool _wasConnected = false;

  bool get isBound => _unsubscribe != null;

  /// Retarget the caption filter to a new shell session without tearing down
  /// the event lane. A session switch only changes the client-local filter, so
  /// recreating the binding would drop in-flight captions and churn the daemon
  /// topic for no benefit (unlike a client/render change, which needs a fresh
  /// subscribe).
  void setBoundSessionId(String? id) {
    final normalized = (id == null || id.isEmpty) ? null : id;
    if (normalized == _boundSessionId) return;
    _boundSessionId = normalized;
    // An explicit id wins over anything learned from the previous session;
    // drop both it and that session's completed captions right away.
    _learnedSessionId = null;
    _state.clearTransient();
  }

  void _subscribe() {
    _wasConnected = _client.snapshot.isConnected;
    _requestEventRpc('event.subscribe');
  }

  void _requestEventRpc(String action) {
    _eventRpc = _eventRpc.then((_) async {
      try {
        await _client.call(
          action,
          payload: <String, dynamic>{
            'topics': <String>[
              EventTopic.emotionTag.wireName,
              EventTopic.tokenDelta.wireName,
            ],
          },
        );
      } on Object {
        // Non-fatal: a daemon without the event lane still renders.
      }
    });
  }

  void _onEvent(GatewayEventFrame event) {
    switch (event.topic) {
      case EventTopic.emotionTag:
        final cue = parseExpressionCue(event.data, actorId: _state.actorId);
        if (cue != null) _state.applyCue(cue);
      case EventTopic.tokenDelta:
        final data = event.data;
        final rawSid = data['session_id'];
        final sid = rawSid is String ? rawSid : '';
        // Mirror chat_screen.dart:183-192: an explicit binding wins, a frame
        // without a session id is still accepted (older daemons/fakes), and
        // only disagreeing sessions are dropped. Caption filtering stays
        // client-local; no daemon state or RPC is involved.
        final session = _boundSessionId ?? _learnedSessionId;
        if (session != null && sid.isNotEmpty && sid != session) return;
        if (session == null && sid.isNotEmpty) _learnedSessionId = sid;
        _state.captions.applyTokenDelta(data);
        // Without shell plumbing the first delta teaches us the session. A
        // terminal frame releases that learned binding so a foreign stream
        // cannot hold the caption lane forever; the next turn re-learns.
        final reason = data['reason'];
        final terminal =
            data['final'] == true ||
            reason == 'cancelled' ||
            reason == 'error';
        if (terminal) _learnedSessionId = null;
      default:
        break;
    }
  }

  Future<void> dispose() async {
    _unsubscribe?.call();
    _unsubscribe = null;
    // Queue the topic unsubscribe before any await: a replacement binding
    // constructed while this dispose is suspended would otherwise subscribe
    // first, and the late unsubscribe would land on the shared daemon topic.
    _requestEventRpc('event.unsubscribe');
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _eventRpc;
  }
}
