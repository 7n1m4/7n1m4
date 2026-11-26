// SPDX-License-Identifier: GPL-3.0-or-later

// Stage readout of the daemon-published presence/status lane. The widget owns
// a [PresenceEventStateBinding] and renders only payloads the daemon actually
// sent: no frame means no presence or health text, never "offline"/"unhealthy".
// Stale values are dropped when the client leaves the connected state.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import 'presence_event_state.dart';

/// Small stage chip showing every presence the daemon has published and the
/// latest core health. Absent payloads render as no value at all.
class PresenceStatusChip extends StatefulWidget {
  const PresenceStatusChip({
    super.key,
    required this.client,
    this.label = 'Presence',
  });

  final DaemonClient client;

  /// Static heading for the chip; never a presence or health claim.
  final String label;

  @override
  State<PresenceStatusChip> createState() => _PresenceStatusChipState();
}

class _PresenceStatusChipState extends State<PresenceStatusChip> {
  late PresenceEventState _state;
  late PresenceEventStateBinding _binding;
  StreamSubscription<DaemonStatus>? _statusSubscription;

  @override
  void initState() {
    super.initState();
    _state = PresenceEventState();
    _state.addListener(_onPresenceChanged);
    _binding = PresenceEventStateBinding(client: widget.client, state: _state);
    _statusSubscription = widget.client.statusStream.listen(_onDaemonStatus);
  }

  @override
  void didUpdateWidget(PresenceStatusChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client == widget.client) return;
    _statusSubscription?.cancel();
    _binding.dispose();
    _state.clear();
    _binding = PresenceEventStateBinding(client: widget.client, state: _state);
    _statusSubscription = widget.client.statusStream.listen(_onDaemonStatus);
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _binding.dispose();
    _state.removeListener(_onPresenceChanged);
    _state.dispose();
    super.dispose();
  }

  void _onPresenceChanged() {
    if (mounted) setState(() {});
  }

  void _onDaemonStatus(DaemonStatus status) {
    // A dropped socket invalidates the snapshot: the daemon will republish
    // presence and health on the next authenticated connection.
    if (!status.isConnected) _state.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelSmall;
    final snapshot = _state.snapshot;
    final subjects = snapshot.presenceBySubject.values.toList()
      ..sort((a, b) => a.subject.compareTo(b.subject));
    final health = snapshot.coreHealth;
    final healthy = health != null && health.coreAvailable && health.storeAvailable;

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        children: <Widget>[
          Icon(
            Icons.circle,
            size: 10,
            color: health == null
                ? scheme.onSurface.withValues(alpha: 0.4)
                : healthy
                    ? Colors.greenAccent
                    : Colors.redAccent,
          ),
          Text(widget.label, style: textStyle),
          for (final entry in subjects)
            Text('${entry.subject}: ${entry.state}', style: textStyle),
          if (health != null)
            Text(
              'Core: ${health.coreAvailable}, store: ${health.storeAvailable}, '
              'health: ${health.storeHealth}',
              style: textStyle,
            ),
        ],
      ),
    );
  }
}
