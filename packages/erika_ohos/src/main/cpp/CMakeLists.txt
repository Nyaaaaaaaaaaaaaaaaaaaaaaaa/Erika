cmake_minimum_required(VERSION 3.17)
project(erika_ohos LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED OHOS_SDK_NATIVE)
  message(FATAL_ERROR "OHOS_SDK_NATIVE is required to build Erika OHPM bridge")
endif()

set(ERIKA_CAPI_SO "${CMAKE_CURRENT_SOURCE_DIR}/liberika_capi.so" CACHE FILEPATH
  "Prebuilt Erika C API runtime")
if(NOT EXISTS "${ERIKA_CAPI_SO}")
  message(FATAL_ERROR "Missing prebuilt Erika runtime: ${ERIKA_CAPI_SO}")
endif()

add_library(erika_capi SHARED IMPORTED GLOBAL)
set_target_properties(erika_capi PROPERTIES IMPORTED_LOCATION "${ERIKA_CAPI_SO}")

get_filename_component(ERIKA_PACKAGES_ROOT
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." REALPATH)
set(ERIKA_HARMONY_NEXT_NATIVE
  "${CMAKE_CURRENT_SOURCE_DIR}/harmony_next")
add_library(erika_ohos SHARED
  erika_ohos.cpp
  erika_ohos_image.cpp
  "${ERIKA_HARMONY_NEXT_NATIVE}/erika_harmony_next_surface.cpp"
)
target_include_directories(erika_ohos PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${ERIKA_HARMONY_NEXT_NATIVE}"
)
target_compile_options(erika_ohos PRIVATE
  -fno-exceptions
  -ffunction-sections
  -fdata-sections
)
target_link_options(erika_ohos PRIVATE -Wl,--gc-sections)
target_link_libraries(erika_ohos PRIVATE
  erika_capi
  libace_napi.z.so
  libnative_window.so
  libnative_display_soloist.so
  libnative_media_codecbase.so
  libhilog_ndk.z.so
)
set_target_properties(erika_ohos PROPERTIES OUTPUT_NAME "erika_ohos")

add_custom_command(
  TARGET erika_ohos POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${ERIKA_CAPI_SO}"
    "$<TARGET_FILE_DIR:erika_ohos>/liberika_capi.so"
  COMMENT "Staging Erika C API runtime beside the ArkTS bridge"
  VERBATIM
)
