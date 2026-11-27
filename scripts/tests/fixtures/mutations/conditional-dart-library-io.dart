// Mutation fixture: conditional library URI laundering dart:io through an
// `if (dart.library.io)` branch, reached via ui -> state -> data.
void main() {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/ui/cond_screen.dart ===
// import 'package:flutter/widgets.dart';
// import '../state/cond_barrel.dart';
//
// class CondScreen {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/state/cond_barrel.dart ===
// export '../data/store.dart';
//
// class CondBarrel {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/data/store.dart ===
// export 'stub.dart' if (dart.library.io) 'dart:io';
//
// class Store {}

// === VIRTUAL_FILE: apps/flutter/lib/features/chat/data/stub.dart ===
// class Stub {}
