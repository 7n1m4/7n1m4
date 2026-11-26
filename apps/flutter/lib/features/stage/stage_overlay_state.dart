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
/// the terminal marker (`final: true`) ends the turn without clearing it, so
/// the last sentence stays on screen until the next turn starts.
class StageCaptionController extends ChangeNotifier {
  StageCaptionSnapshot _snapshot = const StageCaptionSnapshot();
  String? _messageId;
  final StringBuffer _buffer = StringBuffer();
  int? _lastSeq;

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
    }
    if (delta.isNotEmpty) _buffer.write(delta);
    if (data['final'] == true) {
      _messageId = null;
      _lastSeq = null;
    }
    final buffer = _buffer.toString();
    _snapshot = StageCaptionSnapshot(
      speakerText: _snapshot.speakerText,
      segments: buffer.isEmpty
          ? const <CaptionSegment>[]
          : <CaptionSegment>[
              CaptionSegment(
                text: buffer,
                color: _snapshot.segments.isEmpty
                    ? ''
                    : _snapshot.segments.first.color,
                actorId: _snapshot.segments.isEmpty
                    ? ''
                    : _snapshot.segments.first.actorId,
              ),
            ],
    );
    notifyListeners();
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

  /// Clear the overlay.
  void clear() {
    _messageId = null;
    _lastSeq = null;
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
  }) : _background = background,
       _captions = captions,
       _showModel = showModel,
       _paused = paused,
       _actorId = actorId,
       _idle = idle {
    _captionController.addListener(notifyListeners);
  }

  StageBackground _background;
  StageCaptionStyle _captions;
  final StageCaptionController _captionController = StageCaptionController();
  StageIdleMotion _idle;
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
  }) : _client = client,
       _state = state {
    _unsubscribe = client.onEvent(_onEvent);
    _wasConnected = client.snapshot.isConnected;
    // The lane is opt-in: no subscription means no captions or cues. The
    // request is idempotent on the daemon and non-fatal when unsupported.
    _subscribe();
    _statusSubscription = client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      if (connected && !_wasConnected) _subscribe();
      _wasConnected = connected;
    });
  }

  final DaemonClient _client;
  final StageRenderState _state;

  StreamSubscription<DaemonStatus>? _statusSubscription;
  void Function()? _unsubscribe;
  Future<void> _eventRpc = Future<void>.value();
  bool _wasConnected = false;

  bool get isBound => _unsubscribe != null;

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
        _state.captions.applyTokenDelta(event.data);
      default:
        break;
    }
  }

  Future<void> dispose() async {
    _unsubscribe?.call();
    _unsubscribe = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    _requestEventRpc('event.unsubscribe');
    await _eventRpc;
  }
}
