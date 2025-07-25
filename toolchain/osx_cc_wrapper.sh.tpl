#!/bin/bash
#
# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# OS X relpath is not really working. This is a wrapper script around gcc
# to simulate relpath behavior.
#
# This wrapper uses install_name_tool to replace all paths in the binary
# (bazel-out/.../path/to/original/library.so) by the paths relative to
# the binary. It parses the command line to behave as rpath is supposed
# to work.
#
# See https://blogs.oracle.com/dipol/entry/dynamic_libraries_rpath_and_mac
# on how to set those paths for Mach-O binaries.

# shellcheck disable=SC1083

set -euo pipefail

INSTALL_NAME_TOOL="/usr/bin/install_name_tool"

LIBS=
LIB_DIRS=
RPATHS=
OUTPUT=
CLEANUP_FILES=()

function cleanup() {
  if [[ ${#CLEANUP_FILES[@]} -gt 0 ]]; then
    rm -f "${CLEANUP_FILES[@]}"
  fi
}

trap cleanup EXIT

function parse_option() {
  local -r opt="$1"
  if [[ ${OUTPUT} == "1" ]]; then
    OUTPUT=${opt}
  elif [[ ${opt} =~ ^-l(.*)$ ]]; then
    LIBS="${BASH_REMATCH[1]} ${LIBS}"
  elif [[ ${opt} =~ ^-L(.*)$ ]]; then
    LIB_DIRS="${BASH_REMATCH[1]} ${LIB_DIRS}"
  elif [[ ${opt} =~ ^\@loader_path/(.*)$ ]]; then
    RPATHS="${BASH_REMATCH[1]} ${RPATHS}"
  elif [[ ${opt} =~ ^-Wl,-rpath,\@loader_path/(.*)$ ]]; then
    RPATHS="${BASH_REMATCH[1]} ${RPATHS}"
  elif [[ ${opt} == "-o" ]]; then
    # output is coming
    OUTPUT=1
  fi
}

# See note in toolchain/internal/configure.bzl where we define
# `wrapper_bin_prefix` for why this wrapper is needed.

# this script is located at either
# - <execroot>/external/<repo_name>/bin/cc_wrapper.sh
# - <runfiles>/<repo_name>/bin/cc_wrapper.sh
# The clang is located at
# - <execroot>/external/<repo_name2>/bin/clang
# - <runfiles>/<repo_name2>/bin/clang
#
# In both cases, getting to clang can be done via
# Finding the current dir of this script,
# - <execroot>/external/<repo_name>/bin/
# - <runfiles>/<repo_name>/bin/
# going back 2 directories
# - <execroot>/external
# - <runfiles>
#
# Going into %{toolchain_path_prefix} without the `external/` prefix + `bin/clang`
#

dirname_shim() {
  local path="$1"

  # Remove trailing slashes
  path="${path%/}"

  # If there's no slash, return "."
  if [[ "${path}" != */* ]]; then
    echo "."
    return
  fi

  # Remove the last component after the final slash
  path="${path%/*}"

  # If it becomes empty, it means root "/"
  echo "${path:-/}"
}

script_dir=$(dirname_shim "${BASH_SOURCE[0]}")
toolchain_path_prefix="%{toolchain_path_prefix}"
# Sometimes this path may be an absolute path in which case we dont do anything because
# This is using the host toolchain to build.
if [[ ${toolchain_path_prefix} != /* ]]; then
  toolchain_path_prefix="${script_dir}/../../${toolchain_path_prefix#external/}"
  toolchain_path_prefix_abs="$(cd "${toolchain_path_prefix}" && pwd -P)/"
else
  toolchain_path_prefix_abs="${toolchain_path_prefix}"
fi

if [[ ! -f ${toolchain_path_prefix}bin/clang ]]; then
  echo >&2 "ERROR: could not find clang; PWD=\"${PWD}\"; PATH=\"${PATH}\"; toolchain_path_prefix=${toolchain_path_prefix}."
  exit 5
fi

function sanitize_option() {
  local -r opt=$1
  if [[ ${opt} == */cc_wrapper.sh ]]; then
    printf "%s" "${toolchain_path_prefix}bin/clang"
  elif [[ ${opt} == "-fuse-ld=ld64.lld" ]]; then
    echo "--ld-path=${toolchain_path_prefix_abs}bin/ld64.lld"
  elif [[ ${opt} =~ ^-fsanitize-(ignore|black)list=[^/] ]] && [[ ${script_dir} == /* ]]; then
    # shellcheck disable=SC2206
    parts=(${opt/=/ }) # Split flag name and value into array.
    printf "%s" "${parts[0]}=${script_dir}/../../../${parts[1]}"
  else
    printf "%s" "${opt}"
  fi
}

cmd=()
for ((i = 0; i <= $#; i++)); do
  if [[ ${!i} == @* && -r "${i:1}" ]]; then
    tmpfile=$(mktemp)
    CLEANUP_FILES+=("${tmpfile}")
    while IFS= read -r opt; do
      if [[ ${opt} == "-fuse-ld=ld64.lld" ]]; then
        echo "-fuse-ld=lld" >>"${tmpfile}"
      fi
      opt="$(
        set -e
        sanitize_option "${opt}"
      )"
      parse_option "${opt}" >>"${tmpfile}"
    done <"${!i:1}"
    cmd+=("@${tmpfile}")
  else
    opt="$(
      set -e
      sanitize_option "${!i}"
    )"
    parse_option "${opt}"
    cmd+=("${opt}")
  fi
done

# On macOS, we use ld as the linker for single-platform builds (i.e., when not
# cross-compiling). Some applications may remove /usr/bin from PATH before
# calling this script, which would make /usr/bin/ld unreachable.  For example,
# rules_rust does not set PATH (unless the user explicitly sets PATH in env
# through attributes) [1] when calling rustc, and rustc does not replace an
# unset PATH with a reasonable default either ([2], [3]), which results in CC
# being called with PATH={sysroot}/{rust_lib}/bin. Note that rules_cc [4] and
# rules_go [5] do ensure that /usr/bin is in PATH.
# [1]: https://github.com/bazelbuild/rules_rust/blob/e589105b4e8181dd1d0d8ccaa0cf3267efb06e86/cargo/cargo_build_script.bzl#L66-L68
# [2]: https://github.com/rust-lang/rust/blob/1c03f0d0ba4fee54b7aa458f4d3ad989d8bf7b34/compiler/rustc_session/src/session.rs#L804-L813
# [3]: https://github.com/rust-lang/rust/blob/1c03f0d0ba4fee54b7aa458f4d3ad989d8bf7b34/compiler/rustc_codegen_ssa/src/back/link.rs#L640-L645
# [4]: https://cs.opensource.google/bazel/bazel/+/master:src/main/java/com/google/devtools/build/lib/bazel/rules/BazelRuleClassProvider.java;l=529;drc=72caead7b428fd50164079956ec368fc54a9567c
# [5]: https://github.com/bazelbuild/rules_go/blob/63dfd99403076331fef0775d52a8039d502d4115/go/private/context.bzl#L434
# Let's restore /usr/bin to PATH in such cases. Note that /usr/bin is not a
# writeable directory on macOS even with sudo privileges, so it should be safe
# to add it to PATH even when the application wants to use a very strict PATH.
if [[ ":${PATH}:" != *":/usr/bin:"* ]]; then
  PATH="${PATH}:/usr/bin"
fi

# Call the C++ compiler.
"${cmd[@]}"

# Generate an empty file if header processing succeeded.
if [[ "${OUTPUT}" == *.h.processed ]]; then
  echo -n >"${OUTPUT}"
fi

function get_library_path() {
  for libdir in ${LIB_DIRS}; do
    if [[ -f "${libdir}/lib$1".so ]]; then
      echo "${libdir}/lib$1.so"
    elif [[ -f "${libdir}"/lib"$1".dylib ]]; then
      echo "${libdir}/lib$1.dylib"
    fi
  done
}

# A convenient method to return the actual path even for non symlinks
# and multi-level symlinks.
function get_realpath() {
  local previous="$1"
  local next
  next="$(readlink "${previous}")"
  while [[ -n ${next} ]]; do
    previous="${next}"
    next=$(readlink "${previous}")
  done
  echo "${previous}"
}

# Get the path of a lib inside a tool
function get_otool_path() {
  # the lib path is the path of the original lib relative to the workspace
  get_realpath "$1" | sed 's|^.*/bazel-out/|bazel-out/|'
}

# Do replacements in the output
for rpath in ${RPATHS}; do
  for lib in ${LIBS}; do
    unset libname
    if [[ -f "$(dirname "${OUTPUT}")/${rpath}/lib${lib}.so" ]]; then
      libname="lib${lib}.so"
    elif [[ -f "$(dirname "${OUTPUT}")/${rpath}/lib${lib}.dylib" ]]; then
      libname="lib${lib}.dylib"
    fi
    # ${libname-} --> return $libname if defined, or undefined otherwise. This is to make
    # this set -e friendly
    if [[ -n ${libname-} ]]; then
      libpath="$(get_library_path "${lib}")"
      if [[ -n ${libpath} ]]; then
        otool_path="$(get_otool_path "${libpath}")"
        "${INSTALL_NAME_TOOL}" -change "${otool_path}" \
          "@loader_path/${rpath}/${libname}" "${OUTPUT}"
      fi
    fi
  done
done
