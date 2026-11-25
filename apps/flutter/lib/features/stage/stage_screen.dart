// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../../ui/model_stage.dart';

/// Stage destination: one card's display-model surface, nothing else.
///
/// The shell picks the card; this screen only forwards the id to [ModelStage],
/// which owns the `cards.get` read and the loud failure when the card names an
/// asset this client cannot resolve.
class StageScreen extends StatelessWidget {
  const StageScreen({super.key, required this.client, this.cardId});

  final DaemonClient client;

  /// Card to display; null renders the no-model placeholder.
  final String? cardId;

  @override
  Widget build(BuildContext context) {
    return ModelStage(client: client, cardId: cardId);
  }
}