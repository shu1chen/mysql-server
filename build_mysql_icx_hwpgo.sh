#!/bin/bash
set -e

# =============================================================================
# MySQL HWPGO (Hardware Profile-Guided Optimization) Build Script
#
# Usage:
#   ./build_mysql_icx_hwpgo.sh phase1       # Build with -fprofile-sample-generate
#   ./build_mysql_icx_hwpgo.sh phase2       # Collect profile via perf + HammerDB, then convert
#   ./build_mysql_icx_hwpgo.sh phase3       # Rebuild with -fprofile-sample-use
#   ./build_mysql_icx_hwpgo.sh all          # Run all phases sequentially
# =============================================================================

# Load Intel oneAPI environment
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

# --- Configuration (edit these to adapt) ---
SRCDIR=/home/shuchen1/mysql/mysql-server
BUILDDIR_PHASE1=$SRCDIR/build_icx_gnr_lto_hwpgo_phase1
BUILDDIR_PHASE3=$SRCDIR/build_icx_gnr_lto_hwpgo_phase3
INSTALLDIR_PHASE1=/home/shuchen1/mysql/installation/mysql_icx_gnr_lto_hwpgo_phase1
INSTALLDIR_FINAL=/home/shuchen1/mysql/installation/mysql_icx_gnr_lto_hwpgo
DATADIR=/home/shuchen1/mysql/data_hwpgo_training
PROFILE_DIR=/home/shuchen1/mysql/hwpgo_profiles
HAMMERDB=/home/shuchen1/mysql/HammerDB-5.0
ARCH_FLAGS="-xGRANITERAPIDS"

SOCKET=/tmp/mysql_hwpgo.sock
PORT=3308

# Training workload parameters
WAREHOUSES=16
VU_BUILD=16
VU_TEST=16
RAMPUP=1
DURATION=3

# Perf sampling period
SAMPLE_PERIOD=1000003

# Tools
LLVM_PROFGEN=$(icx --print-prog-name=llvm-profgen)
LLVM_PROFDATA=$(icx --print-prog-name=llvm-profdata)

NPROC=50

BASEDIR_P1=$INSTALLDIR_PHASE1/usr/local/mysql
MYSQLD_P1=$BASEDIR_P1/bin/mysqld

# =============================================================================
usage() {
    echo "Usage: $0 {phase1|phase2|phase3|all}"
    echo ""
    echo "  phase1  Build MySQL with -fprofile-sample-generate"
    echo "  phase2  Collect hardware profile (perf + HammerDB) and convert to LLVM profiles"
    echo "  phase3  Rebuild MySQL with -fprofile-sample-use"
    echo "  all     Run all phases sequentially"
    exit 1
}

# =============================================================================
# Phase 1: Build with -fprofile-sample-generate
# =============================================================================
run_phase1() {
    echo "=============================="
    echo "Phase 1: Building MySQL with -fprofile-sample-generate"
    echo "=============================="

    mkdir -p $BUILDDIR_PHASE1
    cd $BUILDDIR_PHASE1

    if [ ! -f "$BUILDDIR_PHASE1/Makefile" ]; then
        CC=icx CXX=icpx cmake \
            -DCMAKE_CXX_FLAGS="$ARCH_FLAGS -fprofile-sample-generate" \
            -DCMAKE_C_FLAGS="$ARCH_FLAGS -fprofile-sample-generate" \
            -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
            -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
            -DWITH_LD=lld \
            -DWITH_LTO=1 \
            -DBUILD_CONFIG=mysql_release \
            -DCMAKE_BUILD_TYPE=Release \
            ..
    fi

    make -j${NPROC}
    make install DESTDIR="$INSTALLDIR_PHASE1"

    echo ""
    echo "Phase 1 complete: $MYSQLD_P1"
}

# =============================================================================
# Phase 2: Collect hardware profile with perf + convert to LLVM profiles
# =============================================================================
run_phase2() {
    echo "=============================="
    echo "Phase 2: Collecting hardware profile via perf + HammerDB"
    echo "=============================="

    if [ ! -x "$MYSQLD_P1" ]; then
        echo "ERROR: Phase 1 build not found at $MYSQLD_P1"
        echo "       Run '$0 phase1' first."
        exit 1
    fi

    mkdir -p $PROFILE_DIR
    export LD_LIBRARY_PATH=$BASEDIR_P1/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    # --- Initialize data directory ---
    if [ ! -d "$DATADIR" ]; then
        echo "  Initializing data directory..."
        $MYSQLD_P1 \
            --initialize-insecure \
            --basedir=$BASEDIR_P1 \
            --datadir=$DATADIR
    fi

    # --- Start MySQL under perf record ---
    echo "  Starting MySQL server under perf record..."

    if [ -S "$SOCKET" ]; then
        $BASEDIR_P1/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
        sleep 2
    fi

    perf record \
        -o $PROFILE_DIR/mysqld.perf.data \
        -b \
        -c $SAMPLE_PERIOD \
        -e branches,branch-misses \
        -- $MYSQLD_P1 \
            --basedir=$BASEDIR_P1 \
            --datadir=$DATADIR \
            --socket=$SOCKET \
            --port=$PORT \
            --innodb-buffer-pool-size=4G \
            --innodb-redo-log-capacity=2G \
            --innodb-flush-method=O_DIRECT \
            --innodb-flush-log-at-trx-commit=1 \
            --max-connections=256 \
            --table-open-cache=4000 &

    PERF_PID=$!
    echo "  perf record PID: $PERF_PID"

    echo "  Waiting for server to start..."
    for i in $(seq 1 60); do
        if $BASEDIR_P1/bin/mysqladmin -u root --socket=$SOCKET ping 2>/dev/null | grep -q alive; then
            echo "  Server is ready."
            break
        fi
        if [ $i -eq 60 ]; then
            echo "ERROR: MySQL server failed to start within 60s"
            exit 1
        fi
        sleep 1
    done

    # --- Create benchmark user ---
    echo "  Creating benchmark user..."
    $BASEDIR_P1/bin/mysql -u root --socket=$SOCKET -e "
    CREATE USER IF NOT EXISTS 'hammerdb'@'localhost' IDENTIFIED BY 'hammerdb';
    GRANT ALL PRIVILEGES ON *.* TO 'hammerdb'@'localhost';
    FLUSH PRIVILEGES;
    "

    # --- Build TPC-C schema ---
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

    # --- Run TPC-C training workload ---
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

    ./hammerdbcli auto /tmp/hammerdb_hwpgo_run.tcl

    # --- Shutdown MySQL and stop perf ---
    echo "  Shutting down MySQL (perf will stop automatically)..."
    $BASEDIR_P1/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
    wait $PERF_PID 2>/dev/null || true

    echo "  Perf data collected: $PROFILE_DIR/mysqld.perf.data"
    ls -lh $PROFILE_DIR/mysqld.perf.data

    # --- Convert perf data to LLVM profiles ---
    echo ""
    echo "  Converting perf data to LLVM profiles..."

    echo "  Generating execution frequency profile..."
    $LLVM_PROFGEN \
        --perfdata=$PROFILE_DIR/mysqld.perf.data \
        --binary=$MYSQLD_P1 \
        --output=$PROFILE_DIR/mysqld.freq.prof \
        --sample-period=$SAMPLE_PERIOD \
        --perf-event=branches

    echo "  Generating branch mispredict profile..."
    $LLVM_PROFGEN \
        --perfdata=$PROFILE_DIR/mysqld.perf.data \
        --binary=$MYSQLD_P1 \
        --output=$PROFILE_DIR/mysqld.misp.prof \
        --sample-period=$SAMPLE_PERIOD \
        --perf-event=branch-misses \
        --leading-ip-only

    echo ""
    echo "  Profiles generated:"
    ls -lh $PROFILE_DIR/mysqld.freq.prof
    ls -lh $PROFILE_DIR/mysqld.misp.prof
    echo ""
    echo "Phase 2 complete."
}

# =============================================================================
# Phase 3: Rebuild with -fprofile-sample-use
# =============================================================================
run_phase3() {
    echo "=============================="
    echo "Phase 3: Rebuilding MySQL with -fprofile-sample-use"
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

    mkdir -p $BUILDDIR_PHASE3
    cd $BUILDDIR_PHASE3

    if [ ! -f "$BUILDDIR_PHASE3/Makefile" ]; then
        CC=icx CXX=icpx cmake \
            -DCMAKE_CXX_FLAGS="$ARCH_FLAGS -fprofile-sample-use=$PROFILE_DIR/mysqld.freq.prof -mllvm -unpredictable-hints-file=$PROFILE_DIR/mysqld.misp.prof" \
            -DCMAKE_C_FLAGS="$ARCH_FLAGS -fprofile-sample-use=$PROFILE_DIR/mysqld.freq.prof -mllvm -unpredictable-hints-file=$PROFILE_DIR/mysqld.misp.prof" \
            -DCMAKE_AR=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ar \
            -DCMAKE_RANLIB=/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-ranlib \
            -DWITH_LD=lld \
            -DWITH_LTO=1 \
            -DBUILD_CONFIG=mysql_release \
            -DCMAKE_BUILD_TYPE=Release \
            ..
    fi

    make -j${NPROC}
    make install DESTDIR="$INSTALLDIR_FINAL"

    echo ""
    echo "=============================="
    echo "HWPGO build complete!"
    echo "=============================="
    echo "  Installation: $INSTALLDIR_FINAL/usr/local/mysql"
    echo "  Profiles used:"
    echo "    Frequency:    $PROFILE_DIR/mysqld.freq.prof"
    echo "    Mispredict:   $PROFILE_DIR/mysqld.misp.prof"
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
    all)
        run_phase1
        echo ""
        run_phase2
        echo ""
        run_phase3
        ;;
    *)
        usage
        ;;
esac
