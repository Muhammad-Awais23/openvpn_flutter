#!/bin/bash

# NDK path (apna path set karo)
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/27.2.12479018

# Temporary build folder
BUILD_DIR="/tmp/openvpn_build"
mkdir -p $BUILD_DIR
cd $BUILD_DIR

# OpenVPN source download
git clone https://github.com/OpenVPN/openvpn.git
cd openvpn
git checkout release/2.6

# ARM64 compile
./configure \
  --host=aarch64-linux-android \
  --enable-shared \
  LDFLAGS="-Wl,-z,max-page-size=16384" \
  CC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang

make clean
make -j8

# Copy libraries
echo "ARM64 libraries:"
find . -name "*.so"

