## proxysql_GALERA_CHECKER async slave tests
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
declare slave_host
declare slave_port
declare slave_status
declare slave_hostgroup
declare slave_comment

load test-common

WSREP_CLUSTER_NAME=$(cluster_exec "select @@wsrep_cluster_name" 2> /dev/null)
MYSQL_VERSION=$(cluster_exec "select @@version")

# Note: 4110/4210  is left as an unprioritized node
if [[ $WSREP_CLUSTER_NAME == "cluster_one" ]]; then
  PORT_1=4110
  PORT_2=4120
  PORT_3=4130
  PORT_SLAVE1=4190
  PORT_SLAVE2=4195
else
  PORT_1=4210
  PORT_2=4220
  PORT_3=4230
  PORT_SLAVE1=4290
  PORT_SLAVE2=4295
fi

if [[ $USE_IPVERSION == "v6" ]]; then
  LOCALHOST_IP="[::1]"
else
  LOCALHOST_IP="127.0.0.1"
fi

# Sets up the general test setup
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

  # Ensure that we do not have any leftovers from a previous run
  #proxysql_exec "DELETE FROM runtime_mysql_servers WHERE hostgroup_id IN ($WRITE_HOSTGROUP_ID, $READ_HOSTGROUP_ID) AND status='OFFLINE_HARD'"
  proxysql_exec "SAVE mysql servers FROM RUNTIME" >/dev/null

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
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  # Check the initial setup (3 rows in the table, all ONLINE)
  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]
  [ "${slave_status[0]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "${read_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  result=$(retrieve_slavenode_status "${slave_host[0]}" "${slave_port[0]}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]
}


@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --include-slaves=$LOCALHOST_IP:$PORT_SLAVE1 --use-slave-as-writer=yes --writer-is-reader=ondemand <<< 'n'
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

@test "stopping and restarting the slave ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # Stop the slave
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  echo $result >&2
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "No" ]
  [ "${slave_sql_running}" = "No" ]

  # Restart the slave
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

}

@test "stopping and starting the slave threads ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # Stop the slave SQL thread
  echo "$LINENO Stopping the slave sql thread on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE SQL_THREAD"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "No" ]

  # Restart the slave SQL thread
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

  # Stop the slave IO thread
  echo "$LINENO Stopping the slave IO thread on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE IO_THREAD"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "No" ]
  [ "${slave_sql_running}" = "Yes" ]

  # Restart the slave IO thread
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

}


@test "slave activation after stopping the entire cluster ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
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

  # TEST shutdown the entire cluster (slave should become active)
  # ========================================================
  # shutdown node1
  echo "$LINENO Shutting down node : $host:$PORT_1..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket1 -u root shutdown
  [ "$status" -eq 0 ]

  # shutdown node2
  echo "$LINENO Shutting down node : $host:$PORT_2..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket2 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_3 ]
  [[ $PORT_1 -eq ${read_port[0]} || $PORT_1 -eq ${read_port[1]} ]]
  [[ $PORT_2 -eq ${read_port[0]} || $PORT_2 -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # rerun
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_3 ]
  [[ $PORT_1 -eq ${read_port[0]} || $PORT_1 -eq ${read_port[1]} ]]
  [[ $PORT_2 -eq ${read_port[0]} || $PORT_2 -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # shutdown node3
  echo "$LINENO Shutting down node : $host:$PORT_3..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket3 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # rerun, should move all nodes to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # rerun, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # TEST Stop the slave
  # ========================================================
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  

  # TEST Start the slave
  # ========================================================
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]
  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]

  # TEST restart a single node
  # ========================================================
  echo "$LINENO Starting node (bootstrapping) : $host:$PORT_1..." >&2
  restart_server "$restart_cmd1" "$restart_user1" "bootstrap"
  wait_for_server_start $pxc_socket1 1

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]

  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # TEST restart all nodes
  # ========================================================
  echo "$LINENO Starting node : $host:$PORT_2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket2 2

  echo "$LINENO Starting node : $host:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]
}


@test "slave activation after disabling the entire cluster ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  #verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST disable the entire cluster (with pxc_maint_mode)
  # ========================================================
  echo "$LINENO Disabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  echo "$LINENO Disabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # Rerun the checker, should remove the offline writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # Rerun the checker, should show no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

  # TEST Stop the slave
  # ========================================================
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # Start the slave
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]


  # Test enable a single node
  # ========================================================
  echo "$LINENO Enabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]


  # Test enable all the nodes
  # ========================================================
  echo "$LINENO Enabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  echo "$LINENO Enabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]

  [ "${slave_port[1]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[1]}" = "ONLINE" ]
  [ "${slave_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]


  # REACTIVATE the scheduler
  # ========================================================
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$SCHEDULER_ID; LOAD scheduler TO RUNTIME"
}

@test "run proxysql-admin -d (restart for use-slave-as-writer tests) ($WSREP_CLUSTER_NAME)" {
  #skip
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e --use-slave-as-writer=no ($WSREP_CLUSTER_NAME)" {
  #skip
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --include-slaves=$LOCALHOST_IP:$PORT_SLAVE1 --use-slave-as-writer=no --writer-is-reader=ondemand <<< 'n'
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

@test "stopping and restarting the slave --use-slave-as-writer=no ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # Stop the slave
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  echo $result >&2
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "No" ]
  [ "${slave_sql_running}" = "No" ]

  # Restart the slave
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

}

@test "stopping and starting the slave threads --use-slave-as-writer=no ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # Stop the slave SQL thread
  echo "$LINENO Stopping the slave sql thread on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE SQL_THREAD"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "No" ]

  # Restart the slave SQL thread
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

  # Stop the slave IO thread
  echo "$LINENO Stopping the slave IO thread on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE IO_THREAD"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "No" ]
  [ "${slave_sql_running}" = "Yes" ]

  # Restart the slave IO thread
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]
  sleep 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  result=$(retrieve_slavenode_status "${CLUSTER_HOSTNAME}" "${PORT_SLAVE1}")
  master_host=$(echo -e "$result" | cut -f1)
  slave_io_running=$(echo -e "$result" | cut -f2)
  slave_sql_running=$(echo -e "$result" | cut -f3)

  [ -n "${master_host}" ]
  [ "${slave_io_running}" = "Yes" ]
  [ "${slave_sql_running}" = "Yes" ]

}


@test "slave activation after stopping the entire cluster --use-slave-as-writer=no ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
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

  # TEST shutdown the entire cluster (slave should become active)
  # ========================================================
  # shutdown node1
  echo "$LINENO Shutting down node : $host:$PORT_1..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket1 -u root shutdown
  [ "$status" -eq 0 ]

  # shutdown node2
  echo "$LINENO Shutting down node : $host:$PORT_2..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket2 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_3 ]
  [[ $PORT_1 -eq ${read_port[0]} || $PORT_1 -eq ${read_port[1]} ]]
  [[ $PORT_2 -eq ${read_port[0]} || $PORT_2 -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # rerun
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_3 ]
  [[ $PORT_1 -eq ${read_port[0]} || $PORT_1 -eq ${read_port[1]} ]]
  [[ $PORT_2 -eq ${read_port[0]} || $PORT_2 -eq ${read_port[1]} ]]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # shutdown node3
  echo "$LINENO Shutting down node : $host:$PORT_3..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket3 -u root shutdown
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # rerun, should move all nodes to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # rerun, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]

  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # TEST Stop the slave
  # ========================================================
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]


  # TEST Start the slave
  # ========================================================
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "OFFLINE_HARD" ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]


  # TEST restart a single node
  # ========================================================
  echo "$LINENO Starting node (bootstrapping) : $host:$PORT_1..." >&2
  restart_server "$restart_cmd1" "$restart_user1" "bootstrap"
  wait_for_server_start $pxc_socket1 1

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]

  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_SOFT" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # TEST restart all nodes
  # ========================================================
  echo "$LINENO Starting node : $host:$PORT_2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket2 2

  echo "$LINENO Starting node : $host:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
}


@test "slave activation after disabling the entire cluster --use-slave-as-writer=no ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # PREPARE for the test
  # ========================================================
  test_preparation
  #verify_initial_state

  # Store some special variables
  retrieve_writer_info
  host=${write_host[0]}

  # TEST disable the entire cluster (with pxc_maint_mode)
  # ========================================================
  echo "$LINENO Disabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]
  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  echo "$LINENO Disabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # Rerun the checker, should remove the offline writer
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # Rerun the checker, should show no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # TEST Stop the slave
  # ========================================================
  echo "$LINENO Stopping the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "STOP SLAVE"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "OFFLINE_HARD" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]

  # Start the slave
  echo "$LINENO Starting the slave on port:$PORT_SLAVE1" >&2
  run mysql_exec "$CLUSTER_HOSTNAME" "$PORT_SLAVE1" "START SLAVE"
  [ "$status" -eq 0 ]

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 0 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "OFFLINE_SOFT" ]

  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]


  # Test enable a single node
  # ========================================================
  echo "$LINENO Enabling node : $host:$PORT_1..." >&2
  run mysql_exec "$host" "$PORT_1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_2 ]
  [ "${read_port[1]}" -eq $PORT_3 ]
  [ "${read_port[2]}" -eq $PORT_1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]


  # Test enable all the nodes
  # ========================================================
  echo "$LINENO Enabling node : $host:$PORT_2..." >&2
  run mysql_exec "$host" "$PORT_2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  echo "$LINENO Enabling node : $host:$PORT_3..." >&2
  run mysql_exec "$host" "$PORT_3" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='async-slave $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info
  retrieve_slave_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]
  [ "${#slave_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $PORT_1 ]
  [ "${read_port[0]}" -eq $PORT_1 ]
  [ "${read_port[1]}" -eq $PORT_2 ]
  [ "${read_port[2]}" -eq $PORT_3 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  [ "${slave_port[0]}" -eq $PORT_SLAVE1 ]
  [ "${slave_status[0]}" = "ONLINE" ]
  [ "${slave_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]


  # REACTIVATE the scheduler
  # ========================================================
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$SCHEDULER_ID; LOAD scheduler TO RUNTIME"
}
