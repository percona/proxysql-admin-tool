## proxysql-admin setup tests
source /etc/proxysql-admin.cnf

@test "run proxysql-admin -d" {
run sudo proxysql-admin -d
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e" {
run sudo proxysql-admin -e <<< 'n'
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run the check for cluster size" {
  #get values from PXC and ProxySQL side
  wsrep_cluster_count=$(mysql --user=$CLUSTER_APP_USERNAME --password=$CLUSTER_APP_PASSWORD  --host=$CLUSTER_HOSTNAME --port=6033 --protocol=tcp -Bse"show status like 'wsrep_cluster_size'" | awk '{print $2}')
  proxysql_cluster_count=$(mysql --user=$PROXYSQL_USERNAME --password=$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select count(*) from mysql_servers" | awk '{print $0}')
  [ "$wsrep_cluster_count" -eq "$proxysql_cluster_count" ]
}

@test "run the check for --node-check-interval" {
  report_interval=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD  --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse"select interval_ms from scheduler where id=10" | awk '{print $0}')
  [ "$report_interval" -eq 3000 ]
}

@test "run the check for --adduser" {
  run_add_command=$(printf "proxysql_test_user1\ntest_user\ny" | sudo proxysql-admin --adduser)
  run_check_user_command=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD  --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select 1 from mysql_users where username='proxysql_test_user1'" | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run proxysql-admin --syncusers" {
run sudo proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run the check for --syncusers" {
  cluster_user_count=$(mysql --user=$CLUSTER_USERNAME --password=$CLUSTER_PASSWORD  --host=$CLUSTER_HOSTNAME --port=$CLUSTER_PORT --protocol=tcp -Bse"select count(*) from mysql.user where authentication_string!='' and user not in ('admin','mysql.sys')" | awk '{print $1}')
  proxysql_user_count=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD  --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select count(*) from mysql_users" | awk '{print $0}')
  [ "$cluster_user_count" -eq "$proxysql_user_count" ]
}

@test "run the check for updating runtime_mysql_servers table" {
  # check initial writer info
  first_writer_port=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select port from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  first_writer_status=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select status from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  first_writer_weight=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select weight from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  first_writer_comment=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select comment from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  first_writer_start_cmd=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:')
  first_writer_start_user=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|awk -F' ' '{print $1}')
  [ "$first_writer_status" = "ONLINE" ]
  [ "$first_writer_weight" = "1000000" ]
  [ "$first_writer_comment" = "WRITE" ]

  # check that the tables are equal at start
  mysql_servers=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select * from mysql_servers order by port;" 2>/dev/null)
  runtime_mysql_servers=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select * from mysql_servers order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]

  # shutdown writer
  pxc_bindir=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:'|grep -o "^.*bin/")
  pxc_socket=$(ps aux|grep "mysqld"|grep "port=$first_writer_port"|sed 's:^.* /:/:'|grep -o "\-\-socket=.* ")
  $pxc_bindir/mysqladmin $pxc_socket -u root shutdown
  sleep 3
  nr_nodes=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select count(*) from mysql_servers where status='ONLINE';" 2>/dev/null)
  [ "$nr_nodes" = "2" ]

  # check new writer info
  second_writer_status=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select status from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  second_writer_weight=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select weight from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  second_writer_comment=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select comment from mysql_servers where hostgroup_id='10';" 2>/dev/null)
  [ "$second_writer_status" = "ONLINE" ]
  [ "$second_writer_weight" = "1000000" ]
  [ "$second_writer_comment" = "WRITE" ]

  # bring the node up
  first_writer_start_cmd=$(echo $first_writer_start_cmd|sed 's:--wsrep_cluster_address.*--wsrep_provider_options:--wsrep_provider_options:')
  cluster_address=$(ps aux|grep mysqld|grep -o "\-\-wsrep_cluster_address=gcomm.* --wsrep_provider_options"|sort|head -n1|grep -o ",gcomm.*,"|sed 's/^,//'|sed 's/,$//')
  first_writer_start_cmd="$first_writer_start_cmd --wsrep_cluster_address=$cluster_address"
  nohup $first_writer_start_cmd --user=$first_writer_start_user 3>- &
  sleep 3
  nr_nodes=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select count(*) from mysql_servers where status='ONLINE';" 2>/dev/null)
  [ "$nr_nodes" = "3" ]

  # check that the tables are equal at end
  mysql_servers=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select * from mysql_servers order by port;" 2>/dev/null)
  runtime_mysql_servers=$(mysql --user=$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD --host=$PROXYSQL_HOSTNAME --port=$PROXYSQL_PORT --protocol=tcp -Bse "select * from mysql_servers order by port;" 2>/dev/null)
  [ "$(echo \"$mysql_servers\"|md5sum)" = "$(echo \"$runtime_mysql_servers\"|md5sum)" ]
}

@test "run the check for --test-run" {
  run sudo proxysql-admin  --enable --quick-demo <<< n
  echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[3]}" = "You have selected No. Terminating." ]
}
