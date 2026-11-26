// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

/// A file selected for import. This small value object decouples the native
/// file picker from tests, which can provide bytes directly.
class CardFileSelection {
  const CardFileSelection({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, required this.client, this.pickCardFile});
  final DaemonClient client;
  final Future<CardFileSelection?> Function()? pickCardFile;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  final TextEditingController _importController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _documentController = TextEditingController();

  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  int? _cardCursor;
  bool _cardsTruncated = false;
  bool _loadingMore = false;
  int _loadGeneration = 0;
  Map<String, dynamic>? _detail;
  ({String id, bool liked, bool bookmarked})? _metadata;
  bool _metadataBusy = false;
  bool _busy = false;
  String? _error;
  String? _status;

  void _setBusy(bool busy) {
    setState(() => _busy = busy);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _importController.dispose();
    _nameController.dispose();
    _documentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    _setBusy(true);
    setState(() => _error = null);
    try {
      final page = await widget.client.cardsListPage();
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _cards = page.items.toList();
          _cardsTruncated = page.truncated;
          _cardCursor = page.nextCursor;
          _loadingMore = false;
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _loadMore() async {
    final cursor = _cardCursor;
    final generation = _loadGeneration;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.cardsListPage(cursor: cursor);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _cardsTruncated = page.truncated;
        _cardCursor = page.nextCursor;
        _cards.addAll(page.items);
      });
    } on DaemonClientException catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _open(String id, {bool clearStatus = true}) async {
    _setBusy(true);
    setState(() {
      _error = null;
      if (clearStatus) _status = null;
    });
    try {
      final card = await widget.client.cardsGet(id);
      final metadata = await widget.client.cardsMetadata(id);
      if (mounted) {
        setState(() {
          _detail = card;
          _metadata = metadata;
          _nameController.text = card?['name'] is String
              ? card!['name'] as String
              : '';
          _documentController.text = card == null ? '' : jsonEncode(card);
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMetadata({
    required bool liked,
    required bool bookmarked,
  }) async {
    final current = _metadata;
    if (current == null || current.id.isEmpty) return;
    setState(() {
      _metadataBusy = true;
      _error = null;
    });
    try {
      final metadata = await widget.client.cardsMetadataSet(
        current.id,
        liked: liked,
        bookmarked: bookmarked,
      );
      if (mounted) setState(() => _metadata = metadata);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _metadataBusy = false);
    }
  }

  /// Parses the import field as a card document. A bare JSON object is the
  /// card; a `{"card": …, "pngBase64": …}` envelope is accepted too, matching
  /// what the daemon's `cards.import` takes.
  ({Map<String, dynamic>? card, String? pngBase64})? _parseImport() {
    final raw = _importController.text.trim();
    if (raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    return _decodeImportObject(decoded);
  }

  /// Shared handling for a decoded import object, whether it came from the
  /// text field or a `.json` file.
  ({Map<String, dynamic>? card, String? pngBase64}) _decodeImportObject(
    Map<String, dynamic> decoded,
  ) {
    final png = decoded['pngBase64'];
    if (png is String) return (card: null, pngBase64: png);
    final nested = decoded['card'];
    final card = nested is Map<String, dynamic> ? nested : decoded;
    return (card: card, pngBase64: null);
  }

  Future<CardFileSelection?> _pickCardFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Import a card (.png or .json)',
      type: FileType.custom,
      allowedExtensions: const <String>['json', 'png'],
    );
    if (file == null) return null;
    return CardFileSelection(name: file.name, bytes: await file.readAsBytes());
  }

  Future<void> _importFile() async {
    final CardFileSelection? selection;
    try {
      selection = await (widget.pickCardFile ?? _pickCardFile).call();
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not read the card file: $e');
      return;
    }
    if (selection == null || !mounted) return;
    final ({Map<String, dynamic>? card, String? pngBase64}) parsed;
    if (selection.name.toLowerCase().endsWith('.png')) {
      parsed = (
        card: null,
        pngBase64: base64Encode(selection.bytes),
      );
    } else {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(selection.bytes));
      } on FormatException {
        if (mounted) {
          setState(() => _error = 'The selected file is not valid JSON.');
        }
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        if (mounted) {
          setState(
            () => _error = 'The selected file must contain a JSON object.',
          );
        }
        return;
      }
      parsed = _decodeImportObject(decoded);
    }
    await _runImport(parsed);
  }

  Future<void> _import() async {
    final parsed = _parseImport();
    if (parsed == null) {
      setState(() => _error = 'Paste a JSON card object to import.');
      return;
    }
    await _runImport(parsed);
  }

  Future<void> _runImport(
    ({Map<String, dynamic>? card, String? pngBase64}) parsed,
  ) async {
    _setBusy(true);
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final result = await widget.client.cardsImport(
        card: parsed.card,
        pngBase64: parsed.pngBase64,
      );
      if (!mounted) return;
      setState(() {
        _status = result.renamed
            ? 'Imported "${result.name}" as ${result.id} (renamed)'
            : 'Imported "${result.name}" as ${result.id}';
        _importController.clear();
      });
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Decodes a JSON object from [raw], setting an error and returning null when
  /// it is missing, malformed, or not an object.
  Map<String, dynamic>? _decodeDocument(String raw) {
    if (raw.isEmpty) {
      setState(() => _error = 'A JSON document is required.');
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      setState(() => _error = 'The document is not valid JSON.');
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      setState(() => _error = 'The document must be a JSON object.');
      return null;
    }
    return decoded;
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final raw = _documentController.text.trim();
    if (name.isEmpty || raw.isEmpty) {
      setState(() => _error = 'A name and a JSON document are required.');
      return;
    }
    final Map<String, dynamic>? decoded = _decodeDocument(raw);
    if (decoded == null) return;
    _setBusy(true);
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final result = await widget.client.cardsCreate(<String, dynamic>{
        ...decoded,
        'name': name,
      });
      if (!mounted) return;
      setState(() {
        _status = 'Created "${result.name}" as ${result.id}';
        _nameController.clear();
        _documentController.clear();
      });
      await _load();
      await _open(result.id, clearStatus: false);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveDetail() async {
    final current = _detail;
    if (current == null) return;
    final id = current['id'];
    if (id is! String || id.isEmpty) return;
    final Map<String, dynamic>? document = _decodeDocument(
      _documentController.text,
    );
    if (document == null) return;
    final typedName = _nameController.text.trim();
    final name = typedName;
    if (name.isEmpty) {
      setState(() => _error = 'A name is required.');
      return;
    }
    _setBusy(true);
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final result = await widget.client.cardsUpdate(id, <String, dynamic>{
        ...document,
        'name': name,
      });
      if (!mounted) return;
      setState(() => _status = 'Saved "${result.name}" (${result.id})');
      await _load();
      await _open(id, clearStatus: false);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text('Delete "$name" ($id)? This cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _setBusy(true);
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final deleted = await widget.client.cardsDelete(id);
      if (!mounted) return;
      setState(() {
        _status = deleted ? 'Deleted "$name"' : '"$name" was already gone';
        if (deleted) {
          _detail = null;
          _metadata = null;
        }
      });
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One list row. The id and name are resolved once so the row's callbacks
  /// cannot disagree about which card they act on.
  Widget _cardRow(Map<String, dynamic> card) {
    final id = (card['id'] as String?) ?? '';
    final name = (card['name'] as String?) ?? id;
    return ListTile(
      title: Text(name),
      subtitle: Text(id),
      onTap: () => _open(id),
      trailing: IconButton(
        icon: const Icon(Icons.delete),
        tooltip: 'Delete card',
        onPressed: _busy ? null : () => _delete(id, name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      // The refresh spinner is an inline body state, never a route: a pushed
      // modal route would hide the list from the widget tree (and from tests)
      // for the whole request.
      appBar: AppBar(
        title: const Text('Cards'),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_status != null) Text(_status!),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Import a card',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _importController,
                          decoration: const InputDecoration(
                            labelText: 'Card JSON (object or envelope)',
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _importFile,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Import file'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: _busy ? null : _import,
                              child: const Text('Import'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'New card',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(labelText: 'Name'),
                        ),
                        TextField(
                          controller: _documentController,
                          decoration: const InputDecoration(
                            labelText: 'Card JSON document',
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _busy ? null : _create,
                            child: const Text('Create'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const ListTile(title: Text('Cards'), dense: true),
                if (_cardsTruncated)
                  TextButton(
                    key: const Key('cards-load-more'),
                    onPressed: _busy || _loadingMore ? null : _loadMore,
                    child: Text(
                      _loadingMore ? 'Loading more…' : 'Load more cards',
                    ),
                  ),
                if (_cards.isEmpty)
                  const ListTile(title: Text('No cards available'), dense: true)
                else
                  for (final c in _cards)
                    _cardRow(c),
                if (detail != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(jsonEncode(detail)),
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                          ),
                          TextField(
                            controller: _documentController,
                            decoration: const InputDecoration(
                              labelText: 'Card JSON document',
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton(
                              onPressed: _busy ? null : _saveDetail,
                              child: const Text('Save'),
                            ),
                          ),
                          if (_metadata != null) ...<Widget>[
                            CheckboxListTile(
                              title: const Text('Liked'),
                              value: _metadata!.liked,
                              enabled: !_metadataBusy,
                              onChanged: (value) => _setMetadata(
                                liked: value ?? false,
                                bookmarked: _metadata!.bookmarked,
                              ),
                            ),
                            CheckboxListTile(
                              title: const Text('Bookmarked'),
                              value: _metadata!.bookmarked,
                              enabled: !_metadataBusy,
                              onChanged: (value) => _setMetadata(
                                liked: _metadata!.liked,
                                bookmarked: value ?? false,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
