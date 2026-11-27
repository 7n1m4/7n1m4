// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.

import 'dart:async';

import 'package:anima_control/daemon_client/protocol.dart';

/// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
///
/// Narrow seam over an existing decoded event stream. No wire envelope is
/// built, parsed or minted here.
abstract class ChatTransportAdapter {
  /// Already-decoded event frames. This seam never builds or parses a wire envelope.
  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  Stream<GatewayEventFrame> get events;

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  Future<void> close();
}
