#!/bin/bash
# test/run_sim.sh
#
# Wraps `make` with the compiler overrides needed to build verilator's
# generated C++ on this host: the system g++ (4.8.5) is too old (no C++14),
# so we use clang++ 10.0.0 + libc++ instead. Several verilator PCH
# (precompiled header) make variables also need overriding because the
# `verilator` PyPI wheel was built assuming GCC-style PCH handling, which
# doesn't match clang's -include/-x c++-header flags.
#
# Usage: ./run_sim.sh [make args, e.g. MODULE=testbench.test_basic]

set -e
cd "$(dirname "$0")"

CLANG_ROOT=/pkg/qct/software/llvm/10.0.0
export LD_LIBRARY_PATH="$CLANG_ROOT/lib:$LD_LIBRARY_PATH"

make \
  CXX="$CLANG_ROOT/bin/clang++" \
  CC="$CLANG_ROOT/bin/clang" \
  LINK="$CLANG_ROOT/bin/clang++" \
  CXXFLAGS="-std=c++17 -stdlib=libc++" \
  LDFLAGS="-stdlib=libc++ -L$CLANG_ROOT/lib -lpthread" \
  VK_PCH_I_FAST= VK_PCH_I_SLOW= \
  "$@"
