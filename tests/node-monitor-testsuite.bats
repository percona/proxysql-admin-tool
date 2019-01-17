## proxysql_node_monitor tests
#
# This is to specifically test parts of the node monitor code that
# are not tested in the other tests.
#
# Testing Hints:
# If there is a problem in the test, it's useful to enable the "debug"
# flag to see the proxysql_GALERA_CHECKER and galera_node_monitor
# debug output.  The "--debug" flag must go INSIDE the duoble quotes.
#
#      run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --debug")
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

if [[ $WSREP_CLUSTER_NAME == "cluster_one" ]]; then
  PORT_1=4110
  PORT_2=4120
  PORT_3=4130
else
  PORT_1=4210
  PORT_2=4220
  PORT_3=4230
fi

if [[ $USE_IPVERSION == "v4" ]]; then
  LOCALHOST_IP="127.0.0.1"
else
  LOCALHOST_IP="[::1]"
fi


# Sets up the general priority tests
#   (1) Deactivates the scheduler
#   (2) Syncs up with the RUNTIME (for a consistent start state)
#   (3) Initializes some global variables for use
#
# Globals:
#   SCHEDULER_ID
#   GALERA_CHECKER
#   GALERA_CHECKER_ARGS
#   NODE_MONITOR
#   NODE_MONITOR_ARGS
#   WSREP_CLUSTER_NAME
#   RELOAD_CHECK_FILE
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

  # Pull the options out of GALERA_CHECKER_ARGS
  local config_file write_hg read_hg mode log reload_check_file
  local datadir reload_file
  local temp
  config_file=$(echo "$GALERA_CHECKER_ARGS" | grep -oe "--config-file=[^ ]*")
  write_hg=$(echo "$GALERA_CHECKER_ARGS" | grep -oe "--write-hg=[^ ]*")
  read_hg=$(echo "$GALERA_CHECKER_ARGS" | grep -oe "--read-hg=[^ ]*")
  mode=$(echo "$GALERA_CHECKER_ARGS" | grep -oe "--mode=[^ ]*")

  temp=$(echo $GALERA_CHECKER_ARGS | grep -oe "--log=[^ ]*")
  temp=${temp#--log=}
  datadir="$(dirname $temp)"
  log="--log=$datadir/${WSREP_CLUSTER_NAME}_proxysql_node_monitor.log"

  RELOAD_CHECK_FILE="${datadir}/node_monitor_reload_check.test"
  reload_file="--reload-check-file=$RELOAD_CHECK_FILE"
  echo "0" > "$RELOAD_CHECK_FILE"

  NODE_MONITOR="$(dirname $GALERA_CHECKER)/proxysql_node_monitor"
  NODE_MONITOR_ARGS="$config_file $write_hg $read_hg $mode $log $reload_file"
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
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='node-monitor $LINENO'")
  echo "$GALERA_CHECKER_ARGS" >&2
  [ "$status" -eq 0 ]

  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='node-monitor $LINENO'")
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

@test "run node-monitor node in PXC and NOT in ProxySQL ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Run the node monitor
  # (Nothing should have changed)
  run $(${NODE_MONITOR} ${NODE_MONITOR_ARGS} --log-text="node-monitor $LINENO")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[1]}" -eq 1111 ]
  [ "${read_max_connections[2]}" -eq 1111 ]

  # Remove the node from ProxySQL
  # Remove the first read node
  proxysql_exec "DELETE FROM mysql_servers WHERE hostname='${read_host[1]}' AND port=${read_port[1]} AND hostgroup_id=${read_hostgroup[1]}"
  [ "$?" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 2 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[1]}" -eq 1111 ]

  # Run the node monitor
  # The ndde should have been reinserted into ProxySQL
  run $(${NODE_MONITOR} ${NODE_MONITOR_ARGS} --log-text="node-monitor $LINENO")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[0]}" -eq 1111 ]
  [ "${read_max_connections[1]}" -eq 1111 ]
  [ "${read_max_connections[2]}" -eq 1111 ]
}

@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  #skip
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e with max-connections ($WSREP_CLUSTER_NAME)" {
  #skip
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writer-is-reader=ondemand --max-connections=2222 <<< 'n'
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


@test "run node-monitor node in PXC and NOT in ProxySQL with max-connections ($WSREP_CLUSTER_NAME)" {
  #skip
  # PREPARE for the test
  # ========================================================
  test_preparation
  verify_initial_state

  # Run the node monitor
  # (Nothing should have changed)
  run $(${NODE_MONITOR} ${NODE_MONITOR_ARGS} --log-text="node-monitor $LINENO")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[1]}" -eq 2222 ]
  [ "${read_max_connections[2]}" -eq 2222 ]

  # Remove the node from ProxySQL
  # Remove the first read node
  proxysql_exec "DELETE FROM mysql_servers WHERE hostname='${read_host[1]}' AND port=${read_port[1]} AND hostgroup_id=${read_hostgroup[1]}"
  [ "$?" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 2 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[1]}" -eq 2222 ]

  # Run the node monitor
  # The ndde should have been reinserted into ProxySQL
  run $(${NODE_MONITOR} ${NODE_MONITOR_ARGS} --log-text="node-monitor $LINENO" --max-connections=2222 --debug)
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#read_host[@]}" -eq 3 ]
  [ "${#write_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[0]}" -eq 2222 ]
  [ "${read_max_connections[1]}" -eq 2222 ]
  [ "${read_max_connections[2]}" -eq 2222 ]
}

