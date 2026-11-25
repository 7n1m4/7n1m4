// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:genui/genui.dart';

/// Minimal allowlisted GenUI catalog: only non-asset basic components.
/// The model is told this exact catalog in the daemon system prompt.
Catalog airiGenUiCatalog() => BasicCatalogItems.asNoAssetCatalog().copyWithout(
      functionsToRemove: <ClientFunction>[BasicFunctions.openUrlFunction],
    );
