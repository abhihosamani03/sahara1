cmake_minimum_required(VERSION 3.22.1)
project(sahara_codec2 C)

# Codec2 1.2.0 source vendored under codec2/. Its codebooks (codebook*.c) were
# generated once on the host with src/generate_codebook and are checked in, so
# the Android build never needs to run a host toolchain.
set(CODEC2_DIR ${CMAKE_CURRENT_SOURCE_DIR}/codec2)

file(GLOB CODEC2_SOURCES ${CODEC2_DIR}/*.c)

add_library(sahara_codec2 SHARED ${CODEC2_SOURCES} codec2_jni.c)

target_include_directories(sahara_codec2 PRIVATE ${CODEC2_DIR})
# freedv_api.c embeds the git hash; upstream CMake generates it, we pin it.
target_compile_definitions(sahara_codec2 PRIVATE GIT_HASH="sahara")
target_compile_options(sahara_codec2 PRIVATE -O2 -w -fvisibility=hidden)
target_link_libraries(sahara_codec2 PRIVATE m log)
