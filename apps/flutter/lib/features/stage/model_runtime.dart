// SPDX-License-Identifier: GPL-3.0-or-later

// Static runtime capabilities for every display-model kind. This module owns
// the licensing/support policy so the stage never silently pretends a backend
// can render an asset. No native SDK, binary, or model is bundled: the platform
// side supplies the renderer through [ModelBackend] and the user supplies the
// asset through the card descriptor or the asset resolver.
//
// Live2D is hard-blocked until the maintainer records legal/release approval
// (`docs/design-live2d-legal-gate.md`); nothing here downloads, bundles or
// commits a Cubism Core.

import 'package:flutter/foundation.dart';

import '../../ui/model_stage.dart';

/// Why a backend cannot be used on this client, or null when it can.
enum ModelRuntimeBlocker {
  /// The desktop+mobile native backend is not shipped by this build.
  missingRuntime,

  /// Cubism Core must be fetched and accepted by the user (never committed).
  ///
  /// Live2D is hard-blocked until the maintainer records legal/release
  /// approval. The user must fetch the Cubism Core from Live2D after accepting
  /// the terms; the core is never committed. There is no flag or setting that
  /// clears this blocker.
  cubismLicense,
}

/// Static, user-facing facts about one model kind's native runtime.
class ModelRuntimeInfo {
  const ModelRuntimeInfo({
    required this.kind,
    required this.channelName,
    required this.licenseNote,
    required this.blocker,
  });

  final ModelKind kind;
  final String channelName;
  final String licenseNote;

  /// Null when this build can attempt to load the kind.
  final ModelRuntimeBlocker? blocker;

  bool get isAvailable => blocker == null;
}

/// Single source of truth for the four model kinds.
///
/// The values mirror the in-tree Rust references: VRM/MMD are 3D, Spine is 2D,
/// Live2D requires a user-fetched Cubism Core (`design-flutter-godot-pivot.md`
/// decisions 4/A and the licensing gate). The channel names are the contract
/// implemented by the native side of this Flutter client.
const List<ModelRuntimeInfo> kModelRuntimes = <ModelRuntimeInfo>[
  ModelRuntimeInfo(
    kind: ModelKind.vrm,
    channelName: 'org.moeru.airi/anima/model/vrm',
    licenseNote: 'VRM assets are user-supplied; no model is bundled.',
    blocker: null,
  ),
  ModelRuntimeInfo(
    kind: ModelKind.spine,
    channelName: 'org.moeru.airi/anima/model/spine',
    licenseNote:
        'Spine Runtimes License applies to the native runtime; '
        'export version must match the editor export.',
    blocker: null,
  ),
  ModelRuntimeInfo(
    kind: ModelKind.mmd,
    channelName: 'org.moeru.airi/anima/model/mmd',
    licenseNote:
        'PMX/VMD models are usually redistribution-restricted; '
        'assets are user-supplied.',
    blocker: null,
  ),
  ModelRuntimeInfo(
    kind: ModelKind.live2d,
    channelName: 'org.moeru.airi/anima/model/live2d',
    licenseNote:
        'Live2D needs a user-fetched Cubism Core accepted under the '
        'Live2D terms; the core is never committed.',
    blocker: ModelRuntimeBlocker.cubismLicense,
  ),
];

/// Maintainer owns approval, 3D ships first, hard-blocked until review,
/// user-fetched after terms, never committed.
const String kLive2DLegalGateNote =
    'Live2D is hard-blocked until the maintainer records legal/release '
    'approval (`docs/design-live2d-legal-gate.md`). 3D ships first; the user '
    'fetches the Cubism Core from Live2D after accepting the terms; the core is '
    'never committed.';

/// Look up the runtime info for [kind]. Throws for an unknown kind; callers
/// route only validated [DisplayModel] values here. The Live2D entry is the
/// executable form of the legal gate; see `docs/design-live2d-legal-gate.md`.
ModelRuntimeInfo runtimeFor(ModelKind kind) =>
    kModelRuntimes.firstWhere((info) => info.kind == kind);

/// Model kinds whose native renderer is actually registered on [platform].
///
/// The in-tree plugin currently ships only the frozen VRM channel on Linux,
/// and no native renderer at all on the other targets. A kind absent here is
/// hidden from the stage's model choices instead of offering a card that can
/// only fail with `runtime-unavailable`.
///
/// Override [registeredKinds] in tests or embedding hosts that ship more
/// renderers; production derives it from the platform's plugin registrations.
List<ModelKind> supportedModelKinds(
  TargetPlatform platform, {
  Set<ModelKind>? registeredKinds,
}) {
  final registered = registeredKinds ??
      switch (platform) {
        TargetPlatform.linux => const <ModelKind>{ModelKind.vrm},
        _ => const <ModelKind>{},
      };
  return kModelRuntimes
      .where((info) => info.isAvailable && registered.contains(info.kind))
      .map((info) => info.kind)
      .toList(growable: false);
}

/// Whether [kind] can render on [platform] in this build.
bool modelKindSupported(
  TargetPlatform platform,
  ModelKind kind, {
  Set<ModelKind>? registeredKinds,
}) => supportedModelKinds(
  platform,
  registeredKinds: registeredKinds,
).contains(kind);
