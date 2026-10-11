# ---------------------------------------------------------------------------
# libbridge.so - the NAPI C++ shim between the ArkTS UI and the Go core.
#
# The Go core (libcore.so) is NOT linked here. It is loaded at runtime with
# dlopen/dlsym so that:
#   * hvigor can configure and build this module on a machine that has no Go
#     toolchain and no libcore.so yet (the .so is a gitignored build artifact),
#   * the app still starts - and can show a meaningful error - when the core
#     .so is missing instead of failing at dynamic-link time,
#   * the Go runtime and the NAPI module each get their own loader entry and we
#     avoid surprising interactions between c-shared init and the OHOS loader.
#
# See README.md for the full ArkTS -> NAPI -> Go call chain.
# ---------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.5.0)
project(Bridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(bridge SHARED
    napi_init.cpp
)

target_link_libraries(bridge PUBLIC
    libace_napi.z.so
    # dlopen/dlsym live in libdl; on OHOS this is a stub that forwards to the
    # loader, but linking it explicitly is required and portable.
    libdl.so
)

# Let the linker finish even though the module resolves GoInvoke with dlsym.
# (HarmonyOS links native modules with "-z now" by default, which would
# otherwise turn the unresolved symbol into a hard link error.)
target_link_options(bridge PRIVATE "-Wl,--allow-shlib-undefined")
