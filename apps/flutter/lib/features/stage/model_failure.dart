// SPDX-License-Identifier: GPL-3.0-or-later

// Common shape for every loud, typed stage failure. Lets the surface render a
// user-safe message without inspecting transport or platform internals.

/// A stage failure with a stable code and a user-safe message.
abstract interface class ModelFailure {
  const ModelFailure(this.code, this.message);

  final String code;
  final String message;
}
