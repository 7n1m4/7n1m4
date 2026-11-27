// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
//
// Pure, in-memory de-duplication over opaque MessageKey identities. Nothing is
// persisted and no wire envelope is built or parsed.

import 'message_key.dart';

/// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
///
/// Records each distinct opaque message id once, preserving first-seen order.
class MessageDedupeIndex {
  final Set<MessageKey> _seen = <MessageKey>{};
  final List<MessageKey> _order = <MessageKey>[];

  /// Distinct first-seen keys in insertion order.
  List<MessageKey> get keys => List<MessageKey>.unmodifiable(_order);

  /// Number of distinct first-seen keys.
  int get length => _order.length;

  /// Inserts [key]; returns true only on first sight.
  bool insert(MessageKey key) {
    if (!_seen.add(key)) return false;
    _order.add(key);
    return true;
  }

  /// Validates a raw id into a key (failing closed), then inserts it.
  bool insertId(String? rawId) => insert(MessageKey(rawId));

  /// Whether [key] has been seen.
  bool contains(MessageKey key) => _seen.contains(key);

  /// Validates a raw id into a key (failing closed), then looks it up.
  bool containsId(String? rawId) => contains(MessageKey(rawId));
}
