# See: https://github.com/flutter/flutter/blob/master/packages/flutter_tools/templates/plugin_shared/linux.tmpl/CMakeLists.txt.tmpl
cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "flutter_anima_render")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "flutter_anima_render_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET glib-2.0)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../crates/anima-render/cpp"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK ${GLIB_LIBRARIES})

# The frozen C ABI (`crates/anima-render/cpp/render_contract.h`) and the Rust
# driver it dispatches into. `cargo build -p anima-render --lib` produces
# `target/<profile>/libanima_render.a`; the crate's build script leaves the C++
# backends in `target/<profile>/build/anima-render-*/out`. Both are required:
# the C ABI entry points live in the Rust archive, the C++ dispatch in the cc
# archives. `build_native.sh` is the supported way to produce them.
get_filename_component(ANIMA_PLUGIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(ANIMA_REPO_ROOT "${ANIMA_PLUGIN_DIR}/../../.." REALPATH)
set(ANIMA_CARGO_TARGET_DIR "${ANIMA_REPO_ROOT}/target")

set(ANIMA_STATICLIB "")
foreach(profile debug release)
  if(NOT ANIMA_STATICLIB)
    set(candidate "${ANIMA_CARGO_TARGET_DIR}/${profile}/libanima_render.a")
    if(EXISTS "${candidate}")
      set(ANIMA_STATICLIB "${candidate}")
      set(ANIMA_BUILD_OUT_DIR "${ANIMA_CARGO_TARGET_DIR}/${profile}/build")
    endif()
  endif()
endforeach()
if(NOT ANIMA_STATICLIB)
  message(FATAL_ERROR
    "libanima_render.a not found under ${ANIMA_CARGO_TARGET_DIR}; run "
    "packages/flutter_anima_render/linux/build_native.sh first")
endif()

file(GLOB ANIMA_BACKEND_ARCHIVES "${ANIMA_BUILD_OUT_DIR}/anima-render-*/out")
set(ANIMA_LINK_LIBRARIES "${ANIMA_STATICLIB}")
foreach(archive_dir ${ANIMA_BACKEND_ARCHIVES})
  list(APPEND ANIMA_LINK_LIBRARIES
    "${archive_dir}/libairi_render_backends.a"
    "${archive_dir}/libairi_spine_cpp.a"
  )
endforeach()
target_link_libraries(${PLUGIN_NAME} PRIVATE ${ANIMA_LINK_LIBRARIES})

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(flutter_anima_render_bundled_libraries
  ""
  PARENT_SCOPE
)