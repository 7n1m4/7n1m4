// SPDX-License-Identifier: GPL-3.0-or-later

/// Immutable, already-typed description of a gateway peer as shown in the UI.
/// No I/O and no wire decoding: callers build these from their own state.
class PeerInfo {
  const PeerInfo({
    required this.id,
    required this.displayName,
    required this.isConnected,
    required this.isTrusted,
  });

  final String id;
  final String displayName;
  final bool isConnected;
  final bool isTrusted;
}

/// Peers whose transport is currently connected.
List<PeerInfo> connectedPeers(Iterable<PeerInfo> peers) =>
    peers.where((p) => p.isConnected).toList(growable: false);

/// Peers the user has explicitly trusted / paired.
List<PeerInfo> trustedPeers(Iterable<PeerInfo> peers) =>
    peers.where((p) => p.isTrusted).toList(growable: false);

/// Peers that are both connected and trusted: safe to interact with.
List<PeerInfo> eligiblePeers(Iterable<PeerInfo> peers) =>
    peers.where((p) => p.isConnected && p.isTrusted).toList(growable: false);

/// Deterministic display order: case-insensitive name, then id to break ties.
/// The extra id key makes the result independent of input order.
List<PeerInfo> orderedPeers(Iterable<PeerInfo> peers) {
  final sorted = peers.toList();
  sorted.sort((a, b) {
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    if (byName != 0) return byName;
    return a.id.compareTo(b.id);
  });
  return List<PeerInfo>.unmodifiable(sorted);
}
