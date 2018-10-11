## proxysql-admin setup tests
#
# Testing Hints:
# If there is a problem in the test, it's useful to enable the "debug"
# flag to see the proxysql_galera_checker and galera_node_monitor
# debug output.  The "--debug" flag must go INSIDE the duoble quotes.
#
#      run $(${galera_checker} "${galera_checker_args} --debug")
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

declare GALERA_CHECKER
declare GALERA_CHECKER_ARGS


load test-common

WSREP_CLUSTER_NAME=$(cluster_exec "select @@wsrep_cluster_name" 2> /dev/null)
MYSQL_VERSION=$(cluster_exec "select @@version")

function test_preparation() {
  local sched_id
  sched_id=$(proxysql_exec "SELECT id FROM scheduler WHERE arg1 like '% --write-hg=$WRITE_HOSTGROUP_ID %'")
  GALERA_CHECKER=$(proxysql_exec "SELECT filename FROM scheduler WHERE id=$sched_id")
  GALERA_CHECKER_ARGS=$(proxysql_exec "SELECT arg1 FROM scheduler WHERE id=$sched_id")
}

function verify_initial_state() {
  local writer_is_reader_type=$1

  # run once to initialize
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  if [[ $writer_is_reader_type == "never" ]]; then
    # Check the initial setup (3 rows in the table, all ONLINE)
    [ "${#read_host[@]}" -eq 2 ]
    [ "${#write_host[@]}" -eq 1 ]

    [ "${read_status[0]}" = "ONLINE" ]
    [ "${read_status[1]}" = "ONLINE" ]
    [ "${write_status[0]}" = "ONLINE" ]

    [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
    [ "${read_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
    [ "${read_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]

    [ "${write_comment[0]}" = "WRITE" ]
    [ "${read_comment[0]}" = "READ" ]
    [ "${read_comment[1]}" = "READ" ]

    [ "${write_weight[0]}" = "1000000" ]
    [ "${read_weight[0]}" = "1000" ]
    [ "${read_weight[1]}" = "1000" ]

  elif [[ $writer_is_reader_type == "always" ]]; then
    [ "${#read_host[@]}" -eq 3 ]
    [ "${#write_host[@]}" -eq 1 ]

    [ "${write_status[0]}" = "ONLINE" ]
    [ "${read_status[0]}" = "ONLINE" ]
    [ "${read_status[1]}" = "ONLINE" ]
    [ "${read_status[2]}" = "ONLINE" ]

    [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
    [ "${read_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
    [ "${read_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]
    [ "${read_hostgroup[2]}" -eq $READ_HOSTGROUP_ID ]

    [ "${write_comment[0]}" = "WRITE" ]
    [ "${read_comment[0]}" = "READ" ]
    [ "${read_comment[1]}" = "READ" ]
    [ "${read_comment[2]}" = "READ" ]

    [ "${write_weight[0]}" = "1000000" ]
    [ "${read_weight[0]}" = "1000" ]
    [ "${read_weight[1]}" = "1000" ]
    [ "${read_weight[2]}" = "1000" ]

  elif [[ $writer_is_reader_type == "ondemand" ]]; then
    [ "${#read_host[@]}" -eq 3 ]
    [ "${#write_host[@]}" -eq 1 ]

    [ "${write_status[0]}" = "ONLINE" ]
    [ "${read_status[0]}" = "OFFLINE_SOFT" ]
    [ "${read_status[1]}" = "ONLINE" ]
    [ "${read_status[2]}" = "ONLINE" ]

    [ "${read_port[0]}" -eq "${write_port[0]}" ]

    [ "${write_hostgroup[0]}" -eq $WRITE_HOSTGROUP_ID ]
    [ "${read_hostgroup[0]}" -eq $READ_HOSTGROUP_ID ]
    [ "${read_hostgroup[1]}" -eq $READ_HOSTGROUP_ID ]
    [ "${read_hostgroup[2]}" -eq $READ_HOSTGROUP_ID ]

    [ "${write_comment[0]}" = "WRITE" ]
    [ "${read_comment[0]}" = "READ" ]
    [ "${read_comment[1]}" = "READ" ]
    [ "${read_comment[2]}" = "READ" ]

    [ "${write_weight[0]}" = "1000000" ]
    [ "${read_weight[0]}" = "1000" ]
    [ "${read_weight[1]}" = "1000" ]
    [ "${read_weight[2]}" = "1000" ]

  fi
}

@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -d
  echo "$output"
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -e --writer-is-reader=never <<< 'n'
  echo "$output"
  [ "$status" -eq  0 ]
}


@test "run proxysql_galera_checker ($WSREP_CLUSTER_NAME)" {
  #skip

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation

  # run once as a test
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  # REACTIVATE the scheduler
  # ========================================================
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
}

@test "deactivate the scheduler for the rest of the test" {
  #
  # DEACTIVATE the scheduler line (call proxysql_galera_checker manually)
  # ========================================================
  local sched_id
  sched_id=$(proxysql_exec "SELECT id FROM scheduler WHERE arg1 like '% --write-hg=$WRITE_HOSTGROUP_ID %'")
  proxysql_exec "UPDATE scheduler SET active=0 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
}


@test "test --writer-is-reader=never stop/start a reader ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for stopping a reader
  # This will stop a reader node.
  # ========================================================
  local port host
  host=${read_host[0]}
  port=${read_port[0]}
  write_port=${write_port[0]}

  # Save variables for restart
  local restart_cmd pxc_socket restart_user
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")

  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk -F' ' '{print $1}')

  # shutdown reader node
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Shutting down reader node : $host:$port..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown
  [ "$status" -eq 0 ]

  # Run the checker, should move reader to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${read_port[0]}" -eq $port ]

  [ "${read_comment[0]}" = "READ" ]
  [ "${read_weight[0]}" -eq 1000 ]

  # Run the checker again, should move to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${read_port[0]}" -eq $port ]

  # Ensure that this hasn't changed
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_weight[0]}" -eq 1000 ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${read_port[0]}" -eq $port ]

  # Ensure that this hasn't changed
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_weight[0]}" -eq 1000 ]


  # TEST for adding a reader
  # This will restart the reader node stopped above.
  # ========================================================

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker, node should become ONLINE again
  # (all nodes online)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
}


@test "test --writer-is-reader=never stop/start a writer ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for stopping a writer
  # This will stop a writer node.
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down writer node : $host:$port..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  # nodes are ordered by status,host,port,hostgroup
  # so OFFLINE nodes come before ONLINE nodes
  retrieve_reader_info
  retrieve_writer_info

  new_writer_port=${write_port[0]}

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  # We expect the OFFLINE node to be the writer that was stopped
  [ "${read_port[0]}" -eq $port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # Run the checker, should move writer to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]

  # Expect the write port to stay the same
  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]
  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST for restarting the writer
  # This will restart the writer node stopped above.
  # ========================================================

  # Restart the writer that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
}


@test "test --writer-is-reader=never disable/enable a reader ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for disabling reader (w pxc_maint_mode)
  # ========================================================
  host=${read_host[0]}
  port=${read_port[0]}
  if [[ $port == ${write_port[0]} ]]; then
    port=${read_port[1]}
  fi

  echo "$LINENO Disabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]
  [[ ${write_port[0]} -ne ${read_port[0]} && ${write_port[0]} -ne ${read_port[1]} ]]
 
  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # Run the checker again, should not change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]
  [[ ${write_port[0]} -ne ${read_port[0]} && ${write_port[0]} -ne ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]


  # TEST for enabling reader (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [[ ${write_port[0]} -ne ${read_port[0]} && ${write_port[0]} -ne ${read_port[1]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

}


@test "test --writer-is-reader=never disable/enable a writer ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for disabling writer (w pxc_maint_mode)
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}

  echo "$LINENO Disabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make writer into an OFFLINE_SOFT reader
  # (Node is still counted as a writer)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # After the first galera_checker pass, the node_monitor will not have
  # changed anything (since it does not check the wsrep state)
  # However, the galera_checker (which does check the wsrep state) will
  # move the writer to OFFLINE_SOFT and will then pick a new writer node.
  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 1 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $port ]
  new_writer_port=${write_port[1]}

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${write_comment[1]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_weight[1]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]

  # Run the checker again, should move the OFFLINE_SOFT writer to
  # an OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  # Check that the new writer hasn't changed
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]


  # Run the checker again, should have no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  # Check that the new writer hasn't changed
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST for enabling writer (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
}


@test "test --writer-is-reader=never stopping all readers ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for dropping all readers (all at once)
  # ========================================================
  writer_port=${write_port[0]}
  reader_port1=${read_port[0]}
  reader_port2=${read_port[1]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd1=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row | awk '{ print $1 }')

  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port2")
  restart_cmd2=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user2=$(echo $ps_row | awk '{ print $1 }')

  # shutdown reader nodes
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Shutting down reader node 2 : $host:$reader_port2..." >&2
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, moves disconnected nodes to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # Run the checker, should move OFFLINE_SOFT to OFFLINE_HARD
  # (because the nodes are no longer appear in the cluster)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST bringing a reader back
  # ========================================================
  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST bringing another reader back (all readers back)
  # ========================================================
  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make all readers ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
}


@test "test --writer-is-reader=never disabling all readers ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST for disabling all readers (all at once) (w/ pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  reader_port1=${read_port[0]}
  reader_port2=${read_port[1]}

  echo "$LINENO Disabling reader node 1 : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # Run the checker again, shouldn't change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST enabling a reader (w/pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # TEST enabling a reader (w/pxc_maint_mode) (all readers back)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

}


@test "test --writer-is-reader=never mix stop/disable ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/never/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "never"

  # TEST by taking two reader nodes (one via shutdown the other with pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  reader_port1=${read_port[0]}
  reader_port2=${read_port[1]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should move readers to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]


  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq $reader_port1 ]
  [ "${read_port[1]}" -eq $reader_port2 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # RESTART the nodes (to get the system back to normal)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 2 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]

  # REACTIVATE the scheduler
  # ========================================================
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
}


@test "test --writer-is-reader=always stop/start a reader ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for stopping a reader
  # ========================================================
  local port host
  host=${write_host[0]}
  write_port=${write_port[0]}

  # find a reader that is not the writer
  port=${read_port[0]}
  if [[ $port -eq ${write_port[0]} ]]; then
    port=${read_port[1]}
  fi

  # Save variables for restart
  local restart_cmd pxc_socket restart_user
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")

  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk -F' ' '{print $1}')

  # shutdown reader node
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Shutting down reader node : $host:$port..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown
  [ "$status" -eq 0 ]

  # Run the checker, should move to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "${write_port}" ]
  [ "${read_port[0]}" -eq "${port}" ]

  # The writer should be one of the ONLINE readers
  [[ ${write_port} -eq ${read_port[1]} || ${write_port} -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should move to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "${write_port}" ]
  [ "${read_port[0]}" -eq "${port}" ]
  [[ ${write_port} -eq ${read_port[1]} || ${write_port} -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "${write_port}" ]
  [ "${read_port[0]}" -eq "${port}" ]
  [[ ${write_port} -eq ${read_port[1]} || ${write_port} -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST for creating a reader
  # ========================================================

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker again, row should have become a reader again
  # (all nodes online)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_port[0]}" -eq $write_port ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
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
}


@test "test --writer-is-reader=always stop/start a writer ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for stopping a writer
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}
  old_writer_port=${write_port[0]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down writer node : $host:$port..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  # nodes are ordered by status,host,port,hostgroup
  # so OFFLINE nodes come before ONLINE nodes
  retrieve_reader_info
  retrieve_writer_info

  new_writer_port=${write_port[0]}

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${old_writer_port}" -eq "${read_port[0]}" ]
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move writer to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $old_writer_port ]
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Expect the write port to stay the same
  [ "${write_port[0]}" -eq $new_writer_port ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $old_writer_port ]
  [ "${write_port[0]}" -eq $new_writer_port ]
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST for restarting the writer
  # ========================================================

  # Restart the writer that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting previous writer node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=always disable/enable a reader ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for disabling reader (w pxc_maint_mode)
  # ========================================================
  host=${read_host[0]}
  port=${read_port[0]}
  if [[ "$port" -eq "${write_port[0]}" ]]; then
    port=${read_port[1]}
  fi
  writer_port=${write_port[0]}

  echo "$LINENO Disabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should not change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $port ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST for enabling reader (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=always disable/enable a writer ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for disabling writer (w pxc_maint_mode)
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}

  echo "$LINENO Disabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make writer into an OFFLINE_SOFT reader
  # (Node is still counted as a writer)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # After the first galera_checker pass, the node_monitor will not have
  # changed anything (since it does not check the wsrep state)
  # However, the galera_checker (which does check the wsrep state) will
  # move the writer to OFFLINE_SOFT and will then pick a new writer node.
  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $port ]
  [ "${write_port[0]}" -eq "${read_port[0]}" ]

  new_writer_port=${write_port[1]}

  # The new online writer is also an online reader
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

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

  # Run the checker again, should move the OFFLINE_SOFT writer to
  # an OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  # Check that the new writer hasn't changed
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $port ]
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should have no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $port ]
  [[ $new_writer_port -eq ${read_port[1]} || $new_writer_port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST for enabling writer (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  # writer node shouldn't change
  [ "${write_port[0]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=always stopping all readers ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for dropping all readers (all at once)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd1=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row | awk '{ print $1 }')

  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port2")
  restart_cmd2=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user2=$(echo $ps_row | awk '{ print $1 }')

  # shutdown reader nodes
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Shutting down reader node 2 : $host:$reader_port2..." >&2
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, moves disconnected nodes to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move OFFLINE_SOFT to OFFLINE_HARD
  # (because the nodes are no longer appear in the cluster)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST bringing a reader back
  # ========================================================
  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket 2

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $reader_port2 ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST bringing another reader back (all readers back)
  # ========================================================
  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make all readers ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=always disabling all readers ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST for disabling all readers (all at once) (w/ pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  echo "$LINENO Disabling reader node 1 : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${write_port[0]}" -eq "${read_port[2]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, shouldn't change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${write_port[0]}" -eq "${read_port[2]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST enabling a reader (w/pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST enabling a reader (w/pxc_maint_mode) (all readers back)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=always mix stop/disable  ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/always/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "always"

  # TEST by taking two reader nodes (one via shutdown the other with pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should move readers to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq $reader_port1 ]
  [ "${read_port[1]}" -eq $reader_port2 ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # RESTART the nodes (to get the system back to normal)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "ONLINE" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]

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
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
}


@test "test --writer-is-reader=ondemand stop/start a reader ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"

  # TEST for stopping a reader
  # ========================================================
  local port host

  # read_port[0] is OFFLINE_SOFT and is the writer node
  # so  use read_port[1]
  host=${read_host[1]}
  port=${read_port[1]}

  writer_port=${write_port[0]}

  # Save variables for restart
  local restart_cmd pxc_socket restart_user
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")

  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk -F' ' '{print $1}')

  # shutdown reader node
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Shutting down reader node : $host:$port..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown
  [ "$status" -eq 0 ]

  # Run the checker, should move to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [[ ${read_port[0]} -eq $write_port || ${read_port[1]} -eq $write_port ]]
  [[ ${read_port[0]} -eq $port || ${read_port[1]} -eq $port ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should move to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${read_port[0]}" -eq "$port" ]
  [ "${read_port[1]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${read_port[0]}" -eq "$port" ]
  [ "${read_port[1]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST for creating a reader
  # ========================================================

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker again, row should have become a reader again
  # (all nodes online)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_port[0]}" -eq $write_port ]
  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq "${write_port[0]}" ]
  [[ $port -eq ${read_port[1]} || $port -eq ${read_port[2]} ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand stop/start a writer ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"

  # TEST for stopping a writer
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}
  old_writer_port=${write_port[0]}

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$port")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down writer node : $host:$port..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, should move writer to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS}")
  [ "$status" -eq 0 ]

  # nodes are ordered by status,host,port,hostgroup
  # so OFFLINE nodes come before ONLINE nodes
  retrieve_reader_info
  retrieve_writer_info

  new_writer_port=${write_port[0]}

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [[ "${new_writer_port}" -eq "${read_port[0]}" || "${new_writer_port}" -eq "${read_port[1]}" ]]
  [[ "${old_writer_port}" -eq "${read_port[0]}" || "${old_writer_port}" -eq "${read_port[1]}" ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move writer to OFFLINE_HARD
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]
  [ "${read_port[0]}" -eq $old_writer_port ]

  # Expect the write port to stay the same
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $old_writer_port ]
  [ "${read_port[1]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should have no change
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $old_writer_port ]
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq $old_writer_port ]
  [ "${read_port[1]}" -eq $new_writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST for restarting the writer
  # ========================================================

  # Restart the writer that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$port..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand disable/enable a reader ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"

  # TEST for disabling reader (w pxc_maint_mode)
  # ========================================================

  # read_port[0] is the writer node, so use read_port[1]
  port=${read_port[1]}
  writer_port=${write_port[0]}

  echo "$LINENO Disabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [[ "${writer_port}" -eq "${read_port[0]}" || "${writer_port}" -eq "${read_port[1]}" ]]
  [[ "${port}" -eq "${read_port[0]}" || "${port}" -eq "${read_port[1]}" ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, should not change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [[ "${writer_port}" -eq "${read_port[0]}" || "${writer_port}" -eq "${read_port[1]}" ]]
  [[ "${port}" -eq "${read_port[0]}" || "${port}" -eq "${read_port[1]}" ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST for enabling reader (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand disable/enable a writer ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"

  # TEST for disabling writer (w pxc_maint_mode)
  # ========================================================
  host=${write_host[0]}
  port=${write_port[0]}
  old_writer_port=$port

  echo "$LINENO Disabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make writer into an OFFLINE_SOFT reader
  # (Node is still counted as a writer)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  # After the first galera_checker pass, the node_monitor will not have
  # changed anything (since it does not check the wsrep state)
  # However, the galera_checker (which does check the wsrep state) will
  # move the writer to OFFLINE_SOFT and will then pick a new writer node.
  new_writer_port=${write_port[1]}

  [ "${#write_host[@]}" -eq 2 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "OFFLINE_SOFT" ]
  [ "${write_status[1]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq "$old_writer_port" ]
  [[ "${old_writer_port}" -eq "${read_port[0]}" || "${old_writer_port}" -eq "${read_port[1]}" ]]
  [[ "${new_writer_port}" -eq "${read_port[0]}" || "${new_writer_port}" -eq "${read_port[1]}" ]]

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


  # Run the checker again, should remove the OFFLINE_SOFT writer
  # (it will leave behind the OFFLINE_SOFT reader entry)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  # Check that the new writer hasn't changed
  [ "${write_port[0]}" -eq $new_writer_port ]
  [[ "${old_writer_port}" -eq "${read_port[0]}" || "${old_writer_port}" -eq "${read_port[1]}" ]]
  [[ "${new_writer_port}" -eq "${read_port[0]}" || "${new_writer_port}" -eq "${read_port[1]}" ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Run the checker again, should have no changes
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $new_writer_port ]
  [[ "${old_writer_port}" -eq "${read_port[0]}" || "${old_writer_port}" -eq "${read_port[1]}" ]]
  [[ "${new_writer_port}" -eq "${read_port[0]}" || "${new_writer_port}" -eq "${read_port[1]}" ]]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST for enabling writer (w pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling writer node : $host:$port..." >&2
  run mysql_exec "$host" "$port" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker again, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  # writer node shouldn't change
  [ "${write_port[0]}" -eq $new_writer_port ]
  [ "${read_port[0]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand stopping all readers ($WSREP_CLUSTER_NAME)" {
  #skip

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"

  # TEST for dropping all readers (all at once)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd1=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user1=$(echo $ps_row | awk '{ print $1 }')

  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port2")
  restart_cmd2=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user2=$(echo $ps_row | awk '{ print $1 }')

  # shutdown reader nodes
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Shutting down reader node 2 : $host:$reader_port2..." >&2
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # Run the checker, moves disconnected nodes to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker, should move OFFLINE_SOFT to OFFLINE_HARD
  # (because the nodes are no longer appear in the cluster)
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_HARD" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST bringing a reader back
  # ========================================================
  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd1 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd1" "$restart_user1"
  wait_for_server_start $pxc_socket 2

  # Run the checker, should make reader ONLINE
  # Will also take the reader (for the writer node) to OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${read_port[0]}" -eq $reader_port2 ]
  [ "${read_port[1]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $reader_port1 ]
  [ "${write_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # TEST bringing another reader back (all readers back)
  # ========================================================
  writer_port=${write_port[0]}

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd2 | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port2..." >&2
  restart_server "$restart_cmd2" "$restart_user2"
  wait_for_server_start $pxc_socket 3

  # Run the checker, should make all readers ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq "${write_port[0]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand disabling all readers ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"


  # TEST for disabling all readers (all at once) (w/ pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  echo "$LINENO Disabling reader node 1 : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader OFFLINE_SOFT
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${write_port[0]}" -eq "${read_port[2]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]

  # Run the checker again, shouldn't change anything
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${write_port[0]}" -eq "${read_port[2]}" ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST enabling a reader (w/pxc_maint_mode)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port1..." >&2
  run mysql_exec "$host" "$reader_port1" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [[ "${writer_port}" -eq "${read_port[0]}" || "${writer_port}" -eq "${read_port[1]}" ]]
  [[ "${reader_port2}" -eq "${read_port[0]}" || "${reader_port2}" -eq "${read_port[1]}" ]]
  [ "${read_port[2]}" -eq $reader_port1 ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # TEST enabling a reader (w/pxc_maint_mode) (all readers back)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Run the checker, should make reader ONLINE
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]
}


@test "test --writer-is-reader=ondemand mix stop/disable ($WSREP_CLUSTER_NAME)" {
  #skip
  require_pxc_maint_mode

  # SYNC up with the runtime
  # (For a consistent starting point)
  # ========================================================
  proxysql_exec "SAVE mysql servers FROM RUNTIME"

  # SETUP (determine some of the parameters, such as READ/WRITE nodes)
  # Also check the initial state (so it's in a known starting state)
  # ========================================================
  test_preparation
  GALERA_CHECKER_ARGS=$(echo "$GALERA_CHECKER_ARGS" | sed "s/never/ondemand/g")

  # Echo this here, so that when an error occurs we can see the
  # galera_checker arguments
  echo "$LINENO $GALERA_CHECKER_ARGS" >&2

  verify_initial_state "ondemand"



  # TEST by taking two reader nodes (one via shutdown the other with pxc_maint_mode)
  # ========================================================
  writer_port=${write_port[0]}
  if [[ $writer_port -eq ${read_port[0]} ]]; then
    reader_port1=${read_port[1]}
    reader_port2=${read_port[2]}
  elif [[ $writer_port -eq ${read_port[1]} ]]; then
    reader_port1=${read_port[0]}
    reader_port2=${read_port[2]}
  else
    reader_port1=${read_port[0]}
    reader_port2=${read_port[1]}
  fi

  # Save variables for restart
  ps_row=$(ps aux | grep "mysqld" | grep "port=$reader_port1")
  restart_cmd=$(echo $ps_row | sed 's:^.* /:/:')
  restart_user=$(echo $ps_row | awk '{ print $1 }')

  # shutdown writer node
  echo "$LINENO Shutting down reader node 1 : $host:$reader_port1..." >&2
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  echo "$LINENO Disabling reader node 2 : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='maintenance'"
  [ "$status" -eq 0 ]

  # Run the checker, should move readers to OFFLINE_SOFT reader
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # Run the checker again
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_HARD" ]
  [ "${read_status[1]}" = "OFFLINE_SOFT" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq $reader_port1 ]
  [ "${read_port[1]}" -eq $reader_port2 ]
  [ "${read_port[2]}" -eq $writer_port ]

  [ "${write_comment[0]}" = "WRITE" ]
  [ "${read_comment[0]}" = "READ" ]
  [ "${read_comment[1]}" = "READ" ]
  [ "${read_comment[2]}" = "READ" ]

  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${read_weight[0]}" -eq 1000 ]
  [ "${read_weight[1]}" -eq 1000 ]
  [ "${read_weight[2]}" -eq 1000 ]


  # RESTART the nodes (to get the system back to normal)
  # ========================================================
  echo "$LINENO Enabling reader node : $host:$reader_port2..." >&2
  run mysql_exec "$host" "$reader_port2" "SET global pxc_maint_mode='disabled'"
  [ "$status" -eq 0 ]

  # Restart the reader that was stopped above
  pxc_socket=$(echo $restart_cmd | grep -o "\-\-socket=[^ ]* ")
  echo "$LINENO Starting reader node : $host:$reader_port1..." >&2
  restart_server "$restart_cmd" "$restart_user"
  wait_for_server_start $pxc_socket 3

  # Run the checker
  run $(${GALERA_CHECKER} "${GALERA_CHECKER_ARGS} --log-text='writer-is-reader $LINENO'")
  [ "$status" -eq 0 ]

  retrieve_reader_info
  retrieve_writer_info

  [ "${#write_host[@]}" -eq 1 ]
  [ "${#read_host[@]}" -eq 3 ]

  [ "${write_status[0]}" = "ONLINE" ]
  [ "${read_status[0]}" = "OFFLINE_SOFT" ]
  [ "${read_status[1]}" = "ONLINE" ]
  [ "${read_status[2]}" = "ONLINE" ]

  [ "${write_port[0]}" -eq $writer_port ]
  [ "${read_port[0]}" -eq $writer_port ]
  [[ "${reader_port1}" -eq "${read_port[1]}" || "${reader_port1}" -eq "${read_port[2]}" ]]
  [[ "${reader_port2}" -eq "${read_port[1]}" || "${reader_port2}" -eq "${read_port[2]}" ]]

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
  #proxysql_exec "UPDATE scheduler SET active=1 WHERE id=$sched_id; LOAD scheduler TO RUNTIME"
}

# Test full cluster shutdown
# Test full cluster disable (with pxc_maint_mode)
