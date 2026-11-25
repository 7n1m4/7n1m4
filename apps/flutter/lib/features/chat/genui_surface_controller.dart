// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:genui/genui.dart';

import 'genui_catalog.dart';

/// One assistant turn: sanitized text plus the GenUI surfaces it produced.
class AiriGenUiTurn {
  const AiriGenUiTurn({
    required this.text,
    required this.surfaceIds,
    required this.failed,
  });

  final String text;

  /// Surface ids in creation order, without duplicates.
  final List<String> surfaceIds;

  /// True when an attempted dynamic widget could not be displayed.
  final bool failed;
}

/// Owns GenUI surfaces across assistant turns and parses A2UI from streamed
/// token output.
///
/// The SDK parser handles fenced/raw JSON and separates text from A2UI
/// messages. Callers feed the full accumulated turn (not isolated deltas) to
/// [parseTurn]; controller and parser failures are contained here.
class AiriGenUiSession {
  AiriGenUiSession({SurfaceController? controller})
      : _controller = controller ?? SurfaceController(catalogs: [airiGenUiCatalog()]);

  final SurfaceController _controller;
  final Set<String> _seenSurfaceIds = <String>{};
  bool _failed = false;

  /// Feed the accumulated text for a finished assistant turn.
  Future<AiriGenUiTurn> parseTurn(String output) async {
    if (output.isEmpty) {
      return const AiriGenUiTurn(
        text: '',
        surfaceIds: <String>[],
        failed: false,
      );
    }

    final transport = A2uiTransportAdapter();
    final text = StringBuffer();
    var malformed = false;

    // Both streams have error handlers: versioned malformed A2UI is emitted as
    // a parser error and must never escape into the widget tree. genui's own
    // internal pipeline subscription has no error handler, so parsing runs in
    // a guarded zone as a second containment layer.
    final textSub = transport.incomingText.listen(
      text.write,
      onError: (Object error, StackTrace stack) => malformed = true,
      cancelOnError: false,
    );
    final messageSub = transport.incomingMessages.listen((message) {
      try {
        _controller.handleMessage(message);
      } on Object {
        malformed = true;
      }
    }, onError: (Object error, StackTrace stack) {
      malformed = true;
    }, cancelOnError: false);

    final zone = Zone.current;
    await runZonedGuarded(() async {
      transport.addChunk(output);
      // flush() closes the parser's input: all events for this turn have been
      // delivered by the time it completes.
      await transport.flush();
    }, (Object error, StackTrace stack) {
      malformed = true;
      zone.run(() {});
    });
    await textSub.cancel();
    await messageSub.cancel();
    transport.dispose();

    final attempted = _controller.activeSurfaceIds
        .where((id) => !_seenSurfaceIds.contains(id))
        .toList();
    _seenSurfaceIds.addAll(attempted);
    final surfaces = attempted.where(_isRenderable).toList();
    return AiriGenUiTurn(
      text: text.toString(),
      surfaceIds: surfaces,
      // A created surface whose components are outside the curated catalog is
      // intentionally not rendered; tell the chat UI to show its safe fallback.
      failed: _failed || malformed || (attempted.isNotEmpty && surfaces.isEmpty),
    );
  }

  bool _isRenderable(String surfaceId) {
    try {
      final context = _controller.contextFor(surfaceId);
      final catalog = context.catalog;
      final definition = context.definition.value;
      if (definition == null ||
          !definition.components.containsKey('root') ||
          catalog == null) {
        return false;
      }
      final allowed = catalog.items.map((item) => item.name).toSet();
      return definition.components.values
          .every((component) => allowed.contains(component.type));
    } on Object {
      _failed = true;
      return false;
    }
  }

  /// Builds a surface card, containing construction-time failures locally.
  Widget surfaceWidget(String surfaceId, {Key? key}) {
    return AiriGenUiSurface(
      key: key ?? ValueKey<String>('genui-$surfaceId'),
      session: this,
      surfaceId: surfaceId,
    );
  }

  /// Exposes the context for a surface; GenUI surfaces are keyed by id.
  SurfaceContext? surfaceContext(String surfaceId) {
    try {
      return _controller.contextFor(surfaceId);
    } on Object {
      _failed = true;
      return null;
    }
  }

  void dispose() {
    _controller.dispose();
  }
}

/// Renders one GenUI surface with a safe, non-technical fallback.
class AiriGenUiSurface extends StatefulWidget {
  const AiriGenUiSurface({
    super.key,
    required this.session,
    required this.surfaceId,
  });

  final AiriGenUiSession session;
  final String surfaceId;

  @override
  State<AiriGenUiSurface> createState() => _AiriGenUiSurfaceState();
}

class _AiriGenUiSurfaceState extends State<AiriGenUiSurface> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    if (_failed) return const Text('A dynamic widget could not be displayed.');
    try {
      final surfaceContext = widget.session.surfaceContext(widget.surfaceId);
      if (surfaceContext == null) throw StateError('Missing GenUI surface');
      return Surface(surfaceContext: surfaceContext);
    } on Object {
      _failed = true;
      return const Text('A dynamic widget could not be displayed.');
    }
  }
}
