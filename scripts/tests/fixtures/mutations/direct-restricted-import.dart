// Mutation fixture: direct banned package import in a restricted chat/ui file.
// Valid Dart on its own; the virtual files below are materialized by
// scripts/tests/mutate-guard.mjs into a detached temp root.
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/ui/chat_screen.dart ===
// import 'package:flutter/widgets.dart';
// import 'package:hive/hive.dart';
//
// class ChatScreen extends StatelessWidget {}
