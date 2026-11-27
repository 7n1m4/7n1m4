// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/peers/peer_predicates.dart';

const _alice = PeerInfo(
  id: 'a',
  displayName: 'Alice',
  isConnected: true,
  isTrusted: true,
);
const _bob = PeerInfo(
  id: 'b',
  displayName: 'bob',
  isConnected: true,
  isTrusted: false,
);
const _carol = PeerInfo(
  id: 'c',
  displayName: 'Carol',
  isConnected: false,
  isTrusted: true,
);
const _dave = PeerInfo(
  id: 'd',
  displayName: 'Dave',
  isConnected: false,
  isTrusted: false,
);
const _alice2 = PeerInfo(
  id: 'e',
  displayName: 'Alice',
  isConnected: true,
  isTrusted: true,
);

const List<PeerInfo> _all = [_alice, _bob, _carol, _dave, _alice2];

List<String> ids(List<PeerInfo> peers) => peers.map((p) => p.id).toList();

void main() {
  test('connectedPeers keeps only online peers', () {
    expect(ids(connectedPeers(_all)), ['a', 'b', 'e']);
  });

  test('trustedPeers keeps only paired peers', () {
    expect(ids(trustedPeers(_all)), ['a', 'c', 'e']);
  });

  test('eligiblePeers keeps connected and trusted peers', () {
    expect(ids(eligiblePeers(_all)), ['a', 'e']);
  });

  test('orderedPeers sorts case-insensitively then by id, independent of input order', () {
    expect(ids(orderedPeers(_all)), ['a', 'e', 'b', 'c', 'd']);
    expect(ids(orderedPeers(_all.reversed)), ['a', 'e', 'b', 'c', 'd']);
  });
}
