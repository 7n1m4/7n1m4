// SPDX-License-Identifier: GPL-3.0-or-later

// The Live2D legal gate (`docs/design-live2d-legal-gate.md`) as executable
// policy: the kind stays loud and unavailable, and no other kind is blocked by
// licensing. No GPU, no daemon, no Cubism Core on disk.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/model_runtime.dart';
import 'package:anima_control/ui/model_stage.dart';

void main() {
  test('the maintainer gate note states every clause of the policy', () {
    expect(kLive2DLegalGateNote, contains('maintainer'));
    expect(kLive2DLegalGateNote, contains('legal/release approval'));
    expect(kLive2DLegalGateNote, contains('3D ships first'));
    expect(kLive2DLegalGateNote, contains('after accepting the terms'));
    expect(kLive2DLegalGateNote, contains('never committed'));
  });

  test('Live2D is the only licensing-blocked kind and stays unavailable', () {
    final live2d = runtimeFor(ModelKind.live2d);
    expect(live2d.blocker, ModelRuntimeBlocker.cubismLicense);
    expect(live2d.isAvailable, isFalse);
    expect(live2d.licenseNote, contains('never committed'));

    for (final info in kModelRuntimes) {
      if (info.kind == ModelKind.live2d) continue;
      expect(
        info.blocker,
        isNull,
        reason: '${info.kind.name} must not be licensing-blocked',
      );
    }
  });

  test('the default registry turns the gate into a loud unavailable backend', () {
    final backend = ModelBackendRegistry.fromRuntimes().backendFor(
      ModelKind.live2d,
    );
    expect(backend, isA<UnavailableModelBackend>());
    expect(
      (backend as UnavailableModelBackend).blocker,
      ModelRuntimeBlocker.cubismLicense,
    );
  });

  test('the production registry hides kinds with no backend on this host', () {
    final registry = ModelBackendRegistry.fromRuntimes(
      supportedKinds: supportedModelKinds(defaultTargetPlatform).toSet(),
      create: (info) => RecordingModelBackend(info.kind),
    );
    for (final kind in supportedModelKinds(defaultTargetPlatform)) {
      expect(registry.backendFor(kind), isA<RecordingModelBackend>());
    }
    for (final kind in <ModelKind>[
      ModelKind.live2d,
      ModelKind.mmd,
      ModelKind.spine,
    ]) {
      expect(
        registry.backendFor(kind),
        isA<UnavailableModelBackend>(),
        reason: '${kind.name} has no renderer on this host',
      );
    }
  });

  test('a platform filter keeps only renderers registered on that host', () {
    final registry = ModelBackendRegistry.fromRuntimes(
      supportedKinds: const <ModelKind>{ModelKind.vrm},
      create: (info) => RecordingModelBackend(info.kind),
    );
    expect(
      registry.backendFor(ModelKind.vrm),
      isA<RecordingModelBackend>(),
    );
    for (final kind in <ModelKind>[
      ModelKind.live2d,
      ModelKind.mmd,
      ModelKind.spine,
    ]) {
      expect(
        registry.backendFor(kind),
        isA<UnavailableModelBackend>(),
        reason: '${kind.name} has no renderer on this host',
      );
    }
  });

  test('a Live2D load fails loudly and never yields a handle', () async {
    final backend = ModelBackendRegistry.fromRuntimes().backendFor(
      ModelKind.live2d,
    );
    await expectLater(
      backend.load(
        const ResolvedModelAsset(
          path: '/nonexistent/user-fetched/model.moc3',
          source: 'file',
          originalValue: 'model.moc3',
          fingerprint: 'test',
          byteLength: 0,
        ),
      ),
      throwsA(
        isA<ModelBackendException>().having(
          (error) => error.code,
          'code',
          'runtime-unavailable',
        ),
      ),
    );
  });
}