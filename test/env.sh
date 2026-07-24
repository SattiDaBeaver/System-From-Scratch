#!/bin/sh
# test/env.sh
#
# This host's only system compiler (gcc 4.8.5) is too old to build the
# Verilator/cocotb C++ runtime (needs C++14+), and the pip-installed
# verilator wheel doesn't carry a matching precompiled binary for this
# glibc/libstdc++. Source this before `make` in test/ to point the build
# at a pre-existing newer toolchain instead (no sudo/system changes):
#   source env.sh && make ...
#
# Also patches two Verilator-Makefile gaps that only show up with a
# non-default CXX: CFG_CXXFLAGS_PCH_I is normally set by Verilator's
# ./configure to "-include" (GCC's flag for injecting a precompiled
# header); the wheel ships that blank for its own bundled compiler.
# CFG_LDLIBS_THREADS is similarly blank, but glibc's pthread symbols used
# by verilated_threads.cpp need an explicit -lpthread on the link line.

export PATH=/pkg/qct/software/gnu64/gcc/11.3.0/bin:/pkg/qct/software/sifive/gcc/centos/8.3.0/bin:/usr2/stalukda/Github/System-From-Scratch/.venv/bin:$PATH
export LD_LIBRARY_PATH=/pkg/qct/software/gnu64/gcc/11.3.0/lib64:/pkg/qct/software/python/3.9.7/lib:$LD_LIBRARY_PATH
export CXX=/pkg/qct/software/gnu64/gcc/11.3.0/bin/g++
export CC=/pkg/qct/software/gnu64/gcc/11.3.0/bin/gcc
export MAKEFLAGS="CFG_CXXFLAGS_PCH_I=-include CFG_LDLIBS_THREADS=-lpthread"

