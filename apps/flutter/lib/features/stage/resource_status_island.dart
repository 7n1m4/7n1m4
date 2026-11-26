// SPDX-License-Identifier: GPL-3.0-or-later

// Parity port of the Vue resource-status island: a pill that appears on the
// first loading transition, delays *later* transitions by 5s (detail 10s),
// and flips to "Ready!" when the load finishes — mirroring Vue's
// `refDelayed(..., { immediate: true })`. Flutter has no per-module
// progress callback (`MethodChannelModelBackend.load` returns a handle only),
// so the sole input is the boolean `ModelStageStatus.loading` condition, plus
// whatever detail lines the caller can supply. No native channel or wire type
// is involved.

import 'dart:async';

import 'package:flutter/material.dart';

import 'model_stage_state.dart';

/// Cancel handle returned by a timer factory. Wrapping `Timer.cancel` keeps the
/// clock injectable without exposing `Timer` to test doubles.
typedef ResourceCancel = void Function();

/// Injectable async seam: schedule [callback] after [duration], return a
/// canceller. Production uses a real [Timer]; tests fire callbacks by hand.
typedef ResourceTimerFactory =
    ResourceCancel Function(Duration duration, void Function() callback);

ResourceCancel _defaultTimerFactory(
  Duration duration,
  void Function() callback,
) => Timer(duration, callback).cancel;

/// Delayed stage-loading status pill.
///
/// [status] is the existing model-stage status; only its `loading` (and
/// `resolving`) states count as in-progress, matching the spinner in
/// `NativeModelSurface`. [detail] is the expandable content when available.
class ResourceStatusIsland extends StatefulWidget {
  const ResourceStatusIsland({
    super.key,
    required this.status,
    this.detail = const <String>[],
    this.delay5s = const Duration(seconds: 5),
    this.delay10s = const Duration(seconds: 10),
    this.timerFactory,
  });

  final ModelStageStatus status;
  final List<String> detail;

  /// Defaults match the Vue reference's 5s/10s delayed flags.
  final Duration delay5s;
  final Duration delay10s;

  /// Override in tests to avoid real sleeps.
  final ResourceTimerFactory? timerFactory;

  @override
  State<ResourceStatusIsland> createState() => _ResourceStatusIslandState();
}

class _ResourceStatusIslandState extends State<ResourceStatusIsland> {
  late ResourceTimerFactory _createTimer;
  ResourceCancel? _cancelPill;
  ResourceCancel? _cancelDetail;
  late bool _loading;
  bool _firstChange = true;
  bool _showPill = false;
  bool _showDetail = false;
  bool _expanded = false;

  bool get _isLoading => switch (widget.status) {
        ModelStageStatus.loading || ModelStageStatus.resolving => true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _createTimer = widget.timerFactory ?? _defaultTimerFactory;
    _loading = _isLoading;
    // Only a transition *into* loading is immediate; if the island already
    // mounts loading, the first change (to ready) must still obey the delay.
    _firstChange = !_loading;
    // Vue's `refDelayed(..., { immediate: true })` seeds the delayed flags
    // from the current value, so a load already in progress at mount is shown
    // at once; only later transitions are delayed.
    _showPill = _loading;
    _showDetail = _loading;
    _expanded = _loading;
  }

  @override
  void didUpdateWidget(covariant ResourceStatusIsland oldWidget) {
    super.didUpdateWidget(oldWidget);
    _createTimer = widget.timerFactory ?? _defaultTimerFactory;
    final loading = _isLoading;
    if (loading == _loading) return;
    _cancelPill?.call();
    _cancelDetail?.call();
    _loading = loading;
    if (!mounted) return;
    if (_firstChange) {
      // First observed transition is immediate, like Vue's `immediate: true`.
      _firstChange = false;
      setState(() {
        _showPill = loading;
        _showDetail = loading;
        _expanded = loading;
      });
      return;
    }
    setState(() => _expanded = loading);
    _schedule(loading);
  }

  /// Mirrors the Vue `refDelayed`: a state change reaches the pill/detail
  /// only after its own delay, so a short blip never flashes the surface.
  void _schedule(bool loading) {
    _cancelPill = _createTimer(widget.delay5s, () {
      if (!mounted) return;
      setState(() => _showPill = loading);
    });
    _cancelDetail = _createTimer(widget.delay10s, () {
      if (!mounted) return;
      setState(() => _showDetail = loading);
    });
  }

  @override
  void dispose() {
    _cancelPill?.call();
    _cancelDetail?.call();
    super.dispose();
  }

  void _toggleExpanded() {
    if (!_showDetail) return;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      top: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_showPill)
            Semantics(
              label: _loading ? 'Resources loading' : 'Resources ready',
              child: GestureDetector(
                key: const Key('resource-status-pill'),
                onTap: _toggleExpanded,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _loading ? Icons.hourglass_top : Icons.check_circle,
                        size: 16,
                        color: _loading ? null : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _loading ? 'Resources loading...' : 'Ready!',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showDetail && _expanded)
            Container(
              key: const Key('resource-status-detail'),
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Stage model: ${widget.status.name}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  for (final line in widget.detail)
                    Text(line, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
