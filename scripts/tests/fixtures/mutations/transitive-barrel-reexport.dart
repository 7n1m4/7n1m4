// Mutation fixture: export-laundered dart:io reachable through one import hop.
// No forbidden package prefix and no dart:io write/network token appear in any
// file, so only the resolved-import graph guard can kill this mutant.
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/ui/x.dart ===
// import 'package:flutter/widgets.dart';
// import '../state/barrel.dart';
//
// class X {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/state/barrel.dart ===
// export '../data/store.dart';
//
// class Barrel {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/data/store.dart ===
// export 'dart:io';
//
// class Store {}
