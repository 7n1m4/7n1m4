// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local mirror of the daemon-published presence/status event lane.
// The daemon is the sole owner of these values: this holder starts empty and
// only ever stores payloads decoded from real `presence.changed` /
// `status.changed` frames. It never infers, defaults or fabricates presence or
// health when a payload is missing or malformed.

import 'package:flutter/foundation.dart';

import '../../daemon_client/daemon_client.dart';

/// Latest presence for one subject, as published on `presence.changed`.
class PresenceEntry {
  const PresenceEntry({
    required this.subject,
    required this.state,
    required this.seq,
    required this.tsMs,
  });

  final String subject;
  final String state;
  final int seq;
  final int tsMs;
}

/// Latest coarse core health, as published on `status.changed`.
class CoreHealthEntry {
  const CoreHealthEntry({
    required this.coreAvailable,
    required this.storeAvailable,
    required this.storeHealth,
    required this.seq,
    required this.tsMs,
  });

  final bool coreAvailable;
  final bool storeAvailable;
  final String storeHealth;
  final int seq;
  final int tsMs;
}

/// Immutable snapshot. Null fields mean "no valid daemon frame received yet",
/// never "offline" or "unhealthy".
class PresenceEventSnapshot {
  const PresenceEventSnapshot({
    this.presenceBySubject = const <String, PresenceEntry>{},
    this.coreHealth,
  });

  final Map<String, PresenceEntry> presenceBySubject;
  final CoreHealthEntry? coreHealth;

  /// Presence of [subject], or null when the daemon has not published one.
  PresenceEntry? presenceOf(String subject) => presenceBySubject[subject];

  bool get isEmpty => presenceBySubject.isEmpty && coreHealth == null;
}

/// Consumes presence/status frames from the event lane and keeps an
/// immutable snapshot for UI surfaces. Sequence numbers let an older replay
/// (or an out-of-order delivery) be dropped without corrupting state.
class PresenceEventState extends ChangeNotifier {
  PresenceEventSnapshot _snapshot = const PresenceEventSnapshot();
  final Map<String, int> _lastPresenceSeq = <String, int>{};
  int? _lastStatusSeq;

  PresenceEventSnapshot get snapshot => _snapshot;

  /// Applies a decoded payload. Returns false (without notifying) when the
  /// payload is null — the caller must not substitute defaults.
  bool applyPayload(Object? payload) => switch (payload) {
        PresenceChangedData(:final subject, :final state, :final seq, :final tsMs) =>
          _applyPresence(subject, state, seq, tsMs),
        StatusChangedData(
          :final coreAvailable,
          :final storeAvailable,
          :final storeHealth,
          :final seq,
          :final tsMs,
        ) =>
          _applyStatus(
            coreAvailable,
            storeAvailable,
            storeHealth,
            seq,
            tsMs,
          ),
        _ => false,
      };

  bool _applyPresence(String subject, String state, int seq, int tsMs) {
    final last = _lastPresenceSeq[subject];
    if (last != null && seq <= last) return false;
    _lastPresenceSeq[subject] = seq;
    _snapshot = PresenceEventSnapshot(
      presenceBySubject: <String, PresenceEntry>{
        ..._snapshot.presenceBySubject,
        subject: PresenceEntry(
          subject: subject,
          state: state,
          seq: seq,
          tsMs: tsMs,
        ),
      },
      coreHealth: _snapshot.coreHealth,
    );
    notifyListeners();
    return true;
  }

  bool _applyStatus(
    bool coreAvailable,
    bool storeAvailable,
    String storeHealth,
    int seq,
    int tsMs,
  ) {
    final last = _lastStatusSeq;
    if (last != null && seq <= last) return false;
    _lastStatusSeq = seq;
    _snapshot = PresenceEventSnapshot(
      presenceBySubject: _snapshot.presenceBySubject,
      coreHealth: CoreHealthEntry(
        coreAvailable: coreAvailable,
        storeAvailable: storeAvailable,
        storeHealth: storeHealth,
        seq: seq,
        tsMs: tsMs,
      ),
    );
    notifyListeners();
    return true;
  }

  /// Drops all received state. Used when the client goes offline so stale
  /// presence/health is never shown as current.
  void clear() {
    if (_snapshot.isEmpty) return;
    _snapshot = const PresenceEventSnapshot();
    _lastPresenceSeq.clear();
    _lastStatusSeq = null;
    notifyListeners();
  }
}

/// Binds [PresenceEventState] to a [DaemonClient]'s event lane. Topics are
/// subscribed globally by the client itself (best-effort, per socket); this
/// binding only registers typed hooks and stores the payloads they deliver.
class PresenceEventStateBinding {
  PresenceEventStateBinding({
    required DaemonClient client,
    required this._state,
  }) {
    _unsubscribePresence = client.onPresenceChanged(_state.applyPayload);
    _unsubscribeStatus = client.onStatusChanged(_state.applyPayload);
  }

  final PresenceEventState _state;
  void Function()? _unsubscribePresence;
  void Function()? _unsubscribeStatus;

  bool get isBound => _unsubscribePresence != null && _unsubscribeStatus != null;

  void dispose() {
    _unsubscribePresence?.call();
    _unsubscribeStatus?.call();
    _unsubscribePresence = null;
    _unsubscribeStatus = null;
  }
}
