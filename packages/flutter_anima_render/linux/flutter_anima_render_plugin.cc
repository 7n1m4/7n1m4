// SPDX-License-Identifier: GPL-3.0-or-later

#include "include/flutter_anima_render/flutter_anima_render_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "render_contract.h"
#include "vrm_backend.h"

// One platform texture: an FlPixelBufferTexture the render thread refills from
// the native RGBA8 page, plus the id the platform minted for it. The id is
// owned by this plugin's registry; Dart only ever sees the integer.
struct PlatformTexture {
  FlPixelBufferTexture* texture = nullptr;
  int64_t id = -1;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> pixels;
};

// One loaded model: the native handle plus the platform textures the backend
// minted for its pages and shaded output surface.
struct LoadedModel {
  airi_render_handle handle = {0, AIRI_RENDER_NO_TEXTURE};
  std::vector<PlatformTexture*> textures;
};

struct FlutterAnimaRenderPlugin {
  GObject parent_instance;

  FlPluginRegistrar* registrar = nullptr;
  FlTextureRegistrar* texture_registrar = nullptr;
  FlMethodChannel* channel = nullptr;
  airi_render_backend* backend = nullptr;
  guint frame_timer = 0;
  LoadedModel* loading_model = nullptr;
  std::map<uint64_t, LoadedModel> models;
};

typedef struct _FlutterAnimaRenderPluginClass {
  GObjectClass parent_class;
} FlutterAnimaRenderPluginClass;

#define FLUTTER_ANIMA_RENDER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_anima_render_plugin_get_type(), \
                              FlutterAnimaRenderPlugin))

G_DEFINE_TYPE(FlutterAnimaRenderPlugin, flutter_anima_render_plugin,
              G_TYPE_OBJECT)

static GType platform_texture_get_type(void);
static gboolean pump_frames(gpointer user_data);

// --- Texture registry the frozen C ABI calls back into --------------------

static uint32_t platform_register_texture(void* ctx, uint32_t width,
                                          uint32_t height) {
  auto* self = static_cast<FlutterAnimaRenderPlugin*>(ctx);
  if (self == nullptr || self->texture_registrar == nullptr) {
    return AIRI_RENDER_NO_TEXTURE;
  }
  auto* platform = new PlatformTexture();
  platform->texture = static_cast<FlPixelBufferTexture*>(
      g_object_new(platform_texture_get_type(), nullptr));
  platform->width = width;
  platform->height = height;
  platform->pixels.assign(static_cast<size_t>(width) * height * 4, 0);
  g_object_set_data(G_OBJECT(platform->texture), "anima-plugin", self);
  if (!fl_texture_registrar_register_texture(
          self->texture_registrar, FL_TEXTURE(platform->texture))) {
    platform->id = -1;
  } else {
    platform->id = fl_texture_get_id(FL_TEXTURE(platform->texture));
  }
  if (self->loading_model != nullptr) {
    self->loading_model->textures.push_back(platform);
  } else {
    // A texture minted outside a load (there is none today) is owned by the
    // plugin and released with it.
    g_object_unref(platform->texture);
    delete platform;
  }
  return platform->id < 0 ? AIRI_RENDER_NO_TEXTURE
                          : static_cast<uint32_t>(platform->id);
}

// Release one platform texture owned by either an in-flight load (the
// backend calls `release_texture` before `airi_render_load` returns) or a
// fully loaded model. Registration failures have id -1 and are destroyed
// locally by `release_all_textures` below; they cannot be looked up by id.
static void release_platform_texture(FlutterAnimaRenderPlugin* self,
                                     std::vector<PlatformTexture*>& textures,
                                     PlatformTexture* platform) {
  auto it = std::find(textures.begin(), textures.end(), platform);
  if (it == textures.end()) return;
  if (platform->id >= 0 && self->texture_registrar != nullptr) {
    fl_texture_registrar_unregister_texture(
        self->texture_registrar, FL_TEXTURE(platform->texture));
  }
  g_object_unref(platform->texture);
  delete platform;
  textures.erase(it);
}

static void release_all_textures(FlutterAnimaRenderPlugin* self,
                                 LoadedModel& model) {
  while (!model.textures.empty()) {
    release_platform_texture(self, model.textures, model.textures.back());
  }
}

static void platform_release_texture(void* ctx, uint32_t texture_id) {
  auto* self = static_cast<FlutterAnimaRenderPlugin*>(ctx);
  if (self == nullptr) return;
  if (self->loading_model != nullptr) {
    for (auto* platform : self->loading_model->textures) {
      if (platform->id != static_cast<int64_t>(texture_id)) continue;
      release_platform_texture(self, self->loading_model->textures, platform);
      return;
    }
  }
  for (auto& entry : self->models) {
    for (auto* platform : entry.second.textures) {
      if (platform->id != static_cast<int64_t>(texture_id)) continue;
      release_platform_texture(self, entry.second.textures, platform);
      return;
    }
  }
  // A release for a texture this plugin already forgot is not an error: the
  // frozen contract is idempotent on dispose.
}

// Copy the native page bytes for one texture index into the platform buffer.
// The frozen ABI reports every page (base colours, then shaded output) as
// tightly packed RGBA8; the C++ backend owns the pixel lifetime, so the copy
// is complete before it returns.
static bool fill_texture_page(FlutterAnimaRenderPlugin* self, LoadedModel& model,
                              size_t page_index) {
  airi_render_page* pages = nullptr;
  size_t page_count = 0;
  if (airi_render_pages(self->backend, model.handle, nullptr, 0, &page_count) != 0 ||
      page_count != model.textures.size() || page_index >= page_count) {
    return false;
  }
  std::vector<airi_render_page> buffer(page_count);
  if (airi_render_pages(self->backend, model.handle, buffer.data(), buffer.size(),
                        &page_count) != 0 || page_count != buffer.size()) {
    return false;
  }
  const airi_render_page& page = buffer[page_index];
  PlatformTexture* texture = model.textures[page_index];
  const size_t bytes = static_cast<size_t>(page.width) * page.height * 4;
  if (page.pixels == nullptr || page.pixels_len < bytes || bytes == 0 ||
      texture->pixels.size() != bytes) {
    return false;
  }
  std::memcpy(texture->pixels.data(), page.pixels, bytes);
  return true;
}

static gboolean copy_pixels(FlPixelBufferTexture* texture,
                            const uint8_t** out_buffer, uint32_t* width,
                            uint32_t* height, GError** error) {
  auto* self = static_cast<FlutterAnimaRenderPlugin*>(
      g_object_get_data(G_OBJECT(texture), "anima-plugin"));
  if (self == nullptr) {
    g_set_error(error, 1, 1, "texture has no owning plugin");
    return FALSE;
  }
  for (auto& entry : self->models) {
    for (auto* platform : entry.second.textures) {
      if (platform->texture != texture) continue;
      *out_buffer = platform->pixels.data();
      *width = platform->width;
      *height = platform->height;
      return TRUE;
    }
  }
  g_set_error(error, 1, 1, "texture is not registered with the plugin");
  return FALSE;
}

static void pixel_buffer_texture_init(FlPixelBufferTexture* self) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(G_OBJECT_GET_CLASS(self))->copy_pixels =
      copy_pixels;
}

// FlPixelBufferTexture subclass whose copy_pixels reads the owning plugin's
// texture table. The class is registered once, lazily.
static GType platform_texture_get_type(void) {
  static GType type = 0;
  if (g_once_init_enter(&type) == FALSE) {
    static const GTypeInfo info = {
        sizeof(FlPixelBufferTextureClass),
        nullptr,
        nullptr,
        reinterpret_cast<GClassInitFunc>(pixel_buffer_texture_init),
        nullptr,
        nullptr,
        sizeof(FlPixelBufferTexture),
        0,
        nullptr,
        nullptr,
    };
    GType new_type = g_type_register_static(
        fl_pixel_buffer_texture_get_type(), "AnimaPlatformTexture", &info,
        static_cast<GTypeFlags>(0));
    g_once_init_leave(&type, new_type);
  }
  return type;
}

// --- Method channel -------------------------------------------------------

static void respond_success(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("flutter_anima_render: respond failed: %s", error->message);
  }
}

static void respond_error(FlMethodCall* call, const char* code,
                          const char* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("flutter_anima_render: respond failed: %s", error->message);
  }
}

static std::string arg_string(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : std::string();
}

static double arg_double(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) return 0.0;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(value));
  }
  return fl_value_get_float(value);
}

static LoadedModel* find_model(FlutterAnimaRenderPlugin* self, uint64_t id) {
  auto it = self->models.find(id);
  return it == self->models.end() ? nullptr : &it->second;
}

static bool parse_handle(FlValue* args, uint64_t* out_id) {
  FlValue* value = fl_value_lookup_string(args, "handle");
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return false;
  }
  const char* text = fl_value_get_string(value);
  char* end = nullptr;
  unsigned long long id = strtoull(text, &end, 10);
  if (end == text || id == 0) return false;
  *out_id = static_cast<uint64_t>(id);
  return true;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  auto* self = static_cast<FlutterAnimaRenderPlugin*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "load") == 0) {
    const std::string path = arg_string(args, "path");
    if (path.empty()) {
      respond_error(call, "invalid-argument", "load requires a path");
      return;
    }
    airi_render_handle handle = {0, AIRI_RENDER_NO_TEXTURE};
    LoadedModel model;
    model.handle = handle;
    self->loading_model = &model;
    if (airi_render_load(self->backend, path.c_str(), &handle) != 0) {
      // The backend has finished releasing the native pages; tear down any
      // platform textures (including failed registrations) still owned by
      // the in-flight model before dropping it.
      release_all_textures(self, model);
      self->loading_model = nullptr;
      const char* reason = airi_render_last_error(self->backend);
      respond_error(call, "load-failed",
                    reason != nullptr ? reason : "airi_render_load failed");
      return;
    }
    self->loading_model = nullptr;
    model.handle = handle;
    // Upload base colours once and the shaded output page immediately, so
    // the very first presented frame has real pixels instead of a blank
    // buffer. Later ticks refresh the output page in `pump_frames`.
    for (size_t i = 0; i < model.textures.size(); ++i) {
      fill_texture_page(self, model, i);
    }
    self->models[handle.id] = std::move(model);
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(
        result, "handle", fl_value_new_string(std::to_string(handle.id).c_str()));
    fl_value_set_string_take(result, "textureId",
                             fl_value_new_int(handle.texture_id));
    respond_success(call, result);
    return;
  }

  uint64_t id = 0;
  if (!parse_handle(args, &id)) {
    respond_error(call, "invalid-handle", "missing or malformed model handle");
    return;
  }
  LoadedModel* model = find_model(self, id);
  if (model == nullptr) {
    respond_error(call, "invalid-handle", "unknown model handle");
    return;
  }

  if (strcmp(method, "dispose") == 0) {
    // Let the native driver release each minted id first: its callback finds
    // the still-live platform texture and unregisters it. Then clean up any
    // leftovers (e.g. ids that never registered) before erasing the model.
    airi_render_dispose(self->backend, model->handle);
    release_all_textures(self, *model);
    self->models.erase(id);
    respond_success(call, nullptr);
    return;
  }

  airi_render_handle native = model->handle;
  if (strcmp(method, "setLipSync") == 0) {
    if (airi_render_set_lip_sync(
            self->backend, native,
            static_cast<float>(arg_double(args, "weight"))) != 0) {
      respond_error(call, "setLipSync-failed",
                    airi_render_last_error(self->backend));
      return;
    }
    respond_success(call, nullptr);
    return;
  }
  if (strcmp(method, "setEmotion") == 0) {
    const std::string tag = arg_string(args, "tag");
    const std::string kind = arg_string(args, "kind");
    if (airi_render_set_emotion(
            self->backend, native, tag.c_str(), kind.c_str(),
            static_cast<float>(arg_double(args, "intensity"))) != 0) {
      respond_error(call, "setEmotion-failed",
                    airi_render_last_error(self->backend));
      return;
    }
    respond_success(call, nullptr);
    return;
  }
  if (strcmp(method, "setAmbientPhase") == 0) {
    if (airi_render_set_ambient_phase(
            self->backend, native,
            static_cast<float>(arg_double(args, "phase"))) != 0) {
      respond_error(call, "setAmbientPhase-failed",
                    airi_render_last_error(self->backend));
      return;
    }
    respond_success(call, nullptr);
    return;
  }

  respond_error(call, "not-implemented", "unknown method");
}

// --- Frame pump -----------------------------------------------------------

// Advance the CPU-shaded driver and upload its output page before marking a
// new frame. The frozen ABI exposes the shaded RGBA8 page through
// `airi_render_pages`; without the copy, every platform texture stays zero
// filled even though the model is animating.
static gboolean pump_frames(gpointer user_data) {
  auto* self = static_cast<FlutterAnimaRenderPlugin*>(user_data);
  if (self == nullptr || self->backend == nullptr) return TRUE;
  for (auto& entry : self->models) {
    LoadedModel& model = entry.second;
    const size_t last = model.textures.size();
    if (last == 0) continue;
    size_t vertex_count = 0, index_count = 0, draw_count = 0;
    airi_render_frame_counts(self->backend, model.handle, &vertex_count,
                             &index_count, &draw_count);
    std::vector<airi_render_vertex> vertices(vertex_count);
    std::vector<uint32_t> indices(index_count);
    std::vector<airi_render_draw> draws(draw_count);
    airi_render_render(self->backend, model.handle, 1.0f / 30.0f,
                       vertices.data(), vertices.size(), indices.data(),
                       indices.size(), draws.data(), draws.size());
    if (!fill_texture_page(self, model, last - 1)) continue;
    fl_texture_registrar_mark_texture_frame_available(
        self->texture_registrar,
        FL_TEXTURE(model.textures.back()->texture));
  }
  return TRUE;
}

// --- Object lifecycle -----------------------------------------------------

static void flutter_anima_render_plugin_dispose(GObject* object) {
  auto* self = FLUTTER_ANIMA_RENDER_PLUGIN(object);
  for (auto& entry : self->models) {
    airi_render_dispose(self->backend, entry.second.handle);
  }
  self->models.clear();
  if (self->frame_timer != 0) {
    g_source_remove(self->frame_timer);
    self->frame_timer = 0;
  }
  if (self->channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                              nullptr);
    g_object_unref(self->channel);
    self->channel = nullptr;
  }
  if (self->backend != nullptr) {
    airi_render_destroy(self->backend);
    self->backend = nullptr;
  }
  G_OBJECT_CLASS(flutter_anima_render_plugin_parent_class)->dispose(object);
}

static void flutter_anima_render_plugin_class_init(
    FlutterAnimaRenderPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_anima_render_plugin_dispose;
}

static void flutter_anima_render_plugin_init(FlutterAnimaRenderPlugin* self) {
  self->registrar = nullptr;
  self->texture_registrar = nullptr;
  self->channel = nullptr;
  self->backend = nullptr;
  self->frame_timer = 0;
  self->loading_model = nullptr;
}

void flutter_anima_render_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto* self = FLUTTER_ANIMA_RENDER_PLUGIN(
      g_object_new(flutter_anima_render_plugin_get_type(), nullptr));

  self->registrar = registrar;
  self->texture_registrar =
      fl_plugin_registrar_get_texture_registrar(registrar);
  self->backend = airi_render_create(
      AIRI_RENDER_KIND_VRM, platform_register_texture,
      platform_release_texture, self);
  if (self->backend == nullptr) {
    g_warning("flutter_anima_render: airi_render_create failed");
    g_object_unref(self);
    return;
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "org.moeru.airi/anima/model/vrm", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            self, nullptr);

  // Pump the shaded output page into the platform texture at ~30 Hz. The
  // driver renders on the CPU, so the pump is a memcpy plus a frame mark.
  self->frame_timer = g_timeout_add(33, pump_frames, self);
}