#!/bin/bash
set -e

# =============================================================================
# MySQL HWPGO (Hardware Profile-Guided Optimization) Build Script
#
# Multi-phase build process:
#   Phase 1: Build ICX base with -fprofile-sample-generate
#   Phase 2: Profile ICX base, generate freq + mispredict profiles
#   Phase 3: Build ICX MIR base with freq + mispredict profiles
#   Phase 4: Profile ICX MIR base, generate MIR profile + call graph
#   Phase 5: Build final ICX MIR HWPGO with all profiles + call graph
#
# Usage:
#   ./build_mysql_icx_hwpgo.sh phase1
#   ./build_mysql_icx_hwpgo.sh phase2
#   ./build_mysql_icx_hwpgo.sh phase3
#   ./build_mysql_icx_hwpgo.sh phase4
#   ./build_mysql_icx_hwpgo.sh phase5
#   ./build_mysql_icx_hwpgo.sh all
# =============================================================================

# Load Intel oneAPI environment
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

# --- Configuration ---
SRCDIR=/home/shuchen1/workspace/mysql/mysql-server
BOOSTDIR=/home/shuchen1/workspace/mysql/boost
PROFILE_DIR=/home/shuchen1/workspace/mysql/hwpgo_profiles
DATADIR=/home/shuchen1/workspace/mysql/data_hwpgo_training
HAMMERDB=/home/shuchen1/workspace/mysql/HammerDB-5.0
ARCH_FLAGS="-xGRANITERAPIDS"
ONEAPI_LIB="/opt/intel/oneapi/compiler/latest/lib;/opt/intel/oneapi/latest/lib"

# Phase 1: ICX Base
BUILDDIR_PHASE1=$SRCDIR/build_icx_gnr_lto_hwpgo_phase1
INSTALLDIR_PHASE1=/home/shuchen1/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo_phase1

# Phase 3: MIR Base
BUILDDIR_PHASE3=$SRCDIR/build_icx_gnr_lto_hwpgo_mir
INSTALLDIR_PHASE3=/home/shuchen1/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo_mir

# Phase 5: Final HWPGO
BUILDDIR_PHASE5=$SRCDIR/build_icx_gnr_lto_hwpgo_final
INSTALLDIR_FINAL=/home/shuchen1/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo

SOCKET=/tmp/mysql_hwpgo.sock
PORT=3308

# Training workload parameters
# These should match (or exceed) the benchmark settings so that
# the collected profiles reflect the same hot code paths.
WAREHOUSES=60
VU_BUILD=16
VU_TEST=60
RAMPUP=1
DURATION=3

# Perf sampling period
SAMPLE_PERIOD=1000003

# Tools
LLVM_PROFGEN=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-profgen

NPROC=50

# =============================================================================
usage() {
    echo "Usage: $0 {phase1|phase2|phase3|phase4|phase5|all}"
    echo ""
    echo "  phase1  Build ICX base with -fprofile-sample-generate"
    echo "  phase2  Profile ICX base, generate freq + mispredict profiles"
    echo "  phase3  Build ICX MIR base with freq + mispredict profiles"
    echo "  phase4  Profile ICX MIR base, generate MIR profile + call graph"
    echo "  phase5  Build final ICX MIR HWPGO with all profiles + call graph"
    echo "  all     Run all phases sequentially"
    exit 1
}

# =============================================================================
# Helper functions
# =============================================================================

# Start mysqld and wait for it to be ready.
# Sets global MYSQLD_PID.
# Usage: start_mysqld <basedir>
start_mysqld() {
    local BASEDIR=$1
    local MYSQLD_BIN=$BASEDIR/bin/mysqld

    # Make libmysqlclient.so.24 available to HammerDB's Tcl MySQL driver
    export LD_LIBRARY_PATH=$BASEDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    if [ -S "$SOCKET" ]; then
        $BASEDIR/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
        sleep 2
    fi

    $MYSQLD_BIN \
        --basedir=$BASEDIR \
        --datadir=$DATADIR \
        --socket=$SOCKET \
        --port=$PORT \
        --innodb-buffer-pool-size=8G \
        --innodb-redo-log-capacity=2G \
        --innodb-flush-method=O_DIRECT \
        --innodb-flush-log-at-trx-commit=1 \
        --max-connections=256 \
        --table-open-cache=4000 &
    MYSQLD_PID=$!

    echo "  Waiting for server to start..."
    for i in $(seq 1 60); do
        if $BASEDIR/bin/mysqladmin -u root --socket=$SOCKET ping 2>/dev/null | grep -q alive; then
            echo "  Server is ready (PID: $MYSQLD_PID)."
            return 0
        fi
        if [ $i -eq 60 ]; then
            echo "ERROR: MySQL server failed to start within 60s"
            exit 1
        fi
        sleep 1
    done
}

# Create benchmark user and build TPC-C schema.
# Usage: setup_benchmark <basedir>
setup_benchmark() {
    local BASEDIR=$1

    echo "  Creating benchmark user..."
    $BASEDIR/bin/mysql -u root --socket=$SOCKET -e "
    CREATE USER IF NOT EXISTS 'hammerdb'@'localhost' IDENTIFIED BY 'hammerdb';
    GRANT ALL PRIVILEGES ON *.* TO 'hammerdb'@'localhost';
    FLUSH PRIVILEGES;
    "

    echo "  Building TPC-C schema ($WAREHOUSES warehouses)..."
    cat > /tmp/hammerdb_hwpgo_build.tcl << EOF
dbset db mysql
diset connection mysql_host 127.0.0.1
diset connection mysql_port $PORT
diset connection mysql_socket $SOCKET
diset tpcc mysql_user hammerdb
diset tpcc mysql_pass hammerdb
diset tpcc mysql_dbase tpcc
diset tpcc mysql_num_vu $VU_BUILD
diset tpcc mysql_count_ware $WAREHOUSES
diset tpcc mysql_storage_engine innodb
buildschema
EOF

    cd $HAMMERDB
    ./hammerdbcli auto /tmp/hammerdb_hwpgo_build.tcl
}

# Run TPC-C training workload.
run_workload() {
    echo "  Running TPC-C training workload (${RAMPUP}min ramp + ${DURATION}min run)..."

    cat > /tmp/hammerdb_hwpgo_run.tcl << EOF
dbset db mysql
diset connection mysql_host 127.0.0.1
diset connection mysql_port $PORT
diset connection mysql_socket $SOCKET
diset tpcc mysql_user hammerdb
diset tpcc mysql_pass hammerdb
diset tpcc mysql_dbase tpcc
diset tpcc mysql_driver timed
diset tpcc mysql_rampup $RAMPUP
diset tpcc mysql_duration $DURATION
vuset vu $VU_TEST
vucreate
vurun
vudestroy
EOF

    cd $HAMMERDB
    ./hammerdbcli auto /tmp/hammerdb_hwpgo_run.tcl
}

# Shutdown mysqld and wait for it to exit.
# Usage: stop_mysqld <basedir>
stop_mysqld() {
    local BASEDIR=$1

    echo "  Shutting down MySQL..."
    $BASEDIR/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
    wait $MYSQLD_PID 2>/dev/null || true
}

# =============================================================================
# Phase 1: Build ICX base with -fprofile-sample-generate
# =============================================================================
run_phase1() {
    echo "=============================="
    echo "Phase 1: Building ICX base with -fprofile-sample-generate"
    echo "=============================="

    mkdir -p "$BUILDDIR_PHASE1"
    cd "$BUILDDIR_PHASE1"

    if [ ! -f "$BUILDDIR_PHASE1/Makefile" ]; then
        cmake \
            -DCMAKE_C_COMPILER=icx \
            -DCMAKE_CXX_COMPILER=icpx \
            -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
            -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
            -DCMAKE_C_FLAGS="-O3 $ARCH_FLAGS -fprofile-sample-generate" \
            -DCMAKE_CXX_FLAGS="-O3 $ARCH_FLAGS -fprofile-sample-generate" \
            -DCMAKE_INSTALL_PREFIX="$INSTALLDIR_PHASE1" \
            -DCMAKE_BUILD_RPATH="$ONEAPI_LIB" \
            -DCMAKE_INSTALL_RPATH="$ONEAPI_LIB" \
            -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
            -DSYSCONFDIR="$INSTALLDIR_PHASE1/etc" \
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

    make -j${NPROC}
    make install

    echo ""
    echo "Phase 1 complete: $INSTALLDIR_PHASE1/bin/mysqld"
}

# =============================================================================
# Phase 2: Profile ICX base, generate freq + mispredict profiles
# =============================================================================
run_phase2() {
    echo "=============================="
    echo "Phase 2: Profiling ICX base"
    echo "=============================="

    local BASEDIR=$INSTALLDIR_PHASE1
    local MYSQLD_BIN=$BASEDIR/bin/mysqld

    if [ ! -x "$MYSQLD_BIN" ]; then
        echo "ERROR: Phase 1 build not found at $MYSQLD_BIN"
        echo "       Run '$0 phase1' first."
        exit 1
    fi

    mkdir -p "$PROFILE_DIR"

    # --- Initialize data directory ---
    if [ ! -d "$DATADIR" ]; then
        echo "  Initializing data directory..."
        $MYSQLD_BIN \
            --initialize-insecure \
            --basedir=$BASEDIR \
            --datadir=$DATADIR
    fi

    # --- Start mysqld ---
    echo "  Starting MySQL server..."
    start_mysqld $BASEDIR

    # --- Setup benchmark ---
    setup_benchmark $BASEDIR

    # --- Start perf recording (attached to mysqld PID) ---
    echo "  Starting perf record (PID: $MYSQLD_PID)..."
    perf record -b \
        -e branches:u,branch-misses:u \
        -c $SAMPLE_PERIOD \
        -p $MYSQLD_PID \
        -o $PROFILE_DIR/mysql_freq_unpred.perf.data &
    PERF_PID=$!

    # --- Run training workload ---
    run_workload

    # --- Stop perf and mysqld ---
    echo "  Stopping perf..."
    kill -INT $PERF_PID 2>/dev/null || true
    wait $PERF_PID 2>/dev/null || true

    stop_mysqld $BASEDIR

    echo "  Perf data collected:"
    ls -lh $PROFILE_DIR/mysql_freq_unpred.perf.data

    # --- Convert perf data to LLVM profiles ---
    echo ""
    echo "  Generating execution frequency profile..."
    $LLVM_PROFGEN \
        --format text \
        --output=$PROFILE_DIR/mysqld.freq.prof \
        --binary=$MYSQLD_BIN \
        --sample-period=$SAMPLE_PERIOD \
        --perf-event=branches:u \
        --perfdata=$PROFILE_DIR/mysql_freq_unpred.perf.data

    echo "  Generating branch mispredict profile..."
    $LLVM_PROFGEN \
        --format text \
        --output=$PROFILE_DIR/mysqld.misp.prof \
        --binary=$MYSQLD_BIN \
        --sample-period=$SAMPLE_PERIOD \
        --perf-event=branch-misses:u \
        --leading-ip-only \
        --perfdata=$PROFILE_DIR/mysql_freq_unpred.perf.data

    echo ""
    echo "  Profiles generated:"
    ls -lh $PROFILE_DIR/mysqld.freq.prof
    ls -lh $PROFILE_DIR/mysqld.misp.prof
    echo ""
    echo "Phase 2 complete."
}

# =============================================================================
# Phase 3: Build ICX MIR base with freq + mispredict profiles
# =============================================================================
run_phase3() {
    echo "=============================="
    echo "Phase 3: Building ICX MIR base"
    echo "=============================="

    if [ ! -f "$PROFILE_DIR/mysqld.freq.prof" ]; then
        echo "ERROR: Frequency profile not found at $PROFILE_DIR/mysqld.freq.prof"
        echo "       Run '$0 phase2' first."
        exit 1
    fi

    if [ ! -f "$PROFILE_DIR/mysqld.misp.prof" ]; then
        echo "ERROR: Mispredict profile not found at $PROFILE_DIR/mysqld.misp.prof"
        echo "       Run '$0 phase2' first."
        exit 1
    fi

    PHASE3_FLAGS="-O3 $ARCH_FLAGS -flto"
    PHASE3_FLAGS+=" -fprofile-sample-use=$PROFILE_DIR/mysqld.freq.prof"
    PHASE3_FLAGS+=" -mllvm -unpredictable-hints-file=$PROFILE_DIR/mysqld.misp.prof"
    PHASE3_FLAGS+=" -mllvm -machine-pseudo-probe-for-profiling=pre-ra"

    mkdir -p "$BUILDDIR_PHASE3"
    cd "$BUILDDIR_PHASE3"

    if [ ! -f "$BUILDDIR_PHASE3/Makefile" ]; then
        cmake \
            -DCMAKE_C_COMPILER=icx \
            -DCMAKE_CXX_COMPILER=icpx \
            -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
            -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
            -DCMAKE_C_FLAGS="$PHASE3_FLAGS" \
            -DCMAKE_CXX_FLAGS="$PHASE3_FLAGS" \
            -DCMAKE_INSTALL_PREFIX="$INSTALLDIR_PHASE3" \
            -DCMAKE_BUILD_RPATH="$ONEAPI_LIB" \
            -DCMAKE_INSTALL_RPATH="$ONEAPI_LIB" \
            -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
            -DSYSCONFDIR="$INSTALLDIR_PHASE3/etc" \
            -DWITH_BOOST="$BOOSTDIR" \
            -DDOWNLOAD_BOOST=1 \
            -DWITH_INNODB_MEMCACHED=ON \
            -DWITH_NUMA=ON \
            -DENABLED_LOCAL_INFILE=ON \
            -DFORCE_INSOURCE_BUILD=OFF \
            -DFORCE_UNSUPPORTED_COMPILER=ON \
            -DCMAKE_CXX_STANDARD=20 \
            -DCMAKE_CXX_STANDARD_REQUIRED=ON \
            -DWITH_LD=lld \
            -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
            -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
            -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
            ..
    fi

    make -j${NPROC}
    make install

    echo ""
    echo "Phase 3 complete: $INSTALLDIR_PHASE3/bin/mysqld"
}

# =============================================================================
# Phase 4: Profile ICX MIR base, generate MIR profile + call graph
# =============================================================================
run_phase4() {
    echo "=============================="
    echo "Phase 4: Profiling ICX MIR base"
    echo "=============================="

    local BASEDIR=$INSTALLDIR_PHASE3
    local MYSQLD_BIN=$BASEDIR/bin/mysqld

    if [ ! -x "$MYSQLD_BIN" ]; then
        echo "ERROR: Phase 3 MIR build not found at $MYSQLD_BIN"
        echo "       Run '$0 phase3' first."
        exit 1
    fi

    mkdir -p "$PROFILE_DIR"

    # --- Initialize data directory (if not already done in phase 2) ---
    if [ ! -d "$DATADIR" ]; then
        echo "  Initializing data directory..."
        $MYSQLD_BIN \
            --initialize-insecure \
            --basedir=$BASEDIR \
            --datadir=$DATADIR
    fi

    # --- Start mysqld ---
    echo "  Starting MySQL server (MIR build)..."
    start_mysqld $BASEDIR

    # --- Setup benchmark ---
    setup_benchmark $BASEDIR

    # --- Start perf recording (freq event only) ---
    echo "  Starting perf record (PID: $MYSQLD_PID)..."
    perf record -b \
        -e branches:u \
        -c $SAMPLE_PERIOD \
        -p $MYSQLD_PID \
        -o $PROFILE_DIR/mysql_mir.perf.data &
    PERF_PID=$!

    # --- Run training workload ---
    run_workload

    # --- Stop perf and mysqld ---
    echo "  Stopping perf..."
    kill -INT $PERF_PID 2>/dev/null || true
    wait $PERF_PID 2>/dev/null || true

    stop_mysqld $BASEDIR

    echo "  Perf data collected:"
    ls -lh $PROFILE_DIR/mysql_mir.perf.data

    # --- Generate MIR profile + call graph ---
    echo ""
    echo "  Generating MIR profile and call graph..."
    $LLVM_PROFGEN \
        --format text \
        --output=$PROFILE_DIR/mysqld.mir.prof \
        --binary=$MYSQLD_BIN \
        --perf-event=branches:u \
        --perfdata=$PROFILE_DIR/mysql_mir.perf.data \
        --call-graph-output=$PROFILE_DIR/mysql.mir.cg

    echo ""
    echo "  Profiles generated:"
    ls -lh $PROFILE_DIR/mysqld.mir.prof
    ls -lh $PROFILE_DIR/mysql.mir.cg
    echo ""
    echo "Phase 4 complete."
}

# =============================================================================
# Phase 5: Build final ICX MIR HWPGO with all profiles + call graph
# =============================================================================
run_phase5() {
    echo "=============================="
    echo "Phase 5: Building final ICX MIR HWPGO"
    echo "=============================="

    for PROF in mysqld.freq.prof mysqld.misp.prof mysqld.mir.prof mysql.mir.cg; do
        if [ ! -f "$PROFILE_DIR/$PROF" ]; then
            echo "ERROR: Profile not found at $PROFILE_DIR/$PROF"
            echo "       Run earlier phases first."
            exit 1
        fi
    done

    PHASE5_FLAGS="-O3 $ARCH_FLAGS -flto"
    PHASE5_FLAGS+=" -fprofile-sample-use=$PROFILE_DIR/mysqld.freq.prof"
    PHASE5_FLAGS+=" -mllvm -unpredictable-hints-file=$PROFILE_DIR/mysqld.misp.prof"
    PHASE5_FLAGS+=" -mllvm -machine-pseudo-probe-for-profiling=pre-ra"
    PHASE5_FLAGS+=" -mllvm -machine-sample-profile-file=$PROFILE_DIR/mysqld.mir.prof"
    PHASE5_FLAGS+=" -ffunction-sections"
    PHASE5_FLAGS+=" -Wl,--call-graph-ordering-file=$PROFILE_DIR/mysql.mir.cg"
    PHASE5_FLAGS+=" -Wl,--no-warn-symbol-ordering"

    mkdir -p "$BUILDDIR_PHASE5"
    cd "$BUILDDIR_PHASE5"

    if [ ! -f "$BUILDDIR_PHASE5/Makefile" ]; then
        cmake \
            -DCMAKE_C_COMPILER=icx \
            -DCMAKE_CXX_COMPILER=icpx \
            -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
            -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
            -DCMAKE_C_FLAGS="$PHASE5_FLAGS" \
            -DCMAKE_CXX_FLAGS="$PHASE5_FLAGS" \
            -DCMAKE_INSTALL_PREFIX="$INSTALLDIR_FINAL" \
            -DCMAKE_BUILD_RPATH="$ONEAPI_LIB" \
            -DCMAKE_INSTALL_RPATH="$ONEAPI_LIB" \
            -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
            -DSYSCONFDIR="$INSTALLDIR_FINAL/etc" \
            -DWITH_BOOST="$BOOSTDIR" \
            -DDOWNLOAD_BOOST=1 \
            -DWITH_INNODB_MEMCACHED=ON \
            -DWITH_NUMA=ON \
            -DENABLED_LOCAL_INFILE=ON \
            -DFORCE_INSOURCE_BUILD=OFF \
            -DFORCE_UNSUPPORTED_COMPILER=ON \
            -DCMAKE_CXX_STANDARD=20 \
            -DCMAKE_CXX_STANDARD_REQUIRED=ON \
            -DWITH_LD=lld \
            -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
            -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
            -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
            ..
    fi

    make -j${NPROC}
    make install

    echo ""
    echo "=============================="
    echo "HWPGO build complete!"
    echo "=============================="
    echo "  Installation: $INSTALLDIR_FINAL"
    echo "  Profiles used:"
    echo "    Frequency:    $PROFILE_DIR/mysqld.freq.prof"
    echo "    Mispredict:   $PROFILE_DIR/mysqld.misp.prof"
    echo "    MIR:          $PROFILE_DIR/mysqld.mir.prof"
    echo "    Call graph:   $PROFILE_DIR/mysql.mir.cg"
}

# =============================================================================
# Main
# =============================================================================
PHASE="${1:-}"

echo "=== MySQL HWPGO Build ==="
echo "  Source:       $SRCDIR"
echo "  Arch:         $ARCH_FLAGS"
echo "  llvm-profgen: $LLVM_PROFGEN"
echo "  Cores:        $NPROC"
echo ""

case "$PHASE" in
    phase1)
        run_phase1
        ;;
    phase2)
        run_phase2
        ;;
    phase3)
        run_phase3
        ;;
    phase4)
        run_phase4
        ;;
    phase5)
        run_phase5
        ;;
    all)
        run_phase1
        echo ""
        run_phase2
        echo ""
        run_phase3
        echo ""
        run_phase4
        echo ""
        run_phase5
        ;;
    *)
        usage
        ;;
esac
