#!/bin/bash
set -e

# Load Intel oneAPI environment
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

# --- Configuration ---
SRCDIR=/home/shuchen1/mysql/mysql-server
BUILDDIR=$SRCDIR/build_icx_gnr_lto
INSTALLDIR=/home/shuchen1/mysql/installation/mysql_icx_gnr_lto
ARCH_FLAGS="-xGRANITERAPIDS"

NPROC=50

echo "=== MySQL ICX Build ==="
echo "  Source:  $SRCDIR"
echo "  Build:   $BUILDDIR"
echo "  Install: $INSTALLDIR"
echo "  Arch:    $ARCH_FLAGS"
echo "  Cores:   $NPROC"
echo ""

mkdir -p $BUILDDIR
cd $BUILDDIR

if [ ! -f "$BUILDDIR/Makefile" ]; then
    echo "Running cmake..."
    CC=icx CXX=icpx cmake \
        -DCMAKE_CXX_FLAGS="$ARCH_FLAGS" \
        -DCMAKE_C_FLAGS="$ARCH_FLAGS" \
        -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
        -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
        -DWITH_LD=lld \
        -DWITH_LTO=1 \
        -DBUILD_CONFIG=mysql_release \
        -DCMAKE_BUILD_TYPE=Release \
        ..
fi

echo "Building..."
make -j${NPROC}

echo "Installing..."
make install DESTDIR="$INSTALLDIR"

echo ""
echo "=== Build complete ==="
echo "  Installation: $INSTALLDIR/usr/local/mysql"
