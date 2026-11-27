// SPDX-License-Identifier: GPL-3.0-or-later

/// Immutable result item consumed by the pure settings filter.
///
/// [id] is an opaque lookup key, never a search term: matching sees only the
/// human-readable [title], [category] and [description] fields.
class SettingsResultItem {
  const SettingsResultItem({
    required this.id,
    required this.title,
    required this.category,
    this.description,
  });

  final String id;
  final String title;
  final String category;
  final String? description;

  /// Fields a query may match. [id] is deliberately absent.
  Iterable<String> get searchableText => <String>[
    title,
    category,
    if (description != null && description!.isNotEmpty) description!,
  ];

  /// An id can break ranking ties only if it is one opaque token: no
  /// whitespace, path separators, key/value glue or trailing line terminator.
  static bool isValidId(String id) =>
      id.isNotEmpty && id.trim() == id && _opaqueId.hasMatch(id);

  static final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9_-]+$');

  @override
  bool operator ==(Object other) =>
      other is SettingsResultItem &&
      other.id == id &&
      other.title == title &&
      other.category == category &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, title, category, description);
}
