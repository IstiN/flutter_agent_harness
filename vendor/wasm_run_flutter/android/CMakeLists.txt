set(LibraryVersion "wasm_run-v0.1.0") # generated; do not edit

# Unlike the Windows & Linux CMakeLists.txt, this Android equivalent is just here
# to download the Android binaries into src/main/jniLibs/ and does not build anything.
# The binary download/extraction is difficult to do concisely in Groovy/Gradle,
# at least across host platforms, so we are just reusing our Linux/Windows logic.

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Download the binaries if they are not already present.
set(LibRoot "${CMAKE_CURRENT_SOURCE_DIR}/src/main/jniLibs")
set(ArchivePath "${CMAKE_CURRENT_SOURCE_DIR}/${LibraryVersion}.tar.gz")

if(NOT EXISTS ${ArchivePath})
  file(DOWNLOAD
    "https://github.com/juancastillo0/wasm_run/releases/download/${LibraryVersion}/android.tar.gz"
    ${ArchivePath}
    TLS_VERIFY ON
  )
endif()

# Extract the binaries, overriding any already present.
file(REMOVE_RECURSE ${LibRoot})
file(MAKE_DIRECTORY ${LibRoot})
execute_process(
  COMMAND ${CMAKE_COMMAND} -E tar xzf ${ArchivePath}
  WORKING_DIRECTORY ${LibRoot}
)

# Play's 16 KB page-size gate (issue #289 DoD item 1): arm64-v8a shared
# objects must be linked with a 16 KB max page size (LOAD segment align
# >= 0x4000) or Play rejects updates targeting API 35+ and the device
# degrades to page-size compat mode. The flag arrives from build.gradle
# (defaultConfig externalNativeBuild) and is applied to arm64-v8a links
# only; the other ABIs keep the toolchain default page size.
if(ANDROID_ABI STREQUAL "arm64-v8a" AND WASM_RUN_ARM64_LINKER_FLAGS)
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${WASM_RUN_ARM64_LINKER_FLAGS}"
      CACHE STRING "Shared linker flags" FORCE)
endif()
