// Canonical dead-exports + region-lock fixture for scripts/tests/no-dead-exports.mjs.
//
// This file is valid Dart on its own. The virtual files below are stored as
// comment-wrapped sections: the guard's node:test suite splits on the
// VIRTUAL_FILE markers, strips one leading `// ` from each content line,
// materializes them in a temporary root, and removes it in `t.after`.
//
// Cases covered:
//  (a) dead_archetype.dart - barrel-exported and test-imported only
//  (b) live_archetype.dart - reached by a direct production importer
//  (c) chat_screen.dart - every symbol anchor present (passing region)
//      missing/ variant - one symbol anchor absent (failing region)
//  (d) forbidden/ variant - a forbidden anchor present (failing region)
//  (e) conditional_barrel.dart / conditional_screen.dart - extra URI literals
//  (f) unsafe virtual paths are rejected by validateVirtualPath in the suite
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/main.dart ===
// // Grandfathered entrypoint: launched by the runtime, never imported.
// import 'features/chat/chat_screen.dart';
// import 'features/chat/live_screen.dart';
// import 'features/chat/conditional_screen.dart';
//
// void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/chat_screen.dart ===
// import 'chat_message_display.dart';
//
// class ChatScreen {
//   Widget build(int messageIndex) {
//     final displayed = m.isUser ? m.text : stripMarkers(m.text);
//     const sessionsKey = Key('chat-sessions-button');
//     return ListView.builder(
//       itemBuilder: (_, int messageIndex) => Key('chat-copy-$messageIndex'),
//       itemCount: 1,
//     );
//   }
//
//   Widget body(String data) => MarkdownBody(
//         data: data,
//       );
// }

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/chat_message_display.dart ===
// export 'dead_archetype.dart';
//
// String stripMarkers(String text) => text;

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/dead_barrel.dart ===
// export 'dead_archetype.dart';
//
// class DeadBarrel {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/dead_archetype.dart ===
// class DeadArchetype {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/live_screen.dart ===
// import 'live_archetype.dart';
//
// class LiveScreen {
//   LiveArchetype get style => LiveArchetype();
// }

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/live_archetype.dart ===
// class LiveArchetype {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/conditional_screen.dart ===
// import 'stub.dart' if (dart.library.io) 'conditional_target.dart';
//
// class ConditionalScreen {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/conditional_target.dart ===
// class ConditionalTarget {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/conditional_barrel.dart ===
// export 'stub.dart' if (dart.library.io) 'dead_archetype.dart';
//
// class ConditionalBarrel {}

// === VIRTUAL_FILE: apps/flutter/test/dead_archetype_test.dart ===
// import 'package:anima_control/features/chat/dead_archetype.dart';
//
// void main() {}

// === VIRTUAL_FILE: apps/flutter/test/dead_barrel_test.dart ===
// import 'package:anima_control/features/chat/dead_barrel.dart';
//
// void main() {}

// === VIRTUAL_FILE: missing/apps/flutter/lib/features/chat/chat_screen.dart ===
// import 'chat_message_display.dart';
//
// class ChatScreen {
//   Widget build(int messageIndex) {
//     final displayed = m.isUser ? m.text : stripMarkers(m.text);
//     const sessionsKey = Key('chat-sessions-button');
//     return ListView.builder(
//       itemBuilder: (_, int messageIndex) => Key('chat-copy-$messageIndex'),
//       itemCount: 1,
//     );
//   }
//
//   // The markdown-body anchor is intentionally absent in this variant.
//   Widget body(String data) => Text(data);
// }

// === VIRTUAL_FILE: forbidden/apps/flutter/lib/features/chat/chat_screen.dart ===
// import 'chat_message_display.dart';
//
// class ChatScreen {
//   Widget build(int messageIndex) {
//     final displayed = m.isUser ? m.text : stripMarkers(m.text);
//     const sessionsKey = Key('chat-sessions-button');
//     final decoration = bubbleDecorationFor(archetypeKey: null, isUser: false);
//     return ListView.builder(
//       itemBuilder: (_, int messageIndex) => Key('chat-copy-$messageIndex'),
//       itemCount: 1,
//     );
//   }
//
//   Widget body(String data) => MarkdownBody(
//         data: data,
//       );
// }
