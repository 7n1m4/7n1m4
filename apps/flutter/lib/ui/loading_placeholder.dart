// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

/// A shape-preserving loading placeholder.
///
/// [child] defines the skeleton's geometry; this widget only pulses its
/// opacity. It is purely presentational and announces itself as loading to
/// assistive technology.
class LoadingPlaceholder extends StatefulWidget {
  const LoadingPlaceholder({
    super.key,
    required this.child,
    this.label = 'Loading',
  });

  /// Widget whose layout defines the placeholder's shape.
  final Widget child;

  /// Accessibility label announced while loading.
  final String label;

  @override
  State<LoadingPlaceholder> createState() => _LoadingPlaceholderState();
}

class _LoadingPlaceholderState extends State<LoadingPlaceholder>
    with SingleTickerProviderStateMixin {
  static const Duration _pulseDuration = Duration(milliseconds: 1200);
  static const double _dimOpacity = 0.4;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _pulseDuration,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: _dimOpacity,
    end: 1.0,
  ).animate(_controller);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // The shape is decorative: only the placeholder's own label is announced.
    final Widget shape = ExcludeSemantics(child: widget.child);
    return Semantics(
      label: widget.label,
      child: reduceMotion
          ? Opacity(opacity: 0.7, child: shape)
          : FadeTransition(opacity: _opacity, child: shape),
    );
  }
}
