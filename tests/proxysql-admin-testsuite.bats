## proxysql-admin setup tests

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
  wsrep_cluster_count=$(mysql --user=proxysql_user -ppassw0rd  --host=localhost --port=6033 --protocol=tcp -Bse"show status like 'wsrep_cluster_size'" | awk '{print $2}')
  proxysql_cluster_count=$(mysql --user=admin --password=admin -h127.0.0.1 -P6032 -Bse "select count(*) from mysql_servers" | awk '{print $0}')
  [ "$wsrep_cluster_count" -eq "$proxysql_cluster_count" ]
}

@test "run the check for --node-check-interval" {
  report_interval=$(mysql --user=admin -padmin  --host=localhost --port=6032 --protocol=tcp -Bse"select interval_ms from scheduler where id=10" | awk '{print $0}')
  [ "$report_interval" -eq 3000 ]
}

@test "run the check for --adduser" {
  run_add_command=$(printf "proxysql_test_user1\ntest_user\ny" | sudo proxysql-admin --adduser)
  run_check_user_command=$(mysql --user=admin --password=admin -h127.0.0.1 -P6032 -Bse "select 1 from mysql_users where username='proxysql_test_user1'" | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run the check for --syncusers" {
  cluster_user_count=$(mysql --user=admin --password=admin  --host=localhost --port=21000 --protocol=tcp -Bse"select count(*) from mysql.user where authentication_string!='' and user not in ('admin','mysql.sys')" | awk '{print $1}')
  proxysql_user_count=$(mysql --user=admin --password=admin -h127.0.0.1 -P6032 -Bse "select count(*) from mysql_users" | awk '{print $0}')
  [ "$cluster_user_count" -eq "$proxysql_user_count" ]
}

@test "run proxysql-admin --syncusers" {
run sudo proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}
