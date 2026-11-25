// SPDX-License-Identifier: GPL-3.0-or-later

// The stage's canonical routing seam, copied from the Vue reference
// (`packages/stage-ui/src/components/scenes/RendererStage.vue`): kind check
// first, then asset-presence check, then render. A card that names an asset
// this client cannot resolve fails loudly instead of falling back to a
// fabricated model. Once the descriptor is valid, [NativeModelSurface] drives
// the native backend through a client-local [ModelStageRuntime].

import 'dart:io';

import 'package:flutter/material.dart';

import '../daemon_client/daemon_client.dart';
import '../features/stage/method_channel_backend.dart';
import '../features/stage/model_asset_resolver.dart';
import '../features/stage/model_backend.dart';
import '../features/stage/native_model_surface.dart';
import '../features/stage/stage_overlay_state.dart';
import '../speech/lip_sync_rms_data.dart';

/// Display-model kinds the card schema can name.
enum ModelKind { none, vrm, live2d, mmd, spine }

/// Where a display model's asset lives: a `file`/`url` source plus its value,
/// or a bare display-model id.
class ModelAssetRef {
  const ModelAssetRef({required this.kind, this.source, this.value});

  final ModelKind kind;

  /// `'file'`, `'url'`, or null when the descriptor carries only a value.
  final String? source;

  /// File path, URL, or display-model id.
  final String? value;

  bool get isEmpty => value == null || value!.trim().isEmpty;
}

/// The display model a card asks for, resolved from `cards.get` output.
class DisplayModel {
  const DisplayModel({required this.kind, this.asset});

  final ModelKind kind;
  final ModelAssetRef? asset;

  static const DisplayModel none = DisplayModel(kind: ModelKind.none);

  static const String missingAssetCode = 'missing-asset';
  static const String invalidAssetCode = 'invalid-asset';
  static const String unknownModelKindCode = 'unknown-model-kind';

  /// Extracts the display model from a `cards.get` result.
  ///
  /// Recognizes the inline `extensions.airi.vrm` / `.live2d` / `.mmd` /
  /// `.spine` descriptors of the card document. A card that only carries
  /// `extensions.airi.displayModelId` is intentionally unresolved here — the
  /// display-model store that maps ids to assets is a later bead — and surfaces
  /// as a loud `unknown-model-kind` rather than a silent fallback.
  static DisplayModel fromCard(Map<String, dynamic>? card) {
    if (card == null) return none;
    final airi = _airiExtension(card);
    if (airi == null) return none;
    for (final entry in const <(ModelKind, String)>[
      (ModelKind.vrm, 'vrm'),
      (ModelKind.live2d, 'live2d'),
      (ModelKind.mmd, 'mmd'),
      (ModelKind.spine, 'spine'),
    ]) {
      final descriptor = airi[entry.$2];
      if (descriptor is Map) {
        return DisplayModel(
          kind: entry.$1,
          asset: _assetFromDescriptor(entry.$1, descriptor),
        );
      }
    }
    final displayModelId = airi['displayModelId'];
    if (displayModelId is String && displayModelId.trim().isNotEmpty) {
      return DisplayModel(
        kind: ModelKind.none,
        asset: ModelAssetRef(kind: ModelKind.none, value: displayModelId),
      );
    }
    return none;
  }

  /// Null when the asset is present and well-formed; otherwise the human-readable
  /// problem. Never throws.
  String? get problem {
    if (kind == ModelKind.none) {
      final value = asset?.value;
      if (value != null && value.trim().isNotEmpty) {
        return 'Model kind is unresolved: display model "$value" is named by id '
            'only, and this client cannot resolve ids to assets yet.';
      }
      return null;
    }
    final ref = asset;
    if (ref == null || ref.isEmpty) {
      return 'Missing model asset: the card names a ${kind.name} model but no '
          'file or URL.';
    }
    final value = ref.value!.trim();
    switch (ref.source) {
      case 'url':
        final uri = Uri.tryParse(value);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return 'Invalid model asset: "$value" is not an http(s) URL.';
        }
      case 'file':
      case null:
        return null;
      default:
        return 'Invalid model asset: unknown source "${ref.source}".';
    }
    return null;
  }

  /// The [ModelStageError] code for [problem], or null when there is none.
  String? get problemCode {
    final text = problem;
    if (text == null) return null;
    if (text.startsWith('Missing model asset')) return missingAssetCode;
    if (text.startsWith('Invalid model asset')) return invalidAssetCode;
    return unknownModelKindCode;
  }

  static Map<dynamic, dynamic>? _airiExtension(Map<String, dynamic> card) {
    // The daemon hands back the stored card document: CCv2/CCv3 wrap the body
    // in `data`, while a bare document carries `extensions` at the top level.
    final data = card['data'];
    final extensions = data is Map ? data['extensions'] : card['extensions'];
    if (extensions is! Map) return null;
    final airi = extensions['airi'];
    return airi is Map ? airi : null;
  }

  static ModelAssetRef _assetFromDescriptor(
    ModelKind kind,
    Map<dynamic, dynamic> descriptor,
  ) {
    final file = descriptor['file'];
    final url = descriptor['url'];
    final source = descriptor['source'];
    return ModelAssetRef(
      kind: kind,
      source: source is String && source.isNotEmpty ? source : null,
      value: file is String && file.isNotEmpty
          ? file
          : url is String && url.isNotEmpty
          ? url
          : null,
    );
  }
}

/// A loud, typed stage failure. Nothing is rendered in place of the model.
class ModelStageError implements Exception {
  const ModelStageError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ModelStageError($code): $message';
}

/// One card's display-model surface.
///
/// Loads the card through `cards.get` (the only read seam) and routes it.
/// Renders a placeholder when the card names no model, a loud error when it
/// names an asset this client cannot resolve, and otherwise delegates to the
/// native model surface. There is exactly one model-stage entry point: this
/// widget; [NativeModelSurface] is its render phase, not a competing router.
class ModelStage extends StatefulWidget {
  const ModelStage({
    super.key,
    required this.client,
    this.cardId,
    this.backends,
    this.resolver,
    this.frames,
    this.actorId,
    this.render,
  });

  final DaemonClient client;

  /// Card to display. Null/empty means "no card selected".
  final String? cardId;

  /// Injectable backend registry for tests. Defaults to method-channel
  /// adapters for all four kinds in production.
  final ModelBackendRegistry? backends;

  /// Injectable asset resolver for tests.
  final ModelAssetResolver? resolver;

  /// Real stamped frames from the local TTS pipeline, when available.
  final Stream<LipSyncRmsData>? frames;

  /// Optional actor filter for frames and emotion cues.
  final String? actorId;

  /// Client-local render state shared with the stage shell's overlays. The
  /// stage shell owns it; this widget only routes the model through it.
  final StageRenderState? render;

  @override
  State<ModelStage> createState() => _ModelStageState();
}

class _ModelStageState extends State<ModelStage> {
  Future<Map<String, dynamic>?>? _card;
  late final ModelBackendRegistry _backends;
  late final ModelAssetResolver _resolver;

  @override
  void initState() {
    super.initState();
    _card = _load();
    _backends =
        widget.backends ??
        ModelBackendRegistry.fromRuntimes(
          create: (info) =>
              MethodChannelModelBackend(info.kind, info.channelName),
        );
    _resolver =
        widget.resolver ??
        ModelAssetResolver(cacheDirectory: Directory.systemTemp);
  }

  @override
  void didUpdateWidget(ModelStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId != widget.cardId) _card = _load();
  }

  Future<Map<String, dynamic>?> _load() async {
    final cardId = widget.cardId;
    if (cardId == null || cardId.isEmpty) return null;
    return widget.client.cardsGet(cardId);
  }

  @override
  Widget build(BuildContext context) {
    final cardId = widget.cardId;
    if (cardId == null || cardId.isEmpty) {
      return const _NoModelPlaceholder();
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: _card,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<Map<String, dynamic>?> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _LoudError(
                ModelStageError(
                  'load-failed',
                  _loadFailureMessage(snapshot.error),
                ),
              );
            }
            final displayModel = DisplayModel.fromCard(snapshot.data);
            final problem = displayModel.problem;
            if (problem != null) {
              return _LoudError(
                ModelStageError(displayModel.problemCode!, problem),
              );
            }
            if (displayModel.kind == ModelKind.none) {
              return const _NoModelPlaceholder();
            }
            if (widget.backends == null && widget.resolver == null) {
              return _KindPlaceholder(kind: displayModel.kind);
            }
            return NativeModelSurface(
              key: ValueKey<String>(
                '${displayModel.kind}-${displayModel.asset?.value}',
              ),
              client: widget.client,
              model: displayModel,
              backends: _backends,
              resolver: _resolver,
              frames: widget.frames,
              actorId: widget.actorId,
              render: widget.render,
            );
          },
    );
  }

  /// Keeps transport internals (hosts, tokens, socket text) out of the stage:
  /// the daemon's own message is already user-safe, anything else is named by
  /// its failure kind.
  static String _loadFailureMessage(Object? error) {
    if (error is DaemonClientException) return error.message;
    return 'The card could not be loaded '
        '(${error?.runtimeType ?? 'unknown error'}).';
  }
}

class _NoModelPlaceholder extends StatelessWidget {
  const _NoModelPlaceholder();

  @override
  Widget build(BuildContext context) {
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_not_supported_outlined, size: 48, color: subtle),
          const SizedBox(height: 12),
          Text(
            'No display model',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'This card does not name a model to display.',
            style: TextStyle(color: subtle),
          ),
        ],
      ),
    );
  }
}

class _KindPlaceholder extends StatelessWidget {
  const _KindPlaceholder({required this.kind});

  final ModelKind kind;

  @override
  Widget build(BuildContext context) {
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.view_in_ar_outlined, size: 48, color: subtle),
          const SizedBox(height: 12),
          Text(
            '${kind.name.toUpperCase()} model · renderer pending',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'The asset is resolved; rendering arrives with the renderer bead.',
            style: TextStyle(color: subtle),
          ),
        ],
      ),
    );
  }
}

class _LoudError extends StatelessWidget {
  const _LoudError(this.error);

  final ModelStageError error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Semantics(
        label: 'Model stage error: ${error.message}',
        child: Card(
          color: colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, color: colorScheme.error),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Model stage error',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        error.message,
                        style: TextStyle(color: colorScheme.error),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        error.code,
                        style: TextStyle(
                          color: colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
