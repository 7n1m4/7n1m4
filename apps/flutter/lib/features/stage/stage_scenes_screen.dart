// SPDX-License-Identifier: GPL-3.0-or-later

// Minimal scene manager: add a tint or a local image, activate one backdrop,
// remove entries. Every mutation goes through [StageSceneStore], which is the
// only writer of this client-local library. No daemon state is touched.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'model_failure.dart';
import 'stage_scene_manager.dart';

/// Returns a chosen image path, or null when the user cancels. Injected so
/// widget tests never open a platform file dialog.
typedef StageImagePicker = Future<String?> Function();

class StageScenesScreen extends StatefulWidget {
  const StageScenesScreen({
    super.key,
    required this.store,
    this.cardId,
    this.imagePicker = _pickImage,
    this.imagePickerAvailable,
    this.onChanged,
  });

  final StageSceneStore store;

  /// Card whose scene is being edited; null edits the library-wide default.
  /// One card's choice never overwrites another's.
  final String? cardId;
  final StageImagePicker imagePicker;

  /// Whether the host registers a native file picker plugin. Linux and
  /// Windows builds do not; tint scenes remain available there.
  final bool? imagePickerAvailable;

  bool get _canPickImage =>
      imagePickerAvailable ??
      const <TargetPlatform>{TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS}
          .contains(defaultTargetPlatform);

  /// Notified after every successful library mutation so a hosting stage can
  /// re-read the active background.
  final VoidCallback? onChanged;

  static Future<String?> _pickImage() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return null;
    return files.first.path;
  }

  @override
  State<StageScenesScreen> createState() => _StageScenesScreenState();
}

class _StageScenesScreenState extends State<StageScenesScreen> {
  bool _loaded = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.store.load();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = error is StageSceneException
            ? error.message
            : 'The scene library could not be loaded.';
      });
    }
  }

  Future<void> _mutate(Future<Object?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      widget.onChanged?.call();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is ModelFailure || error is StageSceneException
            ? '$error'
            : 'The scene could not be updated.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scenes')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_mutate(
                                  () => widget.store.add(tint: '#171717'),
                                )),
                        icon: const Icon(Icons.palette_outlined),
                        label: const Text('Add tint'),
                      ),
                      const SizedBox(width: 8),
                      if (widget._canPickImage)
                        FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () => unawaited(_mutate(() async {
                                    final path = await widget.imagePicker();
                                    if (path == null || path.isEmpty) {
                                      return null;
                                    }
                                    return widget.store.add(imagePath: path);
                                  })),
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Add image'),
                        ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _busy ||
                                (widget.cardId == null
                                    ? widget.store.activeId == null
                                    : widget.store
                                            .activeForCard(widget.cardId!) ==
                                        null)
                            ? null
                            : () => unawaited(
                                  _mutate(
                                    () => widget.store.deactivate(
                                      cardId: widget.cardId,
                                    ),
                                  ),
                                ),
                        child: const Text('Clear active'),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: widget.store.entries.isEmpty
                        ? const Center(child: Text('No scenes yet'))
                        : ListView.builder(
                            itemCount: widget.store.entries.length,
                            itemBuilder: (context, index) {
                              final entry = widget.store.entries[index];
                              final active = (widget.cardId == null
                                      ? widget.store.activeId
                                      : widget.store
                                          .activeForCard(widget.cardId!)) ==
                                  entry.id;
                              return ListTile(
                                key: ValueKey<String>(entry.id),
                                leading: Icon(
                                  active
                                      ? Icons.check_circle
                                      : Icons.image_outlined,
                                ),
                                title: Text(entry.label),
                                subtitle: Text(
                                  '${entry.kind.name}${entry.imagePath == null ? '' : ' · ${entry.imagePath}'}',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    if (!active)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => unawaited(_mutate(
                                                  () => widget.store
                                                      .activate(entry.id, cardId: widget.cardId),
                                                )),
                                        child: const Text('Activate'),
                                      ),
                                    IconButton(
                                      tooltip: 'Remove scene',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_mutate(
                                                () => widget.store
                                                    .remove(entry.id),
                                              )),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
