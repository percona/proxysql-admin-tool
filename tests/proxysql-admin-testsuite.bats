## proxysql-admin setup tests

#
# Variable initialization
#
source /etc/proxysql-admin.cnf
PXC_BASEDIR=$WORKDIR/pxc-bin
PROXYSQL_BASEDIR=$WORKDIR/proxysql-bin

function exec_sql() {
  local user=$1
  local password=$2
  local hostname=$3
  local port=$4
  local query=$5
  local args=""
  local retvalue
  local retoutput

  if [[ $# -ge 6 ]]; then
    args=$6
  fi

  retoutput=$(printf "[client]\nuser=${user}\npassword=\"${password}\"\nhost=${hostname}\nport=${port}"  \
      | $PXC_BASEDIR/bin/mysql --defaults-file=/dev/stdin --protocol=tcp \
            --skip-column_names --unbuffered --batch --silent ${args} -e "${query}")
  retvalue=$?

  printf "${retoutput//%/%%}"
  return $retvalue
}

function proxysql_exec() {
  local query=$1
  local args=""

  if [[ $# -ge 2 ]]; then
    args=$2
  fi

  exec_sql $PROXYSQL_USERNAME $PROXYSQL_PASSWORD \
           $PROXYSQL_HOSTNAME $PROXYSQL_PORT \
           "$query" "$args"

  return $?
}

function cluster_exec() {
  local query=$1
  local args=""

  if [[ $# -ge 2 ]]; then
    args=$2
  fi

  exec_sql $CLUSTER_USERNAME $CLUSTER_PASSWORD \
           $CLUSTER_HOSTNAME $CLUSTER_PORT \
           "$query" "$args"

  return $?
}

wsrep_cluster_name=$(cluster_exec "select @@wsrep_cluster_name" 2> /dev/null)

@test "run proxysql-admin -d (cluster name : $wsrep_cluster_name)" {
run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -d
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e (cluster name : $wsrep_cluster_name)" {
run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -e <<< 'n'
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run the check for cluster size (cluster name : $wsrep_cluster_name)" {
  #get values from PXC and ProxySQL side
  wsrep_cluster_count=$(cluster_exec "show status like 'wsrep_cluster_size'" | awk '{print $2}')
  proxysql_cluster_count=$(proxysql_exec "select count(*) from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) " | awk '{print $0}')
  [ "$wsrep_cluster_count" -eq "$proxysql_cluster_count" ]
}

@test "run the check for --node-check-interval (cluster name : $wsrep_cluster_name)" {
  wsrep_cluster_name=$(cluster_exec "select @@wsrep_cluster_name")
  report_interval=$(proxysql_exec "select interval_ms from scheduler where comment='$wsrep_cluster_name'" | awk '{print $0}')
  [ "$report_interval" -eq 3000 ]
}

@test "run the check for --adduser (cluster name : $wsrep_cluster_name)" {
  run_add_command=$(printf "proxysql_test_user1\ntest_user\ny" | sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --adduser)
  run_check_user_command=$(proxysql_exec "select 1 from mysql_users where username='proxysql_test_user1'" | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run proxysql-admin --syncusers (cluster name : $wsrep_cluster_name)" {
run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run the check for --syncusers (cluster name : $wsrep_cluster_name)" {
  cluster_user_count=$(cluster_exec "select count(*) from mysql.user where authentication_string!='' and user not in ('admin','mysql.sys','mysql.session')" | awk '{print $1}')
  # HACK: this mismatch occurs because we're running the tests for cluster_two
  # right after the test for cluster_one (multi-cluster scenario), so the
  # user counts will be off (because user cluster_one will still be in proxysql users).
  if [[ $wsrep_cluster_name == "cluster_two" ]]; then
    proxysql_user_count=$(proxysql_exec "select count(*) from mysql_users where username not in ('cluster_one')" | awk '{print $0}')
  else
    proxysql_user_count=$(proxysql_exec "select count(*) from mysql_users" | awk '{print $0}')
  fi
  [ "$cluster_user_count" -eq "$proxysql_user_count" ]
}

@test "run the check for updating runtime_mysql_servers table (cluster name : $wsrep_cluster_name)" {
  # check initial writer info
  first_writer_port=$(proxysql_exec "select port from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_status=$(proxysql_exec "select status from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_weight=$(proxysql_exec "select weight from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_comment=$(proxysql_exec "select comment from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  first_writer_start_cmd=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:')
  first_writer_start_user=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|awk -F' ' '{print $1}')
  [ "$first_writer_status" = "ONLINE" ]
  [ "$first_writer_weight" = "1000000" ]
  [ "$first_writer_comment" = "WRITE" ]

  echo "first_writer_start_cmd = $first_writer_start_cmd" >&2

  # check that the tables are equal at start
  mysql_servers=$(proxysql_exec "select * from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  runtime_mysql_servers=$(proxysql_exec "select * from runtime_mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]

  # shutdown writer
  pxc_bindir=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:'|grep -o "^.*bin/")
  pxc_socket=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:'|grep -o "\-\-socket=.* ")
  echo "Sendinig shutdown to $pxc_socket" >&2
  $PXC_BASEDIR/bin/mysqladmin $pxc_socket -u root shutdown

  # This value is highly dependent on the PXC shutdown period
  #   --pxc_maint_transition_period
  sleep 5
  nr_nodes=$(proxysql_exec "select count(*) from mysql_servers where status='ONLINE' and hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID);" 2>/dev/null)
  [ "$nr_nodes" -eq 2 ]

  # check new writer info
  second_writer_status=$(proxysql_exec "select status from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  second_writer_weight=$(proxysql_exec "select weight from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  second_writer_comment=$(proxysql_exec "select comment from mysql_servers where hostgroup_id='$WRITE_HOSTGROUP_ID';" 2>/dev/null)
  [ "$second_writer_status" = "ONLINE" ]
  [ "$second_writer_weight" = "1000000" ]
  [ "$second_writer_comment" = "WRITE" ]

  # bring the node up
  first_writer_start_cmd=$(echo $first_writer_start_cmd|sed 's:--wsrep_cluster_address.*--wsrep_provider_options:--wsrep_provider_options:')
  cluster_address=$(ps aux|grep mysqld | grep $wsrep_cluster_name | grep -o "\-\-wsrep_cluster_address=gcomm.* --wsrep_provider_options"|sort|head -n1|grep -o ",gcomm.*,"|sed 's/^,//'|sed 's/,$//')
  first_writer_start_cmd="$first_writer_start_cmd --wsrep_cluster_address=$cluster_address"
  nohup $first_writer_start_cmd --user=$first_writer_start_user 3>- &
  sleep 15
  nr_nodes=$(proxysql_exec "select count(*) from mysql_servers where status='ONLINE' and hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID);" 2>/dev/null)
  [ "$nr_nodes" = "3" ]

  # check that the tables are equal at end
  mysql_servers=$(proxysql_exec "select * from mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  runtime_mysql_servers=$(proxysql_exec "select * from runtime_mysql_servers where hostgroup_id in ($WRITE_HOSTGROUP_ID,$READ_HOSTGROUP_ID) order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]
}

@test "run the check for --quick-demo (cluster name : $wsrep_cluster_name)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable --quick-demo <<< n
  echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[3]}" = "You have selected No. Terminating." ]
}
