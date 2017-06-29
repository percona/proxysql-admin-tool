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


@test "run the check for --test-run" {
  run sudo  ./proxysql-admin  --enable --quick-demo <<< n
  #echo "$output"
  echo "$output"
  echo "${lines[8]}"
    [ "$status" -eq 0 ]
    #[ "${lines[10]}" = "You have selected No. Terminating." ]
}
