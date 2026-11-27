// SPDX-License-Identifier: GPL-3.0-or-later

import 'settings_search_results.dart';

/// Pure, case-insensitive substring filter over typed settings result items.
///
/// No I/O, no clock and no dependency on the existing SettingsSearchIndex. Invalid ids
/// (empty, whitespace-only or composite) and duplicate ids fail closed so the
/// ascending-id tie-break stays deterministic. A blank query preserves the
/// exact input order of the surviving items.
List<SettingsResultItem> filterSettingsResults(
  Iterable<SettingsResultItem> items,
  String rawQuery,
) {
  final query = rawQuery.trim().toLowerCase();

  final seenIds = <String>{};
  final valid = <SettingsResultItem>[];
  for (final item in items) {
    if (!SettingsResultItem.isValidId(item.id)) continue;
    if (!seenIds.add(item.id)) continue;
    valid.add(item);
  }

  if (query.isEmpty) return List<SettingsResultItem>.unmodifiable(valid);

  final matched = valid
      .where(
        (item) => item.searchableText.any(
          (field) => field.toLowerCase().contains(query),
        ),
      )
      .toList();
  // Dart's List.sort is not stable; a unique, ascending id is the full key.
  matched.sort((a, b) => a.id.compareTo(b.id));
  return List<SettingsResultItem>.unmodifiable(matched);
}
