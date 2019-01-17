## proxysql-admin setup tests
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

@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -d
  echo "$output"
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -e  <<< 'n'
  echo "$output"
  [ "$status" -eq  0 ]
}

@test "run the check for cluster size ($WSREP_CLUSTER_NAME)" {
  #get values from PXC and ProxySQL side
  wsrep_cluster_count=$(cluster_exec "show status like 'wsrep_cluster_size'" | awk '{print $2}')
  proxysql_cluster_count=$(proxysql_exec "select count(*) from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) " | awk '{print $0}')
  [ "$wsrep_cluster_count" -eq "$proxysql_cluster_count" ]
}

@test "run the check for --node-check-interval ($WSREP_CLUSTER_NAME)" {
  wsrep_cluster_name=$(cluster_exec "select @@wsrep_cluster_name")
  report_interval=$(proxysql_exec "select interval_ms from scheduler where comment='$wsrep_cluster_name'" | awk '{print $0}')
  [ "$report_interval" -eq 3000 ]
}

@test "run the check for --adduser ($WSREP_CLUSTER_NAME)" {
  run_add_command=$(printf "proxysql_test_user1\ntest_user\ny" | sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --adduser)
  run_check_user_command=$(proxysql_exec "select 1 from mysql_users where username='proxysql_test_user1'" | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run proxysql-admin --syncusers ($WSREP_CLUSTER_NAME)" {
run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run the check for --syncusers ($WSREP_CLUSTER_NAME)" {

  local mysql_version=$(cluster_exec "select @@version")
  local pass_field
  if [[ $mysql_version =~ ^5.6 ]]; then
    pass_field="password"
  else
    pass_field="authentication_string"
  fi
  cluster_user_count=$(cluster_exec "select count(distinct user) from mysql.user where ${pass_field} != '' and user not in ('admin','mysql.sys','mysql.session')" -Ns)

  # HACK: this mismatch occurs because we're running the tests for cluster_two
  # right after the test for cluster_one (multi-cluster scenario), so the
  # user counts will be off (because user cluster_one will still be in proxysql users).
  if [[ $WSREP_CLUSTER_NAME == "cluster_two" ]]; then
    proxysql_user_count=$(proxysql_exec "select count(*) from mysql_users where username not in ('cluster_one')" | awk '{print $0}')
  else
    proxysql_user_count=$(proxysql_exec "select count(*) from mysql_users" | awk '{print $0}')
  fi
  echo "cluster_user_count:$cluster_user_count  proxysql_user_count:$proxysql_user_count" >&2
  [ "$cluster_user_count" -eq "$proxysql_user_count" ]
}

@test "run the check for updating runtime_mysql_servers table ($WSREP_CLUSTER_NAME)" {
  #skip
  # check initial writer info
  # Give proxysql a change to run the galera_checker script
  sleep 5
  first_writer_port=$(proxysql_exec "select port from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_status=$(proxysql_exec "select status from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_weight=$(proxysql_exec "select weight from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_comment=$(proxysql_exec "select comment from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_start_cmd=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:')
  first_writer_start_user=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|awk -F' ' '{print $1}')
  [ "$first_writer_status" = "ONLINE" ]
  [ "$first_writer_weight" = "1000000" ]
  [ "$first_writer_comment" = "WRITE" ]

  # check that the tables are equal at start
  mysql_servers=$(proxysql_exec "select * from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  runtime_mysql_servers=$(proxysql_exec "select * from runtime_mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]

  # shutdown writer
  pxc_socket=$(ps aux|grep "mysqld"|grep "port=$first_writer_port "|sed 's:^.* /:/:'|grep -o "\-\-socket=[^ ]* ")
  echo "Sending shutdown to $pxc_socket" >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown
  [ "$status" -eq 0 ]

  # This value is highly dependent on the PXC shutdown period
  #   --pxc_maint_transition_period
  wait_for_server_shutdown $pxc_socket 2
  [[ $? -eq 0 ]]

  # Wait a little extra time to ensure that the proxysql_galera_checker
  # was invoked
  sleep 15
  nr_nodes=$(proxysql_exec "select count(*) from mysql_servers where status='ONLINE' and hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID);")
  [ "$nr_nodes" -eq 2 ]

  # check new writer info
  second_writer_status=$(proxysql_exec "select status from mysql_servers where status='ONLINE' and hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  second_writer_weight=$(proxysql_exec "select weight from mysql_servers where status='ONLINE' and hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  second_writer_comment=$(proxysql_exec "select comment from mysql_servers where status='ONLINE' and hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  [ "$second_writer_status" = "ONLINE" ]
  [ "$second_writer_weight" = "1000000" ]
  [ "$second_writer_comment" = "WRITE" ]

  # bring the node up
  # remove the "--wsrep-new-cluster" from the command-line (no bootstrap)
  first_writer_start_cmd=$(echo "$first_writer_start_cmd" | sed "s/\-\-wsrep-new-cluster//g")
  nohup $first_writer_start_cmd --user=$first_writer_start_user 3>&- &
  sleep 15
  nr_nodes=$(proxysql_exec "select count(*) from mysql_servers where status='ONLINE' and hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID);" 2>/dev/null)
  [ "$nr_nodes" = "3" ]

  # check that the tables are equal at end
  mysql_servers=$(proxysql_exec "select * from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  runtime_mysql_servers=$(proxysql_exec "select * from runtime_mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]
}

@test "run the check for --quick-demo ($WSREP_CLUSTER_NAME)" {
  #skip
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable --quick-demo <<< n
  [ "$status" -eq 0 ]
  echo "$output" >&2
  [ "${lines[7]}" = "You have selected No. Terminating." ]
}

