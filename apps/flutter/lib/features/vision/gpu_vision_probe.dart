// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local GPU/vision capability probe.
//
// The daemon owns provider routing; this holder only *reports* what the local
// device exposes (renderer/backend strings) via a platform channel. When no
// native implementation is registered (MissingPluginException / PlatformException
// / any malformed reply) the result is the documented stub
// [GpuVisionProbeResult.unknown] with renderer/backend == 'unknown' and
// available == false. Nothing here decides or writes provider selection.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Snapshot of what the local device exposes for GPU/vision work.
class GpuVisionProbeResult {
  const GpuVisionProbeResult({
    required this.renderer,
    required this.backend,
    required this.available,
  });

  /// Renderer string reported by the platform (e.g. "ANGLE (NVIDIA ...)"),
  /// or 'unknown' when the platform did not report one.
  final String renderer;

  /// Backend string reported by the platform (e.g. "vulkan", "metal", "gl"),
  /// or 'unknown' when the platform did not report one.
  final String backend;

  /// Whether any GPU/vision backend is available on this device.
  final bool available;

  /// Documented stub used when no probe is possible or the reply is unusable.
  static const GpuVisionProbeResult unknown = GpuVisionProbeResult(
    renderer: 'unknown',
    backend: 'unknown',
    available: false,
  );

  bool get isUnknown => this == GpuVisionProbeResult.unknown;

  @override
  bool operator ==(Object other) =>
      other is GpuVisionProbeResult &&
      other.renderer == renderer &&
      other.backend == backend &&
      other.available == available;

  @override
  int get hashCode => Object.hash(renderer, backend, available);
}

/// Holds the latest GPU/vision capability reported by the local device.
///
/// Follows the ChangeNotifier pattern used by other client-local state holders
/// (e.g. [PresenceEventState]); the channel is injectable for tests.
class GpuVisionProbe extends ChangeNotifier {
  GpuVisionProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'org.moeru.airi/anima/gpu_vision';

  final MethodChannel _channel;

  GpuVisionProbeResult _result = GpuVisionProbeResult.unknown;
  bool _probing = false;

  GpuVisionProbeResult get result => _result;
  bool get isProbing => _probing;

  /// Queries the platform once and stores the (possibly stub) result.
  /// Re-entrant calls while a probe is in flight return the current result.
  Future<GpuVisionProbeResult> probe() async {
    if (_probing) return _result;
    _probing = true;
    notifyListeners();
    try {
      final reply = await _channel.invokeMethod<Map<dynamic, dynamic>>('probe');
      final renderer = reply?['renderer'];
      final backend = reply?['backend'];
      final available = reply?['available'];
      _result = GpuVisionProbeResult(
        renderer: renderer is String && renderer.isNotEmpty
            ? renderer
            : 'unknown',
        backend: backend is String && backend.isNotEmpty ? backend : 'unknown',
        available: available == true,
      );
    } on MissingPluginException {
      _result = GpuVisionProbeResult.unknown;
    } on PlatformException {
      _result = GpuVisionProbeResult.unknown;
    } catch (_) {
      _result = GpuVisionProbeResult.unknown;
    }
    _probing = false;
    notifyListeners();
    return _result;
  }

  /// Resets to the documented stub (e.g. when the client goes offline).
  void reset() {
    if (_result == GpuVisionProbeResult.unknown && !_probing) return;
    _result = GpuVisionProbeResult.unknown;
    _probing = false;
    notifyListeners();
  }
}
