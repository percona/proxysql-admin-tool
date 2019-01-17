## proxysql_GALERA_CHECKER desynced host tests
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
declare HOSTGROUPS=()
declare COMMENTS=()
declare WEIGHTS=()
declare MAX_CONNECTIONS=()

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


# Sets up the general priority tests
#   (1) Deactivates the scheduler
#   (2) Syncs up with the RUNTIME (for a consistent start state)
#   (3) Initializes some global variables for use
#
# Globals:
#   SCHEDULER_ID
#   GALERA_CHECKER
#   GALERA_CHECKER_ARGS
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
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
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

  [ "${write_port[0]}" -eq "${read_port[0]}" ]

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
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writer-is-reader=ondemand <<< 'n'
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


@test "desync node activation ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  host=${write_host[0]}

  retrieve_reader_info
  retrieve_writer_info

  port1=${write_port[0]}
  [ "${read_port[0]}" == "${write_port[0]}" ]
  port2=${read_port[1]}
  port3=${read_port[2]}

  # TEST activation of a desync node (nodes are shutdown)
  # ========================================================

  # Change a reader node to desynced
  echo "$LINENO Desyncing node : $host:$port3..." >&2
  run mysql_exec "$host" "$port3" "SET global wsrep_desync=ON"
  [ "$status" -eq 0 ]

  wsrep_status=$(mysql_exec "$host" "$port3" "SHOW STATUS LIkE 'wsrep_local_state'\G" -BNs | tail -1)
  [ "$wsrep_status" -eq 2 ]

  # shutdown the other nodes
  ps_row1=$(ps aux | grep "mysqld" | grep "port=$port1")
  restart_cmd1=$(echo $ps_row1 | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row1 | awk '{ print $1 }')
  pxc_socket1=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")

  ps_row2=$(ps aux | grep "mysqld" | grep "port=$port2")
  restart_cmd2=$(echo $ps_row2 | sed 's:^.* /:/:')
  restart_user2=$(echo $ps_row2 | awk '{ print $1 }')
  pxc_socket2=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")

  ps_row3=$(ps aux | grep "mysqld" | grep "port=$port3")
  restart_cmd3=$(echo $ps_row3 | sed 's:^.* /:/:')
  restart_user3=$(echo $ps_row3 | awk '{ print $1 }')
  pxc_socket3=$(echo $restart_cmd3 | grep -o "\-\-socket=[^ ]* ")

  # shutdown node1
  echo "$LINENO Shutting down node : $host:$port1..." >&2
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket1 -u root shutdown

  # shutdown node2
  echo "$LINENO Shutting down node : $host:$port2..." >&2
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket2 -u root shutdown

  # Now this should check and make online port3
  # Run the checker, should move writer to OFFLINE_SOFT reader
  # node1:down  node2:down  node3:DESYNCED
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move nodes to OFFLINE_HARD
  # node1:down  node2:down  node3:up
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_HARD" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should not change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_HARD" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Change node to SYNCED
  echo "$LINENO Syncing node : $host:$port3..." >&2
  run mysql_exec "$host" "$port3" "SET global wsrep_desync=OFF"
  [ "$status" -eq 0 ]

  # Run the checker
  # node1:down  node2:down  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_HARD" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Change node to desync
  echo "$LINENO Desyncing node : $host:$port3..." >&2
  run mysql_exec "$host" "$port3" "SET global wsrep_desync=ON"
  [ "$status" -eq 0 ]

  # Run the checker
  # node1:down  node2:down  node3:DESYNCED
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_HARD" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Restart node1
  echo "$LINENO Starting node : $host:$port1..." >&2
  echo "$restart_cmd1" >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket1 2

  # node1:ok  node2:down  node3:DESYNCED
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port3 ]
  [ "${write_port[1]}" -eq $port1 ]
  [ "${read_port[0]}" -eq $port2 ]
  [ "${read_port[1]}" -eq $port3 ]
  [ "${read_port[2]}" -eq $port1 ]

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

  # Change node to normal
  echo "$LINENO Resyncing node : $host:$port3..." >&2
  run mysql_exec "$host" "$port3" "SET global wsrep_desync=OFF"
  [ "$status" -eq 0 ]

  # Run the checker
  # node1:ok  node2:down  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_HARD" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port1 ]
  [ "${read_port[0]}" -eq $port2 ]
  [ "${read_port[1]}" -eq $port1 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Restart node2
  echo "$LINENO Starting node : $host:$port2..." >&2
  echo "$restart_cmd2" >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket2 3

  # node1:ok  node2:ok  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "ONLINE" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port1 ]
  [ "${read_port[0]}" -eq $port1 ]
  [ "${read_port[1]}" -eq $port2 ]
  [ "${read_port[2]}" -eq $port3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "desync a writer node ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  host=${write_host[0]}
  port1=${write_port[0]}

  # TEST desync a writer node
  # ========================================================

  # Desync node1 (the writer)
  echo "$LINENO Desyncing node : $host:$port1..." >&2
  run mysql_exec "$host" "$port1" "SET global wsrep_desync=ON"
  [ "$status" -eq 0 ]

  wsrep_status=$(mysql_exec "$host" "$port1" "SHOW STATUS LIkE 'wsrep_local_state'\G" -BNs | tail -1)
  [ "$wsrep_status" -eq 2 ]

  # node1:DESYNCED  node2:ok  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port1 ]
  [ "${read_port[0]}" -eq $port1 ]
  [[ ${write_port[1]} -eq ${read_port[1]} || ${write_port[1]} -eq ${read_port[2]} ]]

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

  # Rerun checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [[ $port1 -eq "${read_port[0]}" ]]
  [[ ${write_port[0]} -eq ${read_port[1]} || ${write_port[0]} -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Sync node1 back (will not change the writer)
  echo "$LINENO Syncing node : $host:$port1..." >&2
  run mysql_exec "$host" "$port1" "SET global wsrep_desync=OFF"
  [ "$status" -eq 0 ]

  # node1:ok  node2:ok  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "ONLINE" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [[ ${write_port[0]} -eq ${read_port[0]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "desync node activation (nodes are disabled) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  host=${write_host[0]}

  # TEST activation of a desync node (nodes are disabled with pxc_maint_mode)
  # ========================================================
  desync_port=${write_port[0]}
  port1=${read_port[1]}
  port2=${read_port[2]}

  # Change a reader node to desynced
  echo "$LINENO Desyncing node : $host:$desync_port..." >&2
  run mysql_exec "$host" "$desync_port" "SET global wsrep_desync=ON"
  [ "$status" -eq 0 ]

  wsrep_status=$(mysql_exec "$host" "$desync_port" "SHOW STATUS LIkE 'wsrep_local_state'\G" -BNs | tail -1)
  [ "$wsrep_status" -eq 2 ]

  # disable port1
  echo "$LINENO Disabling node : $host:$port1..." >&2
  run mysql_exec "$host" "$port1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # disable port2
  echo "$LINENO Disabling node : $host:$port2..." >&2
  run mysql_exec "$host" "$port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # desynced node should have taken over
  # 2 nodes disabled, 1 desynced node
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $desync_port ]
  [ "${read_port[2]}" -eq $desync_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Rerun the checker (nothing should change)
  # 2 nodes disabled, 1 desynced node
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $desync_port ]
  [ "${read_port[2]}" -eq $desync_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Change node to SYNCED
  echo "$LINENO Syncing node : $host:$desync_port..." >&2
  run mysql_exec "$host" "$desync_port" "SET global wsrep_desync=OFF"
  [ "$status" -eq 0 ]

  # Run the checker
  # 2 nodes disabled, 1 node ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $desync_port ]
  [ "${read_port[2]}" -eq $desync_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Change node to desync
  echo "$LINENO Desyncing node : $host:$desync_port..." >&2
  run mysql_exec "$host" "$desync_port" "SET global wsrep_desync=ON"
  [ "$status" -eq 0 ]

  # Run the checker
  # 2 nodes disabled, 1 desynced node
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # One write node (and read) active, two readers offline
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $desync_port ]
  [ "${read_port[2]}" -eq $desync_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Restart node1
  echo "$LINENO Enabling node : $host:$port1..." >&2
  run mysql_exec "$host" "$port1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # node1:ok  node2:down  node3:DESYNCED
  # 1 good node, 1 node disabled, 1 desynced node
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $desync_port ]
  [ "${write_port[1]}" -eq $port1 ]
  [[ ${desync_port} -eq ${read_port[0]} || ${desync_port} -eq ${read_port[1]} ]]
  [[ ${port2} -eq ${read_port[0]} || ${port2} -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $port1 ]

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

  # Change node to normal
  echo "$LINENO Resyncing node : $host:$desync_port..." >&2
  run mysql_exec "$host" "$desync_port" "SET global wsrep_desync=OFF"
  [ "$status" -eq 0 ]

  # Run the checker
  # 2 nodes ok, 1 node disabled
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "OFFLINE_SOFT" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port1 ]
  [[ ${port1} -eq ${read_port[0]} || ${port1} -eq ${read_port[1]} ]]
  [[ ${port2} -eq ${read_port[0]} || ${port2} -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $desync_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Restart node2
  echo "$LINENO Enabling node : $host:$port2..." >&2
  run mysql_exec "$host" "$port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # node1:ok  node2:ok  node3:ok
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='desynced $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" == "OFFLINE_SOFT" ]
  [ "${read_status[1]}" == "ONLINE" ]
  [ "${read_status[2]}" == "ONLINE" ]

  [ "${write_port[0]}" -eq $port1 ]
  [ "${read_port[0]}" -eq $port1 ]
  [[ $port2 -eq ${read_port[1]} || $port2 -eq ${read_port[2]} ]]
  [[ $desync_port -eq ${read_port[1]} || $desync_port -eq ${read_port[2]} ]]

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
