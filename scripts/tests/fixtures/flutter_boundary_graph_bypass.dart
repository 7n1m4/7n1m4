// Canonical export-laundered bypass fixture for the boundary graph guard.
//
// This file is valid Dart on its own. The three virtual files below are stored
// as comment-wrapped sections: `flutter_boundary_graph.mjs --self-test` splits
// on the VIRTUAL_FILE markers, strips one leading `// ` from each content line,
// materializes the files in a temporary directory, and removes it in `finally`.
//
// The chain has no forbidden package prefix and no dart:io write/network token,
// so the round-14 per-file regex guard cannot see it: state re-exports dart:io
// from data, and ui imports state through a single import hop.
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/ui/chat_screen.dart ===
// import 'package:flutter/widgets.dart';
// import '../state/chat_barrel.dart';
//
// class ChatScreen extends StatelessWidget {
//   const ChatScreen({super.key});
//
//   @override
//   Widget build(BuildContext context) => const SizedBox.shrink();
// }

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/state/chat_barrel.dart ===
// export '../data/storage_barrel.dart';
//
// class ChatState {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/data/storage_barrel.dart ===
// export 'dart:io';
//
// class StorageBarrel {}
