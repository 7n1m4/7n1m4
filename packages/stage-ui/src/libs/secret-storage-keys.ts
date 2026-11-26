// SPDX-License-Identifier: GPL-3.0-or-later
// Public path compatibility: the policy itself lives with the daemon-backed
// composable (`vault.secret_key_policy`), not in a hand-maintained key list.
export { isSecretStorageKey } from '../composables/daemon-secret-policy'
