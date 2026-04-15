#!/bin/bash
set -e

# Load Intel oneAPI runtime (provides libsvml.so, libimf.so, etc.)
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

# --- Installation paths (script-specific) ---
BASEDIR=/home/shuchen1/workspace/mysql/installation/mysql_icx_gnr_lto
DATADIR=/home/shuchen1/workspace/mysql/data_icx_gnr_lto
SOCKET=/tmp/mysql_icx.sock
PORT=3307
HAMMERDB=/home/shuchen1/workspace/mysql/HammerDB-5.0
LOG_PREFIX=/tmp/hammerdb_icx

# Make libmysqlclient.so.24 available to HammerDB
export LD_LIBRARY_PATH=$BASEDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# --- Benchmark settings (from env or defaults) ---
CPUS="${BENCH_CPUS:-0-3}"
WAREHOUSES="${BENCH_WAREHOUSES:-60}"
VU_BUILD="${BENCH_VU_BUILD:-16}"
VU_TEST="${BENCH_VU_TEST:-60}"
RAMPUP="${BENCH_RAMPUP:-1}"
DURATION="${BENCH_DURATION:-1}"
RUNS="${BENCH_RUNS:-5}"
BUFFER_POOL="${BENCH_BUFFER_POOL:-8G}"
REDO_LOG="${BENCH_REDO_LOG:-2G}"
FLUSH_METHOD="${BENCH_FLUSH_METHOD:-O_DIRECT}"
FLUSH_LOG_AT_TRX="${BENCH_FLUSH_LOG_AT_TRX:-1}"
MAX_CONNECTIONS="${BENCH_MAX_CONNECTIONS:-256}"
TABLE_OPEN_CACHE="${BENCH_TABLE_OPEN_CACHE:-4000}"

echo "=== MySQL ICX/GNR/LTO HammerDB Benchmark ==="
echo "  BASEDIR: $BASEDIR"
echo "  VU_TEST=$VU_TEST  WAREHOUSES=$WAREHOUSES  RUNS=$RUNS  CPUS=$CPUS"
echo ""

# -------------------------------------------------------
# Step 1: Initialize data directory (skip if already done)
# -------------------------------------------------------
if [ ! -d "$DATADIR" ]; then
    echo "[1/5] Initializing data directory..."
    $BASEDIR/bin/mysqld \
        --initialize-insecure \
        --basedir=$BASEDIR \
        --datadir=$DATADIR
else
    echo "[1/5] Data directory already exists, skipping init."
fi

# -------------------------------------------------------
# Step 2: Start MySQL server
# -------------------------------------------------------
echo "[2/5] Starting MySQL server..."

# Kill any existing instance on this socket/port
if [ -S "$SOCKET" ]; then
    $BASEDIR/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
    sleep 2
fi

taskset -c $CPUS $BASEDIR/bin/mysqld \
    --basedir=$BASEDIR \
    --datadir=$DATADIR \
    --socket=$SOCKET \
    --port=$PORT \
    --innodb-buffer-pool-size=$BUFFER_POOL \
    --innodb-redo-log-capacity=$REDO_LOG \
    --innodb-flush-method=$FLUSH_METHOD \
    --innodb-flush-log-at-trx-commit=$FLUSH_LOG_AT_TRX \
    --max-connections=$MAX_CONNECTIONS \
    --table-open-cache=$TABLE_OPEN_CACHE &

MYSQLD_PID=$!
echo "  mysqld PID: $MYSQLD_PID"

# Wait for server to be ready
echo "  Waiting for server to start..."
for i in $(seq 1 30); do
    if $BASEDIR/bin/mysqladmin -u root --socket=$SOCKET ping 2>/dev/null | grep -q alive; then
        echo "  Server is ready."
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: MySQL server failed to start within 30s"
        exit 1
    fi
    sleep 1
done

# -------------------------------------------------------
# Step 3: Create benchmark user
# -------------------------------------------------------
echo "[3/5] Creating benchmark user..."
$BASEDIR/bin/mysql -u root --socket=$SOCKET -e "
CREATE USER IF NOT EXISTS 'hammerdb'@'localhost' IDENTIFIED BY 'hammerdb';
GRANT ALL PRIVILEGES ON *.* TO 'hammerdb'@'localhost';
FLUSH PRIVILEGES;
"

# -------------------------------------------------------
# Step 4: Build TPC-C schema via HammerDB
# -------------------------------------------------------
echo "[4/5] Building TPC-C schema ($WAREHOUSES warehouses, $VU_BUILD VUs)..."

cat > /tmp/hammerdb_icx_build.tcl << EOF
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
./hammerdbcli auto /tmp/hammerdb_icx_build.tcl

# -------------------------------------------------------
# Step 5: Run TPC-C benchmark (N runs)
# -------------------------------------------------------
echo "[5/5] Running TPC-C benchmark ($RUNS runs, $VU_TEST VUs, ${RAMPUP}min ramp, ${DURATION}min test)..."

cat > /tmp/hammerdb_icx_run.tcl << 'TCLEOF'
dbset db mysql
diset connection mysql_host 127.0.0.1
diset connection mysql_port HAMMERDB_PORT
diset connection mysql_socket HAMMERDB_SOCKET
diset tpcc mysql_user hammerdb
diset tpcc mysql_pass hammerdb
diset tpcc mysql_dbase tpcc
diset tpcc mysql_driver timed
diset tpcc mysql_rampup HAMMERDB_RAMPUP
diset tpcc mysql_duration HAMMERDB_DURATION
diset tpcc mysql_timeprofile true
loadscript
vuset vu HAMMERDB_VU_TEST
vucreate
tcstart
tcstatus
vurun
vudestroy
tcstop
after 5000
set jobid [lindex [jobs joblist] end]
puts "HAMMERDB RESULT"
jobs $jobid result
puts "TRANSACTION RESPONSE TIMES"
jobs $jobid timing
TCLEOF
sed -i "s/HAMMERDB_PORT/$PORT/g; s|HAMMERDB_SOCKET|$SOCKET|g; s/HAMMERDB_RAMPUP/$RAMPUP/g; s/HAMMERDB_DURATION/$DURATION/g; s/HAMMERDB_VU_TEST/$VU_TEST/g" /tmp/hammerdb_icx_run.tcl

for RUN in $(seq 1 "$RUNS"); do
    HAMMERDB_LOG="${LOG_PREFIX}_run${RUN}.log"
    echo ""
    echo "  --- Run $RUN/$RUNS ---"
    ./hammerdbcli auto /tmp/hammerdb_icx_run.tcl 2>&1 | tee "$HAMMERDB_LOG"

    # Show result for this run
    RESULT=$(grep -oP 'System achieved \K[0-9]+ NOPM.*' "$HAMMERDB_LOG" | tail -1)
    echo "  Run $RUN result: ${RESULT:-N/A}"
done

echo ""
echo "=== ICX+LTO: All $RUNS runs complete ==="

# -------------------------------------------------------
# Cleanup: stop MySQL server
# -------------------------------------------------------
echo "Shutting down MySQL server..."
$BASEDIR/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
wait $MYSQLD_PID 2>/dev/null || true
echo "Done."
