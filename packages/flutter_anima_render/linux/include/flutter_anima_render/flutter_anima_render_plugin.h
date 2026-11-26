// SPDX-License-Identifier: GPL-3.0-or-later

// Linux backend of the frozen native render/texture contract.
//
// One `FlMethodChannel` per model kind (`org.moeru.airi/anima/model/<kind>`)
// answers the frozen method set (`load`, `setLipSync`, `setEmotion`,
// `setAmbientPhase`, `dispose`) by driving the frozen C ABI in
// `crates/anima-render/cpp/render_contract.h`. The plugin owns the platform
// half of the texture registry: every texture id is minted here by
// `fl_texture_registrar_register_texture` and handed to Dart as the opaque
// integer the `Texture` widget paints; no id is ever invented in Dart, and
// `dispose` releases exactly the ids the backend reports through
// `release_texture`.
//
// The texture is an `FlPixelBufferTexture`: the VRM driver shades into an
// RGBA8 page on the CPU (`crates/anima-render/src/vrm_native/raster.rs`), so
// the render thread copies that page into the texture and marks a frame
// available. No GPU API is required, which is what makes this backend real
// (rather than a stub) on a headless build.

#ifndef FLUTTER_ANIMA_RENDER_LINUX_PLUGIN_H_
#define FLUTTER_ANIMA_RENDER_LINUX_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

G_MODULE_EXPORT
void flutter_anima_render_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_ANIMA_RENDER_LINUX_PLUGIN_H_