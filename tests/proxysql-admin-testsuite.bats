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

@test "check the cluster size" {
  wsrep_cluster_count=$(mysql --user=proxysql_user -ppassw0rd  --host=localhost --port=6033 --protocol=tcp -Bse"show status like 'wsrep_cluster_size'" | awk '{print $2}')
  proxysql_cluster_count=$(mysql --user=admin --password=admin -h127.0.0.1 -P6032 -Bse "select count(*) from mysql_servers" | awk '{print $0}')
  [ "$wsrep_cluster_count" -eq "$proxysql_cluster_count" ]
}

@test "run proxysql-admin --syncusers" {
run sudo proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}