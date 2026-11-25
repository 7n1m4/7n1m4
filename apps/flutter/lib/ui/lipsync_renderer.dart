// SPDX-License-Identifier: GPL-3.0-or-later

// Flutter avatar renderer's local lip-sync sink for client-generated
// `lip_sync.rms` frames. The frames originate in LipSyncGenerator (local PCM
// -> RMS tap) and carry client-stamped seq/ts_ms; they are never
// daemon-published and never fabricated here.

import 'dart:async';

import 'package:flutter/material.dart';

import '../speech/lip_sync_rms_data.dart';

/// Renders a pet that swells in proportion to the latest RMS level.
///
/// This is deliberately a generic visible sink (scale + tint) until real model
/// mouth bindings are wired: it proves a stamped frame reached a rendering
/// surface without claiming a real mouth mesh. Frames from a different actor,
/// or with a non-monotonic seq, are ignored so replayed/duplicated local frames
/// cannot drive the animation.
class LipSyncRenderer extends StatefulWidget {
  const LipSyncRenderer({
    super.key,
    required this.frames,
    this.actorId,
  });

  /// Stream of client-stamped frames, normally `LipSyncGenerator.frames()`.
  final Stream<LipSyncRmsData> frames;

  /// Optional actor filter. When set, frames for other actors are ignored.
  final String? actorId;

  @override
  State<LipSyncRenderer> createState() => _LipSyncRendererState();
}

class _LipSyncRendererState extends State<LipSyncRenderer> {
  StreamSubscription<LipSyncRmsData>? _subscription;
  LipSyncRmsData? _latest;
  int? _lastSeq;

  @override
  void initState() {
    super.initState();
    _subscription = widget.frames.listen(_onFrame);
  }

  @override
  void didUpdateWidget(LipSyncRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      _subscription?.cancel();
      _latest = null;
      _lastSeq = null;
      _subscription = widget.frames.listen(_onFrame);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onFrame(LipSyncRmsData frame) {
    if (widget.actorId != null && frame.actorId != widget.actorId) return;
    if (_lastSeq != null && frame.seq <= _lastSeq!) return;
    if (!mounted) return;
    setState(() {
      _lastSeq = frame.seq;
      _latest = frame;
    });
  }

  static const double _baseScale = 1.0;
  static const double _maxSwell = 0.7;

  @override
  Widget build(BuildContext context) {
    final level = _latest?.level ?? 0.0;
    final scale = _baseScale + _maxSwell * level;
    final tint = Color.lerp(AppThemeLipSync.idle, AppThemeLipSync.speaking, level) ??
        AppThemeLipSync.idle;
    final label = _latest == null
        ? 'No lip-sync frames yet'
        : '${_latest!.actorId} · level ${_latest!.level.toStringAsFixed(2)} · '
            'seq ${_latest!.seq} · ts ${_latest!.tsMs}';

    return Semantics(
      label: 'Lip-sync pet: $label',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedScale(
            key: const Key('lip-sync-pet'),
            scale: scale,
            duration: const Duration(milliseconds: 80),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: tint,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, key: const Key('lip-sync-status')),
        ],
      ),
    );
  }
}

/// Local palette; kept here so the renderer has no dependency on a screen.
abstract final class AppThemeLipSync {
  static const Color idle = Color(0xFF3C4656);
  static const Color speaking = Color(0xFF8AB4F8);
}
