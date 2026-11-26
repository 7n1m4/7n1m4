// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure Dart mirror of the provider-instance helper half of
/// `packages/stage-ui/src/stores/providers/runtime/instance-store.ts`
/// (constants, `cleanInfix`/`normalizeInstance`, `toStorageKey`, and the
/// row selectors). Mirrors the already-shipped Rust half in
/// `crates/anima-core/src/providers.rs`: no storage writes, no
/// `providerCredentials` proxy, no HMAC mint, no network, no UI.
///
/// Rows are plain maps keyed by `<providerId>:<instanceId>` with fields
/// `instanceId`, `id`, `providerId`, `label`, `options` and `isPrimary`.
/// Callers own the row map; `options` holds raw credentials and stays opaque —
/// never log it or echo it into an error message.
library;

/// LocalStorage key of the v2 snapshot this helper shape comes from. Kept for
/// parity with the TS constant; this library never reads or writes storage.
const String providerInstancesStorageKey = 'settings/credentials/providers';

/// Infix of the single primary instance every provider has (`<providerId>:*`).
const String primaryInstanceInfix = '*';

/// Normalize an instance id that may already carry one or more redundant
/// `<providerId>:` prefixes. Missing, empty and primary ids resolve to
/// [primaryInstanceInfix]; repeated prefixes are peeled one at a time.
String cleanInfix(String providerId, String? instanceId) {
  if (instanceId == null || instanceId.isEmpty || instanceId == primaryInstanceInfix) {
    return primaryInstanceInfix;
  }
  var clean = instanceId;
  final prefix = '$providerId:';
  while (clean.startsWith(prefix)) {
    clean = clean.substring(prefix.length);
  }
  return clean.isEmpty ? primaryInstanceInfix : clean;
}

/// Build the v2 storage key for a provider instance, with [cleanInfix]
/// normalization so a dirty id cannot nest the provider id.
String toStorageKey(String providerId, [String? instanceId]) =>
    '$providerId:${cleanInfix(providerId, instanceId)}';

/// Expand a partial row into a canonical row for [providerId]. The infix is
/// cleaned before it is used in `id`/`instanceId`; absent labels default to
/// `Default` and absent options to an empty map.
Map<String, dynamic> normalizeInstance(
  Map<String, dynamic> instance,
  String providerId,
  String infix,
) {
  final resolvedInfix = cleanInfix(providerId, infix);
  return <String, dynamic>{
    'instanceId': '$providerId:$resolvedInfix',
    'id': resolvedInfix,
    'providerId': providerId,
    'label': instance['label'] as String? ?? 'Default',
    'options': _optionsOf(instance),
    'isPrimary': instance['isPrimary'] == true,
  };
}

Map<String, dynamic> _optionsOf(Map<String, dynamic> row) {
  final options = row['options'];
  if (options is Map) {
    return Map<String, dynamic>.from(options);
  }
  return <String, dynamic>{};
}

/// Repair legacy double-prefixed keys and row ids in place, the pure
/// equivalent of TS `healDirtySnapshot`. Rows already in canonical shape are
/// left untouched.
void healInstanceRows(Map<String, Map<String, dynamic>> rows) {
  final healed = <String, Map<String, dynamic>>{};
  var touched = false;
  for (final entry in rows.entries) {
    final key = entry.key;
    final row = entry.value;
    final providerId = (row['providerId'] as String?) ?? key.split(':').first;
    final cleanId = cleanInfix(providerId, row['id'] as String?);
    final cleanKey = toStorageKey(providerId, cleanId);

    if (cleanKey != key ||
        row['id'] != cleanId ||
        row['instanceId'] != cleanKey) {
      touched = true;
      healed[cleanKey] = normalizeInstance(row, providerId, cleanId);
    } else {
      healed[key] = row;
    }
  }
  if (touched) {
    rows
      ..clear()
      ..addAll(healed);
  }
}

/// Option lookup through the normalized key, so callers can resolve a row with
/// either its clean id or a redundant provider-prefixed id. Returns an empty
/// map when no row exists — unlike the TS store, this helper never materializes
/// or persists a default row. Mirroring TS `snapshot()`, the lookup may repair
/// dirty storage keys/ids in place in [rows]; it only reads option values and
/// never writes storage.
Map<String, dynamic> providerInstanceOptions(
  Map<String, Map<String, dynamic>> rows,
  String providerId, [
  String? instanceId,
]) {
  healInstanceRows(rows);
  final row = rows[toStorageKey(providerId, instanceId)];
  return row == null ? <String, dynamic>{} : _optionsOf(row);
}

/// Rows for [providerId], primary first then sorted by label, mirroring TS
/// `listInstances`. Labels compare case-insensitively (TS `localeCompare`).
List<Map<String, dynamic>> listInstances(
  Map<String, Map<String, dynamic>> rows,
  String providerId,
) {
  healInstanceRows(rows);
  final prefix = '$providerId:';
  final instances = rows.entries
      .where((entry) => entry.key.startsWith(prefix))
      .map((entry) => entry.value)
      .toList();
  instances.sort((a, b) {
    final aPrimary = a['isPrimary'] == true;
    final bPrimary = b['isPrimary'] == true;
    if (aPrimary != bPrimary) {
      return aPrimary ? -1 : 1;
    }
    final aLabel = (a['label'] as String?) ?? '';
    final bLabel = (b['label'] as String?) ?? '';
    return aLabel.toLowerCase().compareTo(bLabel.toLowerCase());
  });
  return instances;
}

/// Mark the addressed row primary and demote every other row of [providerId].
void setPrimaryInstance(
  Map<String, Map<String, dynamic>> rows,
  String providerId,
  String instanceId,
) {
  healInstanceRows(rows);
  final primaryKey = toStorageKey(providerId, instanceId);
  final prefix = '$providerId:';
  for (final entry in rows.entries) {
    if (entry.key.startsWith(prefix)) {
      entry.value['isPrimary'] = entry.key == primaryKey;
    }
  }
}

/// Rename the addressed row, materializing a default row when it is missing.
void setInstanceLabel(
  Map<String, Map<String, dynamic>> rows,
  String providerId,
  String instanceId,
  String label,
) {
  healInstanceRows(rows);
  final key = toStorageKey(providerId, instanceId);
  final row = rows[key];
  if (row == null) {
    rows[key] = normalizeInstance(<String, dynamic>{
      'providerId': providerId,
      'id': instanceId,
      'label': label,
      'isPrimary': cleanInfix(providerId, instanceId) == primaryInstanceInfix,
    }, providerId, instanceId);
    return;
  }
  row['label'] = label;
}

/// Delete the addressed row. Removing the primary promotes another primary
/// row when one exists, otherwise the first remaining row, mirroring TS
/// `removeInstance`.
void removeInstance(
  Map<String, Map<String, dynamic>> rows,
  String providerId, [
  String? instanceId,
]) {
  healInstanceRows(rows);
  rows.remove(toStorageKey(providerId, instanceId));
  if (instanceId == null || instanceId == primaryInstanceInfix) {
    return;
  }

  final remaining = listInstances(rows, providerId);
  if (remaining.any((row) => row['id'] == primaryInstanceInfix)) {
    return;
  }
  final fallback = remaining.firstWhere(
    (row) => row['isPrimary'] == true,
    orElse: () => remaining.isEmpty ? <String, dynamic>{} : remaining.first,
  );
  if (fallback.isEmpty) {
    return;
  }
  rows[toStorageKey(providerId, primaryInstanceInfix)] = normalizeInstance(
    <String, dynamic>{
      ...fallback,
      'id': primaryInstanceInfix,
      'isPrimary': true,
    },
    providerId,
    primaryInstanceInfix,
  );
}

/// Delete every row owned by [providerId], leaving other providers intact.
void removeAllInstances(
  Map<String, Map<String, dynamic>> rows,
  String providerId,
) {
  healInstanceRows(rows);
  final prefix = '$providerId:';
  rows.removeWhere((key, _) => key.startsWith(prefix));
}

/// Return the primary row, materializing it when missing and seeding [template]
/// only when its options are empty.
Map<String, dynamic> ensurePrimaryInstance(
  Map<String, Map<String, dynamic>> rows,
  String providerId, [
  Map<String, dynamic> template = const <String, dynamic>{},
]) {
  healInstanceRows(rows);
  final key = toStorageKey(providerId, primaryInstanceInfix);
  final row = rows.putIfAbsent(
    key,
    () => normalizeInstance(<String, dynamic>{
      'providerId': providerId,
      'id': primaryInstanceInfix,
      'isPrimary': true,
    }, providerId, primaryInstanceInfix),
  );
  if (_optionsOf(row).isEmpty && template.isNotEmpty) {
    row['options'] = Map<String, dynamic>.from(template);
  }
  return row;
}

/// Create a named row from a label turned into a lowercase slug. Returns an
/// existing row with the same slug instead of duplicating it.
Map<String, dynamic> addInstance(
  Map<String, Map<String, dynamic>> rows,
  String providerId,
  String label, [
  Map<String, dynamic> template = const <String, dynamic>{},
]) {
  healInstanceRows(rows);
  final trimmed = label.trim();
  final normalizedLabel = trimmed.isEmpty
      ? 'Instance ${listInstances(rows, providerId).length + 1}'
      : trimmed;
  final slug = normalizedLabel.toLowerCase().replaceAll(RegExp(r'\W+'), '-');
  final key = toStorageKey(providerId, slug);
  final existing = rows[key];
  if (existing != null) {
    return existing;
  }
  final row = normalizeInstance(<String, dynamic>{
    'providerId': providerId,
    'id': slug,
    'label': normalizedLabel,
    'options': Map<String, dynamic>.from(template),
    'isPrimary': false,
  }, providerId, slug);
  rows[key] = row;
  return row;
}
