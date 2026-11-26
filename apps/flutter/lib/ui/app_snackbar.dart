// SPDX-License-Identifier: GPL-3.0-or-later

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';

/// Shows a [SnackBar] with [message] in the nearest [ScaffoldMessenger].
///
/// Any snackbar already on screen is hidden first so repeated calls replace
/// the current one instead of queueing behind it. No state is kept between
/// calls.
void showAppSnackbar(BuildContext context, String message) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}
