#!/usr/bin/env bash

set -euo pipefail

# Prepare a repeatable local build workspace for iOS librime.
#
# This script is intentionally staged. By default it only checks the build
# environment and prints the next commands. Network downloads and compilation
# are opt-in because librime's dependency graph is large.
#
# Usage:
#   bash Scripts/build-librime-ios.sh --check
#   bash Scripts/build-librime-ios.sh --prepare
#   bash Scripts/build-librime-ios.sh --build-deps-iphoneos
#   bash Scripts/build-librime-ios.sh --build-iphoneos
#   ENABLE_WANXIANG_PLUGINS=1 bash Scripts/build-librime-ios.sh --build-iphoneos
#   bash Scripts/build-librime-ios.sh --install-vendor
#   bash Scripts/build-librime-ios.sh --prepare-wanxiang-plugins
#   bash Scripts/build-librime-ios.sh --print-plan
#
# Output contract for this project:
#   Vendor/Rime/include/rime_api.h
#   Vendor/Rime/lib/librime.a
# or:
#   Vendor/Rime/Rime.xcframework

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT_DIR}/build/rime-ios"
SRC_DIR="${BUILD_ROOT}/src"
DEPS_DIR="${BUILD_ROOT}/deps"
INSTALL_DIR="${BUILD_ROOT}/install"
IPHONEOS_DIR="${BUILD_ROOT}/iphoneos"
SIMULATOR_DIR="${BUILD_ROOT}/iphonesimulator"
VENDOR_DIR="${ROOT_DIR}/Vendor/Rime"
TOOLCHAIN_FILE="${BUILD_ROOT}/ios-arm64.toolchain.cmake"

RIME_REPOSITORY="${RIME_REPOSITORY:-https://github.com/rime/librime.git}"
RIME_REF="${RIME_REF:-master}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
BOOST_VERSION="${BOOST_VERSION:-1.89.0}"
ENABLE_WANXIANG_PLUGINS="${ENABLE_WANXIANG_PLUGINS:-0}"
RIME_LUA_REPOSITORY="${RIME_LUA_REPOSITORY:-https://github.com/hchunhui/librime-lua.git}"
RIME_OCTAGRAM_REPOSITORY="${RIME_OCTAGRAM_REPOSITORY:-https://github.com/lotem/librime-octagram.git}"
PLUGIN_SRC_DIR="${BUILD_ROOT}/plugin-src"

MODE="${1:---check}"

missing_tools=()

info() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

fail() {
  printf 'error: %s\n' "$1" >&2
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

require_tool() {
  local tool="$1"
  if ! has_command "${tool}"; then
    missing_tools+=("${tool}")
  fi
}

print_usage() {
  cat <<USAGE
Usage:
  bash Scripts/build-librime-ios.sh --check
  bash Scripts/build-librime-ios.sh --prepare
  bash Scripts/build-librime-ios.sh --build-deps-iphoneos
  bash Scripts/build-librime-ios.sh --build-iphoneos
  ENABLE_WANXIANG_PLUGINS=1 bash Scripts/build-librime-ios.sh --build-iphoneos
  bash Scripts/build-librime-ios.sh --install-vendor
  bash Scripts/build-librime-ios.sh --prepare-wanxiang-plugins
  bash Scripts/build-librime-ios.sh --print-plan

Environment overrides:
  RIME_REPOSITORY=${RIME_REPOSITORY}
  RIME_REF=${RIME_REF}
  IOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}
  BOOST_VERSION=${BOOST_VERSION}
  ENABLE_WANXIANG_PLUGINS=${ENABLE_WANXIANG_PLUGINS}

Notes:
  --check      Validate local tools and SDK availability.
  --prepare    Create build directories and clone/update librime source when tools are present.
  --build-deps-iphoneos
               Build librime's bundled dependencies for iphoneos arm64 into build/rime-ios/install/iphoneos.
  --build-iphoneos
               Configure and build static librime for iphoneos arm64.
               Set ENABLE_WANXIANG_PLUGINS=1 to merge librime-lua and
               librime-octagram into librime.a for Wanxiang.
  --prepare-wanxiang-plugins
               Clone/update librime-lua, its Lua thirdparty branch, and
               librime-octagram, then link them into librime/plugins.
  --install-vendor
               Copy rime_api.h, librime.a, and required static dependency
               archives from the local install dir to Vendor/Rime.
  --print-plan Print the staged build plan for librime and native dependencies.
USAGE
}

iphoneos_install_dir() {
  printf '%s\n' "${INSTALL_DIR}/iphoneos"
}

ensure_librime_checkout() {
  if [[ ! -d "${SRC_DIR}/librime/.git" ]]; then
    fail "Missing librime checkout at ${SRC_DIR}/librime. Run: bash Scripts/build-librime-ios.sh --prepare"
    return 1
  fi
}

write_ios_toolchain() {
  mkdir -p "${BUILD_ROOT}"
  cat > "${TOOLCHAIN_FILE}" <<TOOLCHAIN
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET ${IOS_DEPLOYMENT_TARGET})
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
TOOLCHAIN
  info "Wrote iOS CMake toolchain: ${TOOLCHAIN_FILE}"
}

check_sdk() {
  if ! has_command xcrun; then
    fail "xcrun is missing. Install Xcode command line tools or select a full Xcode."
    return 1
  fi

  local sdk_path
  if ! sdk_path="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; then
    fail "Unable to locate the iPhoneOS SDK with xcrun."
    return 1
  fi

  info "iPhoneOS SDK: ${sdk_path}"
}

check_environment() {
  info "Checking iOS librime build environment"

  require_tool xcodebuild
  require_tool xcrun
  require_tool git
  require_tool curl
  require_tool cmake
  require_tool ninja
  require_tool make
  require_tool autoconf
  require_tool automake

  if ! has_command libtoolize && ! has_command glibtoolize; then
    missing_tools+=("libtoolize/glibtoolize")
  fi

  if ((${#missing_tools[@]} > 0)); then
    fail "Missing build tools: ${missing_tools[*]}"
    cat >&2 <<'INSTALL_HINT'

Suggested Homebrew packages:
  brew install cmake ninja autoconf automake libtool

After installing, run:
  bash Scripts/build-librime-ios.sh --check
INSTALL_HINT
    return 1
  fi

  check_sdk

  info "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  info "CMake: $(cmake --version | head -n 1)"
  info "Ninja: $(ninja --version)"
  info "Git: $(git --version)"
  info "Deployment target: iOS ${IOS_DEPLOYMENT_TARGET}"
  info "Environment check passed."
}

prepare_workspace() {
  check_environment

  info "Creating build directories under ${BUILD_ROOT}"
  mkdir -p "${SRC_DIR}" "${DEPS_DIR}" "${INSTALL_DIR}" "${IPHONEOS_DIR}" "${SIMULATOR_DIR}" "${PLUGIN_SRC_DIR}" "${VENDOR_DIR}/include" "${VENDOR_DIR}/lib"

  if [[ -d "${SRC_DIR}/librime/.git" ]]; then
    info "Updating existing librime checkout"
    git -C "${SRC_DIR}/librime" fetch --tags origin
    git -C "${SRC_DIR}/librime" checkout "${RIME_REF}"
    git -C "${SRC_DIR}/librime" pull --ff-only || warn "Could not fast-forward librime; inspect ${SRC_DIR}/librime manually."
  else
    info "Cloning librime from ${RIME_REPOSITORY}"
    git clone --recursive "${RIME_REPOSITORY}" "${SRC_DIR}/librime"
    git -C "${SRC_DIR}/librime" checkout "${RIME_REF}"
  fi

  info "Workspace prepared."
  print_plan
}

prepare_wanxiang_plugins() {
  check_environment
  ensure_librime_checkout

  mkdir -p "${PLUGIN_SRC_DIR}"

  if [[ -d "${PLUGIN_SRC_DIR}/librime-lua/.git" ]]; then
    info "Updating existing librime-lua checkout"
    git -C "${PLUGIN_SRC_DIR}/librime-lua" fetch --depth=1 origin
    git -C "${PLUGIN_SRC_DIR}/librime-lua" pull --ff-only || warn "Could not fast-forward librime-lua; inspect ${PLUGIN_SRC_DIR}/librime-lua manually."
  else
    info "Cloning librime-lua"
    git clone --depth=1 "${RIME_LUA_REPOSITORY}" "${PLUGIN_SRC_DIR}/librime-lua"
  fi

  if [[ ! -d "${PLUGIN_SRC_DIR}/librime-lua/thirdparty/lua5.4" ]]; then
    info "Cloning librime-lua thirdparty Lua source"
    git -C "${PLUGIN_SRC_DIR}/librime-lua" clone "${RIME_LUA_REPOSITORY}" -b thirdparty --depth=1 thirdparty
  fi

  if [[ -d "${PLUGIN_SRC_DIR}/librime-octagram/.git" ]]; then
    info "Updating existing librime-octagram checkout"
    git -C "${PLUGIN_SRC_DIR}/librime-octagram" fetch --depth=1 origin
    git -C "${PLUGIN_SRC_DIR}/librime-octagram" pull --ff-only || warn "Could not fast-forward librime-octagram; inspect ${PLUGIN_SRC_DIR}/librime-octagram manually."
  else
    info "Cloning librime-octagram"
    git clone --depth=1 "${RIME_OCTAGRAM_REPOSITORY}" "${PLUGIN_SRC_DIR}/librime-octagram"
  fi

  rm -rf "${SRC_DIR}/librime/plugins/lua" "${SRC_DIR}/librime/plugins/octagram"
  ln -s "../../../plugin-src/librime-lua" "${SRC_DIR}/librime/plugins/lua"
  ln -s "../../../plugin-src/librime-octagram" "${SRC_DIR}/librime/plugins/octagram"

  info "Wanxiang plugins linked into librime/plugins: lua, octagram"
}

build_deps_iphoneos() {
  check_environment
  ensure_librime_checkout
  write_ios_toolchain

  local install_prefix
  install_prefix="$(iphoneos_install_dir)"
  mkdir -p "${install_prefix}"

  info "Building bundled librime dependencies for iphoneos arm64"
  info "Install prefix: ${install_prefix}"

  build_boost_iphoneos

  cmake_dep glog "${SRC_DIR}/librime/deps/glog" "${IPHONEOS_DIR}/deps/glog" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_TESTING:BOOL=OFF \
    -DWITH_GFLAGS:BOOL=OFF

  cmake_dep leveldb "${SRC_DIR}/librime/deps/leveldb" "${IPHONEOS_DIR}/deps/leveldb" \
    -DHAVE_CRC32C:BOOL=OFF \
    -DHAVE_SNAPPY:BOOL=OFF \
    -DHAVE_TCMALLOC:BOOL=OFF \
    -DLEVELDB_BUILD_BENCHMARKS:BOOL=OFF \
    -DLEVELDB_BUILD_TESTS:BOOL=OFF

  cmake_dep marisa-trie "${SRC_DIR}/librime/deps/marisa-trie" "${IPHONEOS_DIR}/deps/marisa-trie" \
    -DBUILD_TESTING:BOOL=OFF \
    -DENABLE_TOOLS:BOOL=OFF

  patch_opencc_for_ios_library_build
  cmake_dep opencc "${SRC_DIR}/librime/deps/opencc" "${IPHONEOS_DIR}/deps/opencc" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_DOCUMENTATION:BOOL=OFF \
    -DBUILD_TESTING:BOOL=OFF \
    -DENABLE_GTEST:BOOL=OFF

  cmake_dep yaml-cpp "${SRC_DIR}/librime/deps/yaml-cpp" "${IPHONEOS_DIR}/deps/yaml-cpp" \
    -DYAML_CPP_BUILD_CONTRIB:BOOL=OFF \
    -DYAML_CPP_BUILD_TESTS:BOOL=OFF \
    -DYAML_CPP_BUILD_TOOLS:BOOL=OFF

  info "Dependency build finished."
}

boost_root() {
  printf '%s\n' "${SRC_DIR}/librime/deps/boost-${BOOST_VERSION}"
}

build_boost_iphoneos() {
  local install_prefix boost_dir sdk_path clang cxxflags linkflags
  install_prefix="$(iphoneos_install_dir)"
  boost_dir="$(boost_root)"
  sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
  clang="$(xcrun --sdk iphoneos --find clang++)"

  if [[ ! -f "${boost_dir}/bootstrap.sh" ]]; then
    info "Downloading Boost ${BOOST_VERSION} via librime/install-boost.sh"
    boost_version="${BOOST_VERSION}" BOOST_ROOT="${boost_dir}" bash "${SRC_DIR}/librime/install-boost.sh" --download
  else
    info "Found Boost source: ${boost_dir}"
  fi

  if [[ -f "${install_prefix}/include/boost/version.hpp" && -f "${install_prefix}/lib/libboost_regex.a" ]]; then
    info "Boost headers and regex library already installed for iphoneos"
    return 0
  fi

  info "Building Boost regex for iphoneos arm64"
  cxxflags="-arch arm64 -isysroot ${sdk_path} -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET} -std=c++17"
  linkflags="-arch arm64 -isysroot ${sdk_path} -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"

  (
    cd "${boost_dir}"
    ./bootstrap.sh --with-toolset=clang --with-libraries=regex
    ./b2 -q \
      --with-regex \
      toolset=clang \
      target-os=iphone \
      architecture=arm \
      address-model=64 \
      binary-format=mach-o \
      abi=aapcs \
      link=static \
      threading=multi \
      variant=release \
      cxxflags="${cxxflags}" \
      linkflags="${linkflags}" \
      --prefix="${install_prefix}" \
      install
  )

  info "Boost build finished."
}

patch_opencc_for_ios_library_build() {
  local opencc_root="${SRC_DIR}/librime/deps/opencc"

  info "Patching OpenCC CMake files for iOS library-only cross build"

  perl -0pi -e 's/add_subdirectory\(data\)/if\(NOT IOS\)\n  add_subdirectory\(data\)\nendif\(\)/g' "${opencc_root}/CMakeLists.txt"
  perl -0pi -e 's/add_subdirectory\(test\)/if\(ENABLE_GTEST\)\n  add_subdirectory\(test\)\nendif\(\)/g' "${opencc_root}/CMakeLists.txt"
  perl -0pi -e 's/add_subdirectory\(tools\)/if\(NOT IOS\)\n  add_subdirectory\(tools\)\nendif\(\)/g' "${opencc_root}/src/CMakeLists.txt"
}

cmake_dep() {
  local name="$1"
  local source_dir="$2"
  local build_dir="$3"
  shift 3

  local install_prefix
  install_prefix="$(iphoneos_install_dir)"

  info "Configuring dependency: ${name}"
  cmake -S "${source_dir}" -B "${build_dir}" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${install_prefix}" \
    -DCMAKE_PREFIX_PATH:PATH="${install_prefix}" \
    "$@"

  info "Building dependency: ${name}"
  cmake --build "${build_dir}" --target install
}

build_librime_iphoneos() {
  check_environment
  ensure_librime_checkout
  write_ios_toolchain

  local install_prefix build_dir rime_plugins_env
  install_prefix="$(iphoneos_install_dir)"
  build_dir="${IPHONEOS_DIR}/librime"
  rime_plugins_env=""

  if [[ ! -d "${install_prefix}/include" || ! -d "${install_prefix}/lib" ]]; then
    fail "Missing dependency install prefix ${install_prefix}. Run: bash Scripts/build-librime-ios.sh --build-deps-iphoneos"
    return 1
  fi

  local extra_cmake_args=()
  if [[ "${ENABLE_WANXIANG_PLUGINS}" == "1" ]]; then
    prepare_wanxiang_plugins
    build_dir="${IPHONEOS_DIR}/librime-wanxiang"
    rime_plugins_env="lua octagram"
    extra_cmake_args+=(
      -DCMAKE_C_FLAGS:STRING="-DLUA_USE_IOS"
      -DCMAKE_CXX_FLAGS:STRING="-DLUA_USE_IOS"
      -DBUILD_TOOLS:BOOL=OFF
    )
  fi

  info "Configuring librime static library for iphoneos arm64"
  RIME_PLUGINS="${rime_plugins_env}" cmake -S "${SRC_DIR}/librime" -B "${build_dir}" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${install_prefix}" \
    -DCMAKE_PREFIX_PATH:PATH="${install_prefix}" \
    -DBoost_NO_SYSTEM_PATHS:BOOL=ON \
    -DBOOST_ROOT:PATH="$(boost_root)" \
    -DBoost_INCLUDE_DIR:PATH="${install_prefix}/include" \
    -DBoost_LIBRARY_DIR_RELEASE:PATH="${install_prefix}/lib" \
    -DBoost_REGEX_LIBRARY_RELEASE:FILEPATH="${install_prefix}/lib/libboost_regex.a" \
    -DGlog_INCLUDE_PATH:PATH="${install_prefix}/include" \
    -DGlog_LIBRARY:FILEPATH="${install_prefix}/lib/libglog.a" \
    -DYamlCpp_INCLUDE_PATH:PATH="${install_prefix}/include" \
    -DYamlCpp_NEW_API:PATH="${install_prefix}/include" \
    -DYamlCpp_LIBRARY:FILEPATH="${install_prefix}/lib/libyaml-cpp.a" \
    -DLevelDb_INCLUDE_PATH:PATH="${install_prefix}/include" \
    -DLevelDb_LIBRARY:FILEPATH="${install_prefix}/lib/libleveldb.a" \
    -DMarisa_INCLUDE_PATH:PATH="${install_prefix}/include" \
    -DMarisa_LIBRARY:FILEPATH="${install_prefix}/lib/libmarisa.a" \
    -DOpencc_INCLUDE_PATH:PATH="${install_prefix}/include" \
    -DOpencc_LIBRARY:FILEPATH="${install_prefix}/lib/libopencc.a" \
    -DBUILD_STATIC:BOOL=ON \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_TEST:BOOL=OFF \
    -DBUILD_DATA:BOOL=OFF \
    -DBUILD_SAMPLE:BOOL=OFF \
    -DBUILD_MERGED_PLUGINS:BOOL=ON \
    -DENABLE_EXTERNAL_PLUGINS:BOOL=OFF \
    -DENABLE_LOGGING:BOOL=ON \
    "${extra_cmake_args[@]}"

  info "Building and installing librime"
  cmake --build "${build_dir}" --target install

  info "librime build finished."
  info "Expected library path: ${install_prefix}/lib/librime.a or ${install_prefix}/lib/librime-static.a"
}

install_vendor() {
  local install_prefix
  install_prefix="$(iphoneos_install_dir)"
  mkdir -p "${VENDOR_DIR}/include" "${VENDOR_DIR}/lib"

  if [[ ! -f "${install_prefix}/include/rime_api.h" ]]; then
    fail "Missing ${install_prefix}/include/rime_api.h. Build librime first."
    return 1
  fi

  local source_lib=""
  for candidate in "${install_prefix}/lib/librime.a" "${install_prefix}/lib/librime-static.a" "${IPHONEOS_DIR}/librime/src/librime-static.a"; do
    if [[ -f "${candidate}" ]]; then
      source_lib="${candidate}"
      break
    fi
  done

  if [[ -z "${source_lib}" ]]; then
    fail "Could not find librime static library under ${install_prefix}/lib or ${IPHONEOS_DIR}/librime/src."
    return 1
  fi

  cp "${install_prefix}/include/rime_api.h" "${VENDOR_DIR}/include/rime_api.h"
  cp "${source_lib}" "${VENDOR_DIR}/lib/librime.a"
  for dependency_lib in libboost_regex.a libglog.a libleveldb.a libmarisa.a libopencc.a libyaml-cpp.a; do
    if [[ -f "${install_prefix}/lib/${dependency_lib}" ]]; then
      cp "${install_prefix}/lib/${dependency_lib}" "${VENDOR_DIR}/lib/${dependency_lib}"
    else
      warn "Missing static dependency during vendor install: ${install_prefix}/lib/${dependency_lib}"
    fi
  done

  info "Installed vendor header, librime, and static dependency libraries."
  bash "${ROOT_DIR}/Scripts/check-rime-vendor.sh"
}

print_plan() {
  cat <<PLAN

Staged librime iOS build plan
=============================

1. Build or import native dependencies for iphoneos arm64:
   - Boost
   - yaml-cpp
   - glog
   - marisa
   - opencc
   - leveldb

2. Configure librime with an iOS CMake toolchain:
   - SDK: $(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || printf 'iphoneos SDK unavailable')
   - Arch: arm64
   - Deployment target: ${IOS_DEPLOYMENT_TARGET}
   - Static linking preferred for keyboard extension packaging.
   - For Wanxiang, build with:
     ENABLE_WANXIANG_PLUGINS=1 bash Scripts/build-librime-ios.sh --build-iphoneos
     This merges librime-lua and librime-octagram into librime.a.

3. Install final artifacts into the project contract:
   - Vendor/Rime/include/rime_api.h
   - Vendor/Rime/lib/librime.a
   - Vendor/Rime/lib/libboost_regex.a, libglog.a, libleveldb.a,
     libmarisa.a, libopencc.a, libyaml-cpp.a

4. Validate the drop:
   bash Scripts/check-rime-vendor.sh

5. Only after validation passes, continue to:
   - Xcode Header Search Paths / Library Search Paths
   - Objective-C/C wrapper
   - Swift bridging header
   - RimeBridge native implementation

Current build workspace:
  ${BUILD_ROOT}

PLAN
}

case "${MODE}" in
  --check)
    check_environment
    ;;
  --prepare)
    prepare_workspace
    ;;
  --build-deps-iphoneos)
    build_deps_iphoneos
    ;;
  --build-iphoneos)
    build_librime_iphoneos
    ;;
  --prepare-wanxiang-plugins)
    prepare_wanxiang_plugins
    ;;
  --install-vendor)
    install_vendor
    ;;
  --print-plan)
    print_plan
    ;;
  -h|--help)
    print_usage
    ;;
  *)
    fail "Unknown mode: ${MODE}"
    print_usage >&2
    exit 2
    ;;
esac
