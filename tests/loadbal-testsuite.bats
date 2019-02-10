## proxysql_GALERA_CHECKER loadbal tests
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
  PORT_1=4110
  PORT_2=4120
  PORT_3=4130
else
  PORT_1=4210
  PORT_2=4220
  PORT_3=4230
fi

# Sets up the tests
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
  proxysql_exec "DELETE FROM runtime_mysql_servers WHERE hostgroup_id IN ($WRITE_HOSTGROUP_ID, $READ_HOSTGROUP_ID) AND status='OFFLINE_HARD'"
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
  # run twice to initialize
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # Check the initial setup (3 rows in the table, all ONLINE)
  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]
}


@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --mode=loadbal --writer-is-reader=ondemand <<< 'n'
  [ "$status" -eq  0 ]

  #
  # DEACTIVATE the scheduler line (call proxysql_GALERA_CHECKER manually)
  # For ALL of the tests
  # ========================================================
  local sched_id
  sched_id=$(proxysql_exec "SELECT id FROM scheduler WHERE arg1 like '% --write-hg=$WRITE_HOSTGROUP_ID %'")
  run proxysql_exec "UPDATE scheduler SET active=0 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
  [ "$status" -eq  0 ]
  [ -n "$sched_id" ]
}


@test "shutdown and startup a server ($WSREP_CLUSTER_NAME)" {
  #skip

  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # store startup values
  ps_row1=$(ps aux | grep "mysqld" | grep "port=$PORT_1")
  restart_cmd1=$(echo $ps_row1 | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row1 | awk '{ print $1 }')
  pxc_socket1=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")

  # shutdown node1
  echo "$LINENO Shutting down node : $host:$PORT_1..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket1 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_HARD" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Starting node : $host:$PORT_1..." >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket1 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]
}

@test "disabling/enabling a server (pxc_maint_mode) ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # shutdown node1
  echo "$LINENO Disabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_2 ]
  [ "${write_port[1]}" -eq $PORT_1 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_2 ]
  [ "${write_port[1]}" -eq $PORT_1 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # reenable node 2
  echo "$LINENO Enabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]
}


@test "shutdown and startup the entire cluster ($WSREP_CLUSTER_NAME)" {
  #skip

  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # store startup values
  ps_row1=$(ps aux | grep "mysqld" | grep "port=$PORT_1")
  restart_cmd1=$(echo $ps_row1 | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row1 | awk '{ print $1 }')
  pxc_socket1=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")

  ps_row2=$(ps aux | grep "mysqld" | grep "port=$PORT_2")
  restart_cmd2=$(echo $ps_row2 | sed 's:^.* /:/:')
  restart_user2=$(echo $ps_row2 | awk '{ print $1 }')
  pxc_socket2=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")

  ps_row3=$(ps aux | grep "mysqld" | grep "port=$PORT_3")
  restart_cmd3=$(echo $ps_row3 | sed 's:^.* /:/:')
  restart_user3=$(echo $ps_row3 | awk '{ print $1 }')
  pxc_socket3=$(echo $restart_cmd3 | grep -o "\-\-socket=[^ ]* ")

  # shutdown all nodes
  echo "$LINENO Shutting down node : $host:$PORT_3..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket3 -u root shutdown
  [ "$status" -eq 0 ]

  echo "$LINENO Shutting down node : $host:$PORT_2..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket2 -u root shutdown
  [ "$status" -eq 0 ]

  echo "$LINENO Shutting down node : $host:$PORT_1..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket1 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "OFFLINE_SOFT" ]
  [ "${write_status[2]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_HARD" ]
  [ "${write_status[1]}" = "OFFLINE_HARD" ]
  [ "${write_status[2]}" = "OFFLINE_HARD" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # restart node 3
  echo "$LINENO Starting node (bootstrapping): $host:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3" "bootstrap"
  wait_for_server_start $pxc_socket3 1

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_HARD" ]
  [ "${write_status[1]}" = "OFFLINE_HARD" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Starting node : $host:$PORT_1..." >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket1 2

  # restart node 2
  echo "$LINENO Starting node : $host:$PORT_2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket2 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

}

@test "disabling/enabling the entire cluster ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # disable all nodes
  echo "$LINENO Disabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "OFFLINE_SOFT" ]
  [ "${write_status[2]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "OFFLINE_SOFT" ]
  [ "${write_status[2]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # reenable node 2
  echo "$LINENO Disabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "OFFLINE_SOFT" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_3 ]
  [ "${write_port[2]}" -eq $PORT_2 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

  # restart node 1
  echo "$LINENO Disabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # restart node 3
  echo "$LINENO Disabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='loadbal $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 0 ]
  [ "${#write_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${write_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${write_port[1]}" -eq $PORT_2 ]
  [ "${write_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "READWRITE" ]
  [ "${write_comment[1]}" = "READWRITE" ]
  [ "${write_comment[2]}" = "READWRITE" ]

  [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[1]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${write_hostgroup[2]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]
  [ "${write_weight[2]}" -eq 1000 ]

}
