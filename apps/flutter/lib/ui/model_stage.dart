// SPDX-License-Identifier: GPL-3.0-or-later

// The stage's canonical routing seam, copied from the Vue reference
// (`packages/stage-ui/src/components/scenes/RendererStage.vue`): kind check
// first, then asset-presence check, then render. A card that names an asset
// this client cannot resolve fails loudly instead of falling back to a
// fabricated model. Once the descriptor is valid, [NativeModelSurface] drives
// the native backend through a client-local [ModelStageRuntime].

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../daemon_client/daemon_client.dart';
import '../features/stage/method_channel_backend.dart';
import '../features/stage/model_asset_resolver.dart';
import '../features/stage/model_backend.dart';
import '../features/stage/model_runtime.dart';
import '../features/stage/model_stage_state.dart';
import '../features/stage/native_model_surface.dart';
import '../features/stage/stage_overlay_state.dart';
import '../speech/lip_sync_rms_data.dart';

/// Display-model kinds the card schema can name.
enum ModelKind {
  none,
  vrm,
  live2d,
  mmd,
  spine;

  /// Wire/catalog name used by the card schema.
  String get wireName => name;

  static ModelKind fromWireName(String? name) {
    switch (name) {
      case 'none':
        return ModelKind.none;
      case 'vrm':
        return ModelKind.vrm;
      case 'live2d-zip':
      case 'live2d-directory':
        return ModelKind.live2d;
      case 'pmx-zip':
      case 'pmx-directory':
      case 'pmd':
        return ModelKind.mmd;
      case 'spine-zip':
        return ModelKind.spine;
      default:
        return ModelKind.none;
    }
  }
}

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
  const DisplayModel({required this.kind, this.asset, this.displayModelId});

  final ModelKind kind;
  final ModelAssetRef? asset;
  final String? displayModelId;

  static const DisplayModel none = DisplayModel(kind: ModelKind.none);

  static const String missingAssetCode = 'missing-asset';
  static const String invalidAssetCode = 'invalid-asset';
  static const String unknownModelKindCode = 'unknown-model-kind';

  /// Extracts the display model from a `cards.get` result.
  ///
  /// Recognizes the inline `extensions.airi.vrm` / `.live2d` / `.mmd` /
  /// `.spine` descriptors of the card document. A card that only names a
  /// display-model id is unresolved here by design: [resolveDisplayModel] asks
  /// the daemon catalog for its asset, and an id the catalog does not know
  /// fails loudly instead of falling back to a fabricated model.
  static DisplayModel fromCard(Map<String, dynamic>? card) {
    if (card == null) return none;
    final candidates = _airiExtensions(card);
    for (final airi in candidates) {
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
    }
    // Vue's ControlStrip writes `active_state.displayModelId` as the
    // canonical live value and mirrors it into `modules`; some cards have
    // only the active_state copy. Older cards use modules or top-level.
    final ids = <Object?>[
      for (final airi in candidates) ...<Object?>[
        (airi['active_state'] is Map)
            ? (airi['active_state'] as Map)['displayModelId']
            : null,
        (airi['modules'] is Map)
            ? (airi['modules'] as Map)['displayModelId']
            : null,
        airi['displayModelId'],
      ],
    ];
    for (final candidate in ids) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        return DisplayModel(
          kind: ModelKind.none,
          asset: ModelAssetRef(kind: ModelKind.none, value: candidate),
          displayModelId: candidate,
        );
      }
    }
    return none;
  }

  /// Null when the asset is present and well-formed; otherwise the human-readable
  /// problem. Never throws.
  String? get problem {
    if (kind == ModelKind.none) {
      final value = displayModelId ?? asset?.value;
      if (value != null && value.trim().isNotEmpty) {
        return 'Display model "$value" requires daemon catalog resolution.';
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

  static List<Map<dynamic, dynamic>> _airiExtensions(
    Map<String, dynamic> card,
  ) {
    // The daemon hands back the stored card document: CCv2/CCv3 wrap the body
    // in `data`, while a bare document carries `extensions` at the top level.
    // Vue merges both mirrors with root winning per field, so include both.
    final result = <Map<dynamic, dynamic>>[];
    for (final extensions in <Object?>[
      card['extensions'],
      if (card['data'] is Map) (card['data'] as Map)['extensions'],
    ]) {
      if (extensions is! Map) continue;
      final airi = extensions['airi'];
      if (airi is Map) result.add(airi);
    }
    return result;
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

Future<DisplayModel> resolveDisplayModel(DaemonClient client, DisplayModel model) async {
  final id = model.displayModelId;
  if (id == null || id.trim().isEmpty) return model;
  final reply = await client.call('display-model.resolve', payload: {'id': id});
  if (!reply.ok) {
    throw ModelStageError(
      reply.error?.code ?? 'display-model-unresolved',
      reply.error?.message ?? 'display model could not be resolved',
    );
  }
  final data = reply.data;
  if (data is! Map) {
    throw const ModelStageError(
      'display-model-unresolved',
      'missing data',
    );
  }
  final resolvedId = data['id'];
  final name = data['name'];
  final format = data['format'];
  final source = data['source'];
  if (resolvedId is! String || name is! String || format is! String || source is! String) {
    throw const ModelStageError(
      'display-model-unresolved',
      'incomplete data',
    );
  }
  final kind = ModelKind.fromWireName(format);
  if (kind == ModelKind.none) {
    throw ModelStageError(
      'display-model-unresolved',
      'unknown model kind',
    );
  }
  final file = data['file'];
  final url = data['url'];
  final value = file is String && file.isNotEmpty
      ? file
      : url is String && url.isNotEmpty
          ? url
          : null;
  if (value == null) {
    throw ModelStageError(
      'display-model-unresolved',
      'missing asset value',
    );
  }
  return DisplayModel(
    kind: kind,
    asset: ModelAssetRef(
      kind: kind,
      source: source,
      value: value,
    ),
    displayModelId: resolvedId,
  );
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
    this.cacheDirectoryProvider,
    this.frames,
    this.actorId,
    this.render,
    this.onStatus,
  });

  final DaemonClient client;

  /// Card to display. Null/empty means "no card selected".
  final String? cardId;

  /// Injectable backend registry for tests. Defaults to method-channel
  /// adapters for all four kinds in production.
  final ModelBackendRegistry? backends;

  /// Injectable asset resolver for tests.
  final ModelAssetResolver? resolver;

  /// Injectable cache-directory provider for tests; production uses the
  /// application cache directory, never `Directory.systemTemp`.
  final ModelCacheDirectoryProvider? cacheDirectoryProvider;

  /// Real stamped frames from the local TTS pipeline, when available.
  final Stream<LipSyncRmsData>? frames;

  /// Optional actor filter for frames and emotion cues.
  final String? actorId;

  /// Client-local render state shared with the stage shell's overlays. The
  /// stage shell owns it; this widget only routes the model through it.
  final StageRenderState? render;

  /// Forwarded from the native surface so the stage shell can show delayed
  /// resource-loading feedback without owning the model runtime.
  final void Function(ModelStageStatus status)? onStatus;

  @override
  State<ModelStage> createState() => _ModelStageState();
}

class _ModelStageState extends State<ModelStage> {
  Future<DisplayModel>? _displayModel;
  late final ModelBackendRegistry _backends;
  late final ModelAssetResolver _resolver;

  @override
  void initState() {
    super.initState();
    _displayModel = _loadDisplayModel();
    _backends =
        widget.backends ??
        ModelBackendRegistry.fromRuntimes(
          supportedKinds: supportedModelKinds(defaultTargetPlatform).toSet(),
          create: (info) =>
              MethodChannelModelBackend(info.kind, info.channelName),
        );
    _resolver = widget.resolver ??
        ModelAssetResolver(cacheDirectoryProvider: widget.cacheDirectoryProvider);
  }

  @override
  void didUpdateWidget(ModelStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId != widget.cardId) {
      _displayModel = _loadDisplayModel();
    }
  }

  Future<DisplayModel> _loadDisplayModel() async {
    final cardId = widget.cardId;
    if (cardId == null || cardId.isEmpty) return DisplayModel.none;
    final card = await widget.client.cardsGet(cardId);
    final displayModel = DisplayModel.fromCard(card);
    final id = displayModel.displayModelId;
    if (id != null && id.trim().isNotEmpty) {
      return resolveDisplayModel(widget.client, displayModel);
    }
    return displayModel;
  }

  @override
  Widget build(BuildContext context) {
    final cardId = widget.cardId;
    if (cardId == null || cardId.isEmpty) {
      return const _NoModelPlaceholder();
    }
    return FutureBuilder<DisplayModel>(
      future: _displayModel,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<DisplayModel> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              final err = snapshot.error;
              if (err is ModelStageError) {
                return _LoudError(err);
              }
              return _LoudError(
                ModelStageError(
                  'load-failed',
                  _loadFailureMessage(err),
                ),
              );
            }
            final displayModel = snapshot.data ?? DisplayModel.none;
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
              onStatus: widget.onStatus,
            );
          },
    );
  }

  /// Keeps transport internals (hosts, tokens, socket text) out of the stage:
  /// the daemon's own message is already user-safe, anything else is named by
  /// its failure kind.
  static String _loadFailureMessage(Object? error) {
    if (error is ModelStageError) return error.message;
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
