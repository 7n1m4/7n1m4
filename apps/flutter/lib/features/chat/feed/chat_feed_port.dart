// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'chat_feed_event.dart';

/// UI-owned seam over an already-decoded chat feed event stream.
///
/// This port is deliberately narrow: it only exposes [events] as
/// [ChatFeedEvent] values that a producer has decoded before hand-off. It
/// never builds, parses or mints a wire envelope, and it has no dependency on
/// the quarantined transport seam or its wire frame types.
abstract class ChatFeedPort {
  /// Already-decoded feed events, in the order the producer hands them over.
  Stream<ChatFeedEvent> get events;

  /// Releases the producer's subscription to the feed.
  Future<void> close();
}
