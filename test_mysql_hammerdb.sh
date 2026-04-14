#!/bin/bash
set -e

# Load Intel oneAPI runtime (provides libsvml.so, libimf.so, etc.)
source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true

BASEDIR=/home/shuchen1/mysql/installation/mysql_icx_gnr_lto/usr/local/mysql

# Make libmysqlclient.so.24 available to HammerDB
export LD_LIBRARY_PATH=$BASEDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
DATADIR=/home/shuchen1/mysql/data_icx_gnr_lto
SOCKET=/tmp/mysql_icx.sock
PORT=3307
HAMMERDB=/home/shuchen1/mysql/HammerDB-5.0
WAREHOUSES=16
VU_BUILD=16
VU_TEST=16
RAMPUP=1
DURATION=3

echo "=== MySQL ICX/GNR/LTO HammerDB Test ==="

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

$BASEDIR/bin/mysqld \
    --basedir=$BASEDIR \
    --datadir=$DATADIR \
    --socket=$SOCKET \
    --port=$PORT \
    --innodb-buffer-pool-size=4G \
    --innodb-redo-log-capacity=2G \
    --innodb-flush-method=O_DIRECT \
    --innodb-flush-log-at-trx-commit=1 \
    --max-connections=256 \
    --table-open-cache=4000 &

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

cat > /tmp/hammerdb_build.tcl << EOF
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
./hammerdbcli auto /tmp/hammerdb_build.tcl

# -------------------------------------------------------
# Step 5: Run TPC-C benchmark
# -------------------------------------------------------
echo "[5/5] Running TPC-C benchmark ($VU_TEST VUs, ${RAMPUP}min ramp, ${DURATION}min test)..."

cat > /tmp/hammerdb_run.tcl << EOF
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

./hammerdbcli auto /tmp/hammerdb_run.tcl

echo ""
echo "=== Benchmark complete ==="
echo "Look for TPM (Transactions Per Minute) and NOPM (New Orders Per Minute) above."

# -------------------------------------------------------
# Cleanup: stop MySQL server
# -------------------------------------------------------
echo "Shutting down MySQL server..."
$BASEDIR/bin/mysqladmin -u root --socket=$SOCKET shutdown 2>/dev/null || true
wait $MYSQLD_PID 2>/dev/null || true
echo "Done."
