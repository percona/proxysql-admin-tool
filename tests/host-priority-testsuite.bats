# proxysql_GALERA_CHECKER host priority tests
#
# Testing Hints:
# If there is a problem in the test, it's useful to enable the "debug"
# flag to see the proxysql_GALERA_CHECKER and galera_node_monitor
# debug output.  The "--debug" flag must go INSIDE the duoble quotes.
#
#      run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --debug")
#
#


#
# Variable initialization
#
source /etc/proxysql-admin.cnf
PXC_BASEDIR=$WORKDIR/pxc-bin
PROXYSQL_BASEDIR=$WORKDIR/proxysql-bin

# Declare some GLOBALS
# These are used to return data from get_node_data()
declare HOSTS=()
declare PORTS=()
declare STATUS=()

load test-common

WSREP_CLUSTER_NAME=$(cluster_exec "select @@wsrep_cluster_name" 2> /dev/null)
MYSQL_VERSION=$(cluster_exec "select @@version")


# Note: 4110/4210  is left as an unprioritized node
if [[ $WSREP_CLUSTER_NAME == "cluster_one" ]]; then
  PORT_1=4130
  PORT_2=4120
  PORT_NOPRIO=4110
else
  PORT_1=4230
  PORT_2=4220
  PORT_NOPRIO=4210
fi

if [[ $USE_IPVERSION == "v4" ]]; then
  LOCALHOST_IP="127.0.0.1"
else
  LOCALHOST_IP="[::1]"
fi
PRIORITY_LIST="${LOCALHOST_IP}:${PORT_1},${LOCALHOST_IP}:${PORT_2}"
PRIORITY_LIST_re=$(printf '%s' "$PRIORITY_LIST" | sed 's/[.[\*^$]/\\&/g')

# Sets up the general priority tests
#   (1) Deactivates the scheduler
#   (2) Syncs up with the RUNTIME (for a consistent start state)
#   (3) Initializes some global variables for use
#
# Globals:
#   SCHEDULER_ID
#   GALERA_CHECKER
#   GALERA_CHECKER_ARGS
#   PS_ROW0  RESTART_CMD0  RESTART_USER0  PXC_SOCKET0
#   PS_ROW1  RESTART_CMD1  RESTART_USER1  PXC_SOCKET1
#   PS_ROW2  RESTART_CMD2  RESTART_USER2  PXC_SOCKET2
#
function test_preparation() {
  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters)
  # ========================================================
  SCHEDULER_ID=$(proxysql_exec "SELECT id FROM scheduler WHERE arg1 like '% --write-hg=$WRITE_HOSTGROUP_ID %'")
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  PS_ROW1=$(ps aux | grep "mysqld" | grep "port=$PORT_1")
  RESTART_CMD1=$(echo $PS_ROW1 | sed 's:^.* /:/:')
  RESTART_USER1=$(echo $PS_ROW1 | awk '{ print $1 }')
  PXC_SOCKET1=$(echo $RESTART_CMD1 | grep -o "\-\-socket=[^ ]* ")

  PS_ROW2=$(ps aux | grep "mysqld" | grep "port=$PORT_2")
  RESTART_CMD2=$(echo $PS_ROW2 | sed 's:^.* /:/:')
  RESTART_USER2=$(echo $PS_ROW2 | awk '{ print $1 }')
  PXC_SOCKET2=$(echo $RESTART_CMD2 | grep -o "\-\-socket=[^ ]* ")

  PS_ROW0=$(ps aux | grep "mysqld" | grep "port=$PORT_NOPRIO")
  RESTART_CMD0=$(echo $PS_ROW0 | sed 's:^.* /:/:')
  RESTART_USER0=$(echo $PS_ROW0 | awk '{ print $1 }')
  PXC_SOCKET0=$(echo $RESTART_CMD0 | grep -o "\-\-socket=[^ ]* ")
}

# Runs the galera_checker and verifies the initial state
#
# Globals:
#   GALERA_CHECKER
#   GALERA_CHECKER_ARGS
#   PORT_1  PORT_2  PORT_NOPRIO
#
#  Arguments:
#   None
#
function verify_initial_state() {
  # run twice to initialize (depends on the priority list in the scheduler)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # Check the initial setup (3 rows in the table, all ONLINE)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {
  echo "priority_list is $PRIORITY_LIST" >& 2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writer-is-reader=ondemand --write-node=$PRIORITY_LIST <<< 'n'
  [ "$status" -eq  0 ]

  #
  # DEACTIVATE the scheduler line (call proxysql_GALERA_CHECKER manually)
  # For ALL of the tests
  # ========================================================
  local sched_id
  sched_id=$(proxysql_exec "SELECT id FROM scheduler WHERE arg1 like '% --write-hg=$WRITE_HOSTGROUP_ID %'")
  run proxysql_exec "UPDATE scheduler SET active=0 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
  [ "$status" -eq  0 ]
}


@test "host-priority testing stopping (noprio 1 2) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: unlisted 1 2
  # ========================================================
  # kill nodes 2,1

  # shutdown node2
  echo "$LINENO Shutting down node2 : $host:$PORT_2..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET2 -u root shutdown

  # shutdown node1
  echo "$LINENO Shutting down node1 : $host:$PORT_1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET1 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Rerun the checker, should move OFFLINE_SOFT to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Rerun the checker, should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node1
  echo "$LINENO Starting node1 : $host:$PORT_1..." >&2
  restart_server "$RESTART_CMD1" "$RESTART_USER1"
  wait_for_server_start $PXC_SOCKET1 2

  # Run the checker, should make PORT_1 the writer
  # and taking the previous writer OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_NOPRIO ]
  [ "${write_port[1]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_1 ]
  [ "${read_port[2]}" -eq $PORT_NOPRIO ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node2
  echo "$LINENO Starting node2 : $host:$PORT_2..." >&2
  restart_server "$RESTART_CMD2" "$RESTART_USER2"
  wait_for_server_start $PXC_SOCKET2 3

  # Run the checker, should keep PORT_1 the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_NOPRIO ]
  [ "${read_port[2]}" -eq $PORT_2 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing stopping (noprio 2 1) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: unlisted 2 1
  # ========================================================
  # kill nodes 1,2

  # shutdown node1
  echo "$LINENO Shutting down node1 : $host:$PORT_1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET1 -u root shutdown

  # shutdown node2
  echo "$LINENO Shutting down node2 : $host:$PORT_2..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET2 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Rerun the checker, should move OFFLINE_SOFT to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [[ "${read_port[0]}" -eq $PORT_1 || "${read_port[0]}" -eq $PORT_2 ]]
  [[ "${read_port[1]}" -eq $PORT_1 || "${read_port[1]}" -eq $PORT_2 ]]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]
  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node2
  echo "$LINENO Starting node2 : $host:$PORT_2..." >&2
  restart_server "$RESTART_CMD2" "$RESTART_USER2"
  wait_for_server_start $PXC_SOCKET2 2

  # Run the checker, should keep PORT_2 the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_NOPRIO ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_NOPRIO ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, removes offline writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_2 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_NOPRIO ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node1
  echo "$LINENO Starting node1 : $host:$PORT_1..." >&2
  restart_server "$RESTART_CMD1" "$RESTART_USER1"
  wait_for_server_start $PXC_SOCKET1 3

  # Run the checker, should make PORT_1 the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_2 ]
  [ "${write_port[1]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_NOPRIO ]
  [ "${read_port[2]}" -eq $PORT_2 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should make PORT_1 the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_NOPRIO ]
  [ "${read_port[2]}" -eq $PORT_2 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing stopping (1 noprio 2) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 1 unlisted 2
  # ========================================================
  # kill nodes 2,unlisted

  # shutdown node2
  echo "$LINENO Shutting down node2 : $host:$PORT_2..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET2 -u root shutdown

  # shutdown node noprio
  echo "$LINENO Shutting down node nonprio : $host:$PORT_NOPRIO..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET0 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node noprio
  echo "$LINENO Starting node noprio : $host:$PORT_NOPRIO..." >&2
  restart_server "$RESTART_CMD0" "$RESTART_USER0"
  wait_for_server_start $PXC_SOCKET0 2

  # Run the checker, PORT_1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node 2
  echo "$LINENO Starting node2 : $host:$PORT_2..." >&2
  restart_server "$RESTART_CMD2" "$RESTART_USER2"
  wait_for_server_start $PXC_SOCKET2 3

  # Run the checker, PORT_1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, (no change)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing stopping (1 2 noprio) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 1 2 unlisted
  # ========================================================
  # kill nodes unlisted,2

  # shutdown node noprio
  echo "$LINENO Shutting down node nonprio : $host:$PORT_NOPRIO..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET0 -u root shutdown

  # shutdown node2
  echo "$LINENO Shutting down node2 : $host:$PORT_2..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET2 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should move nodes to OFFLINE_HARD reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node2
  echo "$LINENO Starting node2 : $host:$PORT_2..." >&2
  restart_server "$RESTART_CMD2" "$RESTART_USER2"
  wait_for_server_start $PXC_SOCKET2 2

  # Run the checker, should keep PORT_1 the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_NOPRIO ]
  [ "${read_port[1]}" -eq $PORT_1 ]
  [ "${read_port[2]}" -eq $PORT_2 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node noprio
  echo "$LINENO Starting node noprio : $host:$PORT_NOPRIO..." >&2
  restart_server "$RESTART_CMD0" "$RESTART_USER0"
  wait_for_server_start $PXC_SOCKET0 3

  # Run the checker, PORT_1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing stopping (2 noprio 1) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 2 unlisted 1
  # ========================================================
  # kill nodes 1,unlisted

  # shutdown node1
  echo "$LINENO Shutting down node1 : $host:$PORT_1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET1 -u root shutdown

  # shutdown node noprio
  echo "$LINENO Shutting down node nonprio : $host:$PORT_NOPRIO..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET0 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should move nodes to OFFLINE_HARD reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node noprio
  echo "$LINENO Starting node noprio : $host:$PORT_NOPRIO..." >&2
  restart_server "$RESTART_CMD0" "$RESTART_USER0"
  wait_for_server_start $PXC_SOCKET0 2

  # Run the checker, PORT_2 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Starting node1 : $host:$PORT_1..." >&2
  restart_server "$RESTART_CMD1" "$RESTART_USER1"
  wait_for_server_start $PXC_SOCKET1 3

  # Run the checker, PORT_1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing stopping (2 1 noprio) ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 2 1 unlisted
  # ========================================================
  # kill nodes unlisted,1

  # shutdown node noprio
  echo "$LINENO Shutting down node nonprio : $host:$PORT_NOPRIO..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET0 -u root shutdown

  # shutdown node1
  echo "$LINENO Shutting down node1 : $host:$PORT_1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET1 -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should move nodes to OFFLINE_HARD reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Starting node1 : $host:$PORT_1..." >&2
  restart_server "$RESTART_CMD1" "$RESTART_USER1"
  wait_for_server_start $PXC_SOCKET1 2

  # Run the checker, PORT_1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node noprio
  echo "$LINENO Starting node noprio : $host:$PORT_NOPRIO..." >&2
  restart_server "$RESTART_CMD0" "$RESTART_USER0"
  wait_for_server_start $PXC_SOCKET0 3

  # Run the checker, PORT_1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (noprio 1 2) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # Redo the tests but use pxc_maint_mode instead of stopping the node
  # ========================================================

  # TEST order of node restoration: unlisted 1 2 (pxc_maint_mode)
  # ========================================================

  # Disable 2 1
  echo "$LINENO Disabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${write_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Enable node 1
  echo "$LINENO Enabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Enable node 2
  echo "$LINENO Enabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should still be the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (noprio 2 1) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: unlisted 2 1 (pxc_maint_mode)
  # ========================================================
  # Disable 1 2
  echo "$LINENO Disabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${write_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Enable node 1
  echo "$LINENO Enabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Enable node 2
  echo "$LINENO Enabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should still be the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (1 noprio 2) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 1 unlisted 2 (pxc_maint_mode)
  # ========================================================
  # Disable 2 unlisted
  echo "$LINENO Disabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Enable node noprio
  echo "$LINENO Enabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_NOPRIO" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Enable node 2
  echo "$LINENO Enabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should still be the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (1 2 noprio) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 1 2 unlisted (pxc_maint_mode)
  # ========================================================
  # disable unlisted,2

  # disable noprio
  echo "$LINENO Disabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # disable node 2, should make node 1 the writer
  echo "$LINENO Disabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node 2
  echo "$LINENO Enabling node 2 : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node noprio
  echo "$LINENO Enabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (2 noprio 1) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 2 unlisted 1 (pxc_maint_mode)
  # ========================================================
  # disable 1,unlisted

  # disable node 1, should make node 2 the writer
  echo "$LINENO Disabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # disable noprio
  echo "$LINENO Disabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${write_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node 1
  echo "$LINENO Enabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node noprio
  echo "$LINENO Enabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "host-priority testing disabling (2 1 noprio) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST order of node restoration: 2 1 unlisted (pxc_maint_mode)
  # ========================================================

  # disable unlisted,1

  # disable noprio
  echo "$LINENO Disabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # disable node 1, should make node 2 the writer
  echo "$LINENO Disabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline (no change)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${write_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node 1
  echo "$LINENO Enabling node 1 : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should become the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_2" ]
  [ "${write_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[1]}" -eq "$PORT_1" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # enable node noprio
  echo "$LINENO Enabling node noprio : $host:$PORT_NOPRIO..." >&2
  run mysql_exec "$host" "$PORT_NOPRIO" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, node 1 should stay the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # REACTIVATE the scheduler
  # ========================================================
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$SCHEDULER_ID; LOAD scheduler TO RUNTIME"
}


@test "priority-list has no active nodes and stop writer ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  local new_priority_list="${LOCALHOST_IP}:9000,${LOCALHOST_IP}:9001"
  local new_priority_list_re=$(printf '%s' "$new_priority_list" | sed 's/[.[\*^$]/\\&/g')

  # Swap the old priority list for the new priority list in the
  # galera_checker
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/${PRIORITY_LIST_re}/${new_priority_list_re}/g")

  echo $GALERA_CHECKER_ARGS >&2

  # Run the checker, no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST stop node 1 (writer)
  # ========================================================

  # shutdown node1
  echo "$LINENO Shutting down node1 : $host:$PORT_1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $PXC_SOCKET1 -u root shutdown

  # Run the checker, no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  writer_port=${write_port[0]}
  [[ $writer_port -eq  "${read_port[0]}" || $writer_port -eq ${read_port[1]} ]]
  [[ $PORT_1 -eq  ${read_port[0]} || $PORT_1 -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Starting node1 : $host:$PORT_1..." >&2
  restart_server "$RESTART_CMD1" "$RESTART_USER1"
  wait_for_server_start $PXC_SOCKET1 3

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [ "${read_port[0]}" -eq "$writer_port" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "priority-list has no active nodes and stop reader ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  local new_priority_list="${LOCALHOST_IP}:9000,${LOCALHOST_IP}:9001"
  local new_priority_list_re=$(printf '%s' "$new_priority_list" | sed 's/[.[\*^$]/\\&/g')

  # Swap the old priority list for the new priority list in the
  # galera_checker
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/${PRIORITY_LIST_re}/${new_priority_list_re}/g")

  echo $GALERA_CHECKER_ARGS >&2

  # Run the checker, no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST stop reader node
  # ========================================================
  writer_port=${write_port[0]}
  reader_port=${read_port[1]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown reader node
  echo "$LINENO Shutting down node : $host:$reader_port..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [[ ${writer_port} -eq ${read_port[0]} || ${writer_port} -eq ${read_port[1]} ]]
  [[ ${reader_port} -eq ${read_port[0]} || ${reader_port} -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [ "${read_port[0]}" -eq "$reader_port" ]
  [ "${read_port[1]}" -eq "$writer_port" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Restart the node that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting node : $host:$reader_port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [ "${read_port[0]}" -eq "$writer_port" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "priority-list has no active nodes and disable writer ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}
  writer_port=${write_port[0]}

  local new_priority_list="${LOCALHOST_IP}:9000,${LOCALHOST_IP}:9001"
  local new_priority_list_re=$(printf '%s' "$new_priority_list" | sed 's/[.[\*^$]/\\&/g')

  # Swap the old priority list for the new priority list in the
  # galera_checker
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/${PRIORITY_LIST_re}/${new_priority_list_re}/g")

  echo $GALERA_CHECKER_ARGS >&2

  # Run the checker, no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST disable writer node (pxc_maint_mode)
  # ========================================================
  old_writer_port=$writer_port
  echo "$LINENO Disabling writer node : $host:$writer_port..." >&2
  run mysql_exec "$host" "$writer_port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  new_writer_port=${write_port[1]}

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${old_writer_port}" -eq "${write_port[0]}" ]
  [ "${new_writer_port}" -eq "${write_port[1]}" ]
  [[ $old_writer_port -eq ${read_port[0]} || $old_writer_port -eq ${read_port[1]} ]]
  [[ $new_writer_port -eq ${read_port[0]} || $new_writer_port -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # rerun the checker, should not change the writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${new_writer_port}" -eq "${write_port[0]}" ]
  [[ $old_writer_port -eq ${read_port[0]} || $old_writer_port -eq ${read_port[1]} ]]
  [[ $new_writer_port -eq ${read_port[0]} || $new_writer_port -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Reenable the writer node
  echo "$LINENO Enabling previous writer node : $host:$old_writer_port..." >&2
  run mysql_exec "$host" "$old_writer_port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$new_writer_port" ]
  [ "${read_port[0]}" -eq "$new_writer_port" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "priority-list has no active nodes and disable reader ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  local new_priority_list="${LOCALHOST_IP}:9000,${LOCALHOST_IP}:9001"
  local new_priority_list_re=$(printf '%s' "$new_priority_list" | sed 's/[.[\*^$]/\\&/g')

  # Swap the old priority list for the new priority list in the
  # galera_checker
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/${PRIORITY_LIST_re}/${new_priority_list_re}/g")

  echo $GALERA_CHECKER_ARGS >&2

  # Run the checker, no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST disable reader node (pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  reader_port=${read_port[1]}

  echo "$LINENO Disabling reader node : $host:$reader_port..." >&2
  run mysql_exec "$host" "$reader_port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [[ ${writer_port} -eq ${read_port[0]} || ${writer_port} -eq ${read_port[1]} ]]
  [[ ${reader_port} -eq ${read_port[0]} || ${reader_port} -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [[ ${writer_port} -eq ${read_port[0]} || ${writer_port} -eq ${read_port[1]} ]]
  [[ ${reader_port} -eq ${read_port[0]} || ${reader_port} -eq ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Reenable the reader node
  echo "$LINENO Enabling previous reader node : $host:$reader_port..." >&2
  run mysql_exec "$host" "$reader_port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, writer should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$writer_port" ]
  [[ $reader_port -eq ${read_port[1]} || $reader_port -eq ${read_port[2]} ]]
  [ "${read_port[0]}" -eq "$writer_port" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

}


@test "match the priority-list in the middle of the list ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  local new_priority_list="${LOCALHOST_IP}:9000,${LOCALHOST_IP}:${PORT_2},${LOCALHOST_IP}:9001"
  local new_priority_list_re=$(printf '%s' "$new_priority_list" | sed 's/[.[\*^$]/\\&/g')

  # Swap the old priority list for the new priority list in the
  # galera_checker
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$SCHEDULER_ID")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$SCHEDULER_ID")

  echo $GALERA_CHECKER_ARGS >&2

  # Run the checker, node 1 should be the writer (original priority list)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[0]}" -eq "$PORT_1" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_2" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/${PRIORITY_LIST_re}/${new_priority_list_re}/g")

  # Run the checker, node 2 should be the writer (new priority list)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='host-priority $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$PORT_1" ]
  [ "${write_port[1]}" -eq "$PORT_2" ]
  [ "${read_port[0]}" -eq "$PORT_2" ]
  [ "${read_port[1]}" -eq "$PORT_NOPRIO" ]
  [ "${read_port[2]}" -eq "$PORT_1" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

}
