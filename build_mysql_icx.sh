#!/bin/bash
set -e

# Load Intel oneAPI environment
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

# --- Configuration ---
SRCDIR=/home/shuchen1/workspace/mysql/mysql-server
BUILDDIR=$SRCDIR/build_icx_gnr_lto
INSTALLDIR=/home/shuchen1/workspace/mysql/installation/mysql_icx_gnr_lto
BOOSTDIR=/home/shuchen1/workspace/mysql/boost
ARCH_FLAGS="-xGRANITERAPIDS"
ONEAPI_LIB="/opt/intel/oneapi/compiler/latest/lib;/opt/intel/oneapi/latest/lib"

NPROC=50

echo "=== MySQL ICX Build ==="
echo "  Source:  $SRCDIR"
echo "  Build:   $BUILDDIR"
echo "  Install: $INSTALLDIR"
echo "  Arch:    $ARCH_FLAGS"
echo "  Cores:   $NPROC"
echo ""

mkdir -p "$BUILDDIR"
cd "$BUILDDIR"

if [ ! -f "$BUILDDIR/Makefile" ]; then
    echo "Running cmake..."
    cmake \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
        -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
        -DCMAKE_C_FLAGS="-O3 $ARCH_FLAGS" \
        -DCMAKE_CXX_FLAGS="-O3 $ARCH_FLAGS" \
        -DCMAKE_INSTALL_PREFIX="$INSTALLDIR" \
        -DCMAKE_BUILD_RPATH="$ONEAPI_LIB" \
        -DCMAKE_INSTALL_RPATH="$ONEAPI_LIB" \
        -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
        -DSYSCONFDIR="$INSTALLDIR/etc" \
        -DWITH_BOOST="$BOOSTDIR" \
        -DDOWNLOAD_BOOST=1 \
        -DWITH_INNODB_MEMCACHED=ON \
        -DWITH_NUMA=ON \
        -DENABLED_LOCAL_INFILE=ON \
        -DFORCE_INSOURCE_BUILD=OFF \
        -DFORCE_UNSUPPORTED_COMPILER=ON \
        -DCMAKE_CXX_STANDARD=20 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DWITH_LTO=1 \
        -DWITH_LD=lld \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
        ..
fi

echo "Building..."
make -j${NPROC}

echo "Installing..."
make install

echo ""
echo "=== Build complete ==="
echo "  Installation: $INSTALLDIR"
