// Mutation fixture: pure-formatter relative import that escapes the lib root.
// The marker is in a lib/formatters/ directory (rule F scope), and the file is
// one level below lib/ so '../../outside.dart' resolves above the lib root.
// A benign chat/ui file is included so the graph guard's --root check passes.
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/formatters/pure_formatter.dart ===
// // pure-formatter
// import '../../outside.dart';
//
// double format(double v) => v.abs();

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/ui/anchor.dart ===
// import 'package:flutter/widgets.dart';
//
// class Anchor {}
