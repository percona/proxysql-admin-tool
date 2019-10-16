## proxysql-admin setup tests
#


#
# Variable initialization
#
source /etc/proxysql-admin.cnf
PXC_BASEDIR=$WORKDIR/pxc-bin
PROXYSQL_BASEDIR=$WORKDIR/proxysql-bin
ALL_HOSTGROUPS="$WRITER_HOSTGROUP_ID,$READER_HOSTGROUP_ID,$BACKUP_WRITER_HOSTGROUP_ID,$OFFLINE_HOSTGROUP_ID"

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
if [[ $WSREP_CLUSTER_NAME == "cluster_one" ]]; then
  PORT_1=4110
  PORT_2=4120
  PORT_3=4130
else
  PORT_1=4210
  PORT_2=4220
  PORT_3=4230
fi

if [[ $USE_IPVERSION == "v6" ]]; then
  HOST_IP="::1"
else
  HOST_IP="127.0.0.1"
fi


@test "run proxysql-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -d
  echo "$output" >&2
  [ "$status" -eq  0 ]
}


@test "run proxysql-admin -e ($WSREP_CLUSTER_NAME)" {
  local pre_report_interval
  pre_report_interval=$(proxysql_exec \
                        "SELECT variable_value
                          FROM runtime_global_variables
                          WHERE
                            variable_name = 'mysql-monitor_galera_healthcheck_interval'" |
                      grep -v variable_value)

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -e  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]

  # Need some time for this to converge
  sleep 5

  # Test for default values
  local report_interval
  report_interval=$(proxysql_exec \
                      "SELECT variable_value
                        FROM runtime_global_variables
                        WHERE
                          variable_name = 'mysql-monitor_galera_healthcheck_interval'" |
                    grep -v variable_value)
  echo "report_interval:$report_interval expected:$pre_report_interval" >&2
  [ "$report_interval" -eq $pre_report_interval ]

  local data
  data=$(proxysql_exec \
          "SELECT
            writer_hostgroup,
            backup_writer_hostgroup,
            reader_hostgroup,
            offline_hostgroup,
            active,
            max_writers,
            writer_is_also_reader,
            max_transactions_behind
          FROM
            mysql_galera_hostgroups
          WHERE
            writer_hostgroup =$WRITER_HOSTGROUP_ID" "--silent --skip-column-names")
  local writer_hg reader_hg offline_hg backup_writer_hg
  local active max_writers writer_is_also_reader max_transactions_behind
  writer_hg=$(echo "$data" | cut -f1)
  backup_writer_hg=$(echo "$data" | cut -f2)
  reader_hg=$(echo "$data" | cut -f3)
  offline_hg=$(echo "$data" | cut -f4)

  echo "writer_hg:$writer_hg expected:$WRITER_HOSTGROUP_ID" >&2
  echo "reader_hg:$reader_hg expected:$READER_HOSTGROUP_ID" >&2
  echo "backup_wrter_hg:$backup_writer_hg expected:$BACKUP_WRITER_HOSTGROUP_ID" >&2
  echo "offline_hg:$offline_hg expected:$OFFLINE_HOSTGROUP_ID" >&2
  [[ $writer_hg -eq $WRITER_HOSTGROUP_ID ]]
  [[ $backup_writer_hg -eq $BACKUP_WRITER_HOSTGROUP_ID ]]
  [[ $reader_hg -eq $READER_HOSTGROUP_ID ]]
  [[ $offline_hg -eq $OFFLINE_HOSTGROUP_ID ]]

  active=$(echo "$data" | cut -f5)
  max_writers=$(echo "$data" | cut -f6)
  writer_is_also_reader=$(echo "$data" | cut -f7)
  max_transactions_behind=$(echo "$data" | cut -f8)

  echo "active:$active expected:1" >&2
  echo "max_writers:$active expected:1" >&2
  echo "writer_is_also_reader:$active expected:2" >&2
  echo "max_transactions_behind:$active expected:100" >&2
  [[ $active -eq 1 ]]
  [[ $max_writers -eq 1 ]]
  [[ $writer_is_also_reader -eq 2 ]]
  [[ $max_transactions_behind -eq 100 ]]
}


@test "run proxysql-admin --update-mysql-version ($WSREP_CLUSTER_NAME)" {

  local mysql_version=$(mysql_exec "$HOST_IP" "$PORT_3" "SELECT VERSION();" | tail -1 | cut -d'-' -f1)
  local proxysql_mysql_version=$(proxysql_exec "select variable_value from global_variables where variable_name like 'mysql-server_version'" | awk '{print $0}')
  echo "$LINENO: mysql_version:$mysql_version  proxysql_mysql_version:$proxysql_mysql_version" >&2
  if [[ $mysql_version != $proxysql_mysql_version ]]; then
  
    run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --update-mysql-version
    echo "$output" >&2
    [ "$status" -eq  0 ]

    mysql_version=$(mysql_exec "$HOST_IP" "$PORT_3" "SELECT VERSION();" | tail -1 | cut -d'-' -f1)
    proxysql_mysql_version=$(proxysql_exec "select variable_value from global_variables where variable_name like 'mysql-server_version'" | awk '{print $0}')
    echo "$LINENO: mysql_version:$mysql_version  proxysql_mysql_version:$proxysql_mysql_version" >&2
    [ "$mysql_version" = "$proxysql_mysql_version" ]
  else
    run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --update-mysql-version
    echo "$output" >&2
    [ "$status" -eq  0 ]
  fi
}

@test "run the check for --adduser ($WSREP_CLUSTER_NAME)" {
  run_add_command=$(printf "proxysql_test_user1\ntest_user\ny" | sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --adduser)
  run_check_user_command=$(proxysql_exec "select 1 from mysql_users where username='proxysql_test_user1'" | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run proxysql-admin --syncusers ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --syncusers
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run proxysql-admin --syncusers --add-query-rule ($WSREP_CLUSTER_NAME)" {
  # Check whether user and query rule exists in  ProxySQL DB
  run_check_user=$(proxysql_exec "select 1 from mysql_users where username='test_query_rule'" | awk '{print $0}')
  run_query_rule=$(proxysql_exec "select 1 from mysql_query_rules where username='test_query_rule'" | awk '{print $0}')
  echo "$LINENO : Check query rule user count(test_query_rule) :$run_check_user expected:0"  >&2
  [[ "$run_check_user" -eq 0 ]]
  echo "$LINENO : Check query rule count for user(test_query_rule):$run_query_rule expected:0"  >&2
  [[ "$run_query_rule" -eq 0 ]]
  mysql_exec "$HOST_IP" "$PORT_3" "create user test_query_rule@'%' identified by 'test';"
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --syncusers --add-query-rule
  echo "$output" >&2
  [ "$status" -eq  0 ]
  [ "${lines[4]}" = "  Added query rule for user: test_query_rule" ]
  run_write_hg_query_rule_user=$(proxysql_exec "select 1 from mysql_query_rules where username='test_query_rule' and match_digest='^SELECT.*FOR UPDATE'" | awk '{print $0}')
  echo "$LINENO : Query rule count for user 'test_query_rule' with writer hostgroup:$run_write_hg_query_rule_user expected:1"  >&2
  [[ "$run_write_hg_query_rule_user" -eq 1 ]]
  run_read_hg_query_rule_user=$(proxysql_exec "select 1 from mysql_query_rules where username='test_query_rule' and match_digest='^SELECT '" | awk '{print $0}')
  echo "$LINENO : Query rule count for user 'test_query_rule' with reader hostgroup:$run_read_hg_query_rule_user expected:1"  >&2
  [[ "$run_read_hg_query_rule_user" -eq 1 ]]
  
  # Dropping user 'test_query_rule' from MySQL server to test the query rule delete operation 
  mysql_exec "$HOST_IP" "$PORT_3" "drop user test_query_rule@'%';"
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --syncusers --add-query-rule
  echo "$output" >&2
  [ "$status" -eq  0 ]
  run_check_user=$(proxysql_exec "select 1 from mysql_users where username='test_query_rule'" | awk '{print $0}')
  run_query_rule=$(proxysql_exec "select 1 from mysql_query_rules where username='test_query_rule'" | awk '{print $0}')
  echo "$LINENO : Check query rule user count(test_query_rule) :$run_check_user expected:0"  >&2
  [[ "$run_check_user" -eq 0 ]]
  echo "$LINENO : Check query rule count for user(test_query_rule):$run_query_rule expected:0"  >&2
  [[ "$run_query_rule" -eq 0 ]]
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


@test "run the check for --quick-demo ($WSREP_CLUSTER_NAME)" {
  #skip
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable \
      --writer-hg=10 --reader-hg=11 --backup-writer-hg=12 \
      --offline-hg=13 --quick-demo <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ "${lines[7]}" = "You have selected No. Terminating." ]
}

@test "run the check for --force ($WSREP_CLUSTER_NAME)" {
  # Cleaning existing configuration to test --force option as normal run
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable --force <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 5
  
  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]
  
  # Run 'proxysql-admin --enable --force' without removing existing configuration
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable --force <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 5
  
  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]
  
  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # Check proxysql-admin run status without --force option
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --disable
  [ "$status" -eq 0 ]
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  
  # Check proxysql-admin run status with following options
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin  --enable --update-cluster --force  <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 5
  
  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]
  
  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]
}


@test "test for various parameter settings ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable \
    --max-connections=111 \
    --node-check-interval=11200 \
    --max-transactions-behind=113 <<< 'n'
  echo "$output" >&2
  [ "$status" -eq 0 ]

  # Give ProxySQL some time to converge
  sleep 5

  local data
  data=$(proxysql_exec \
          "SELECT
            active,
            max_transactions_behind
          FROM
            runtime_mysql_galera_hostgroups
          WHERE
            writer_hostgroup =$WRITER_HOSTGROUP_ID" "--silent --skip-column-names")
  local active max_transactions_behind

  active=$(echo "$data" | cut -f1)
  max_transactions_behind=$(echo "$data" | cut -f2)

  echo "active:$active expected:1" >&2
  echo "max_transactions_behind:$max_transactions_behind expected:113" >&2
  [[ $active -eq 1 ]]
  [[ $max_transactions_behind -eq 113 ]]

  local report_interval
  report_interval=$(proxysql_exec \
                      "SELECT variable_value
                        FROM runtime_global_variables
                        WHERE
                          variable_name = 'mysql-monitor_galera_healthcheck_interval'" |
                    grep -v variable_value)
  echo "report_interval:$report_interval expected:11200" >&2
  [ "$report_interval" -eq 11200 ]

  # Reset healthcheck interval value
  proxysql_exec "SET mysql-monitor_galera_healthcheck_interval = 2000; load MYSQL VARIABLES to runtime;"
}


@test "test for --writers-are-readers ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # -----------------------------------------------------------
  # Use default value for --writers-are-readers
  echo "$LINENO : proxysql-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]


  # -----------------------------------------------------------
  # Now run with --writers-are-readers=yes
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=yes" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=yes <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]


  # -----------------------------------------------------------
  # Now run with --writers-are-readers=no
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=no" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=no <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 0 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]


  # -----------------------------------------------------------
  # Use --writers-are-readers=backup
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=backup" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=backup <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]

}


@test "test for --writers-are-readers with a read-only node ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # -----------------------------------------------------------
  # change node3 to be a read-only node
  echo "$LINENO : changing node3 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=1"
  [ "$?" -eq 0 ]

  # -----------------------------------------------------------
  # Use default value for --writers-are-readers
  # This will fail because read-only nodes are not allowed in configurations
  # that use --writers-are-ready=backup (which is the default)
  echo "$LINENO : proxysql-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable <<< 'n'
  [ "$status" -eq 1 ]
  sleep 5

  # -----------------------------------------------------------
  # Now run with --writers-are-readers=yes
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=yes" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=yes <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 1 ]


  # -----------------------------------------------------------
  # Now run with --writers-are-readers=no
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=no" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=no <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 1 ]


  # -----------------------------------------------------------
  # Use --writers-are-readers=backup
  # This should fail because read-only nodes are not allowed when
  # --writers-are-readers=backup
  echo "$LINENO : proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  [ "$status" -eq 0 ]
  echo "$LINENO : proxysql-admin --enable --writers-are-readers=backup" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --writers-are-readers=backup <<< 'n'
  [ "$status" -eq 1 ]
  sleep 5


  # -----------------------------------------------------------
  # revert node3 to be a read/write node
  echo "$LINENO : changing node3 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=0"
  [ "$?" -eq 0 ]

}


# Test loadbal
@test "test for --mode=loadbal ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  echo "$LINENO : proxysql-admin --enable --mode=loadbal" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --mode=loadbal <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:0" >&2
  [ "$proxysql_cluster_count" -eq 0 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:0"  >&2
  [ "$proxysql_cluster_count" -eq 0 ]

  # Check values in mysql_galera_hostgroups
  local data
  data=$(proxysql_exec \
          "SELECT
            writer_hostgroup,
            backup_writer_hostgroup,
            reader_hostgroup,
            offline_hostgroup,
            active,
            max_writers,
            writer_is_also_reader,
            max_transactions_behind
          FROM
            mysql_galera_hostgroups
          WHERE
            writer_hostgroup =$WRITER_HOSTGROUP_ID" "--silent --skip-column-names")
  local writer_hg reader_hg offline_hg backup_writer_hg
  local active max_writers writer_is_also_reader max_transactions_behind
  writer_hg=$(echo "$data" | cut -f1)
  backup_writer_hg=$(echo "$data" | cut -f2)
  reader_hg=$(echo "$data" | cut -f3)
  offline_hg=$(echo "$data" | cut -f4)

  echo "writer_hg:$writer_hg expected:$WRITER_HOSTGROUP_ID" >&2
  echo "reader_hg:$reader_hg expected:$READER_HOSTGROUP_ID" >&2
  echo "backup_wrter_hg:$backup_writer_hg expected:$BACKUP_WRITER_HOSTGROUP_ID" >&2
  echo "offline_hg:$offline_hg expected:$OFFLINE_HOSTGROUP_ID" >&2
  [[ $writer_hg -eq $WRITER_HOSTGROUP_ID ]]
  [[ $backup_writer_hg -eq $BACKUP_WRITER_HOSTGROUP_ID ]]
  [[ $reader_hg -eq $READER_HOSTGROUP_ID ]]
  [[ $offline_hg -eq $OFFLINE_HOSTGROUP_ID ]]

  active=$(echo "$data" | cut -f5)
  max_writers=$(echo "$data" | cut -f6)
  writer_is_also_reader=$(echo "$data" | cut -f7)
  max_transactions_behind=$(echo "$data" | cut -f8)

  echo "active:$active expected:1" >&2
  echo "max_writers:$active expected:1000000" >&2
  echo "writer_is_also_reader:$active expected:0" >&2
  echo "max_transactions_behind:$active expected:100" >&2
  [[ $active -eq 1 ]]
  [[ $max_writers -eq 1000000 ]]
  [[ $writer_is_also_reader -eq 0 ]]
  [[ $max_transactions_behind -eq 100 ]]

}


# Test loadbal with a read-only node
@test "test for --mode=loadbal with a read-only node ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # -----------------------------------------------------------
  # change node3 to be a read-only node
  echo "$LINENO : changing node3 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=1"
  [ "$?" -eq 0 ]

  echo "$LINENO : proxysql-admin --enable --mode=loadbal" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --mode=loadbal <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 0 ]


  # -----------------------------------------------------------
  # revert node3 to be a read/write node
  echo "$LINENO : changing node3 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=0"
  [ "$?" -eq 0 ]

}


# Test singlewrite with --write-node
@test "test for --write-node ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # -----------------------------------------------------------
  echo "$LINENO : proxysql-admin --enable --write-node=${HOST_IP}:${PORT_2}" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --write-node=${HOST_IP}:${PORT_2} <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  #dump_runtime_nodes $LINENO "after write node"
  # Verify the weights on the nodes
  retrieve_writer_info $WRITER_HOSTGROUP_ID
  echo "write_weight[0]:${write_weight[0]}" >&2
  [ "${#write_host[@]}" -eq 1 ]
  [ "${write_weight[0]}" -eq 1000000 ]
  [ "${write_port[0]}" -eq $PORT_2 ]

  retrieve_writer_info $BACKUP_WRITER_HOSTGROUP_ID
  [ "${#write_host[@]}" -eq 2 ]
  [ "${write_weight[0]}" -eq 1000 ]
  [ "${write_weight[1]}" -eq 1000 ]

}


# Test singlewrite with --write-node is a read-only node
@test "test for --write-node on a read-only node ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # -----------------------------------------------------------
  # change node3 to be a read-only node
  echo "$LINENO : changing node3 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=1"
  [ "$?" -eq 0 ]

  # -----------------------------------------------------------
  # This should fail, since a write-node cannot be read-only
  echo "$LINENO : proxysql-admin --enable --write-node=${HOST_IP}:${PORT_2}" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable  --write-node=${HOST_IP}:${PORT_2} <<< 'n'
  [ "$status" -eq 1 ]

  # -----------------------------------------------------------
  # revert node3 to be a read/write node
  echo "$LINENO : changing node3 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=0"
  [ "$?" -eq 0 ]
}


# Test --update-cluster
@test "test --update-cluster ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # Stop node3
  # store startup values
  ps_row3=$(ps aux | grep "mysqld" | grep "port=$PORT_3")
  restart_cmd3=$(echo $ps_row3 | sed 's:^.* /:/:')
  restart_user3=$(echo $ps_row3 | awk '{ print $1 }')
  pxc_socket3=$(echo $restart_cmd3 | grep -o "\-\-socket=[^ ]* ")

  # shutdown node3
  echo "$LINENO Shutting down node : $HOST_IP:$PORT_3..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket3 -u root shutdown
  [ "$status" -eq 0 ]

  # Startup proxysql
  # -----------------------------------------------------------
  echo "$LINENO : proxysql-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable  <<< 'n'
  echo "$output" >& 2
  [ "$status" -eq 0 ]
  sleep 5

  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # Start node3
  echo "$LINENO Starting node : $HOST_IP:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  # Run --update-cluster
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --update-cluster
  echo "$LINENO : proxysql-admin --update-cluster" >&2
  echo "$output" >& 2
  [ "$status" -eq 0 ]

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]

}

@test "run --update-cluster with read-only --write-node server ($WSREP_CLUSTER_NAME)" {
  # Run --update-cluster with read-only --write-node server
  echo "$LINENO : changing node2 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_2" "SET global read_only=1"
  [ "$?" -eq 0 ]
  
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --update-cluster --write-node=$HOST_IP:$PORT_2
  echo "$LINENO : proxysql-admin --update-cluster --write-node=$HOST_IP:$PORT_2 " >&2
  echo "$output" >& 2
  [ "$status" -eq 1 ]

  # revert node2 to be a read/write node
  echo "$LINENO : changing node2 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_2" "SET global read_only=0"
  [ "$?" -eq 0 ]
  
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable
  echo "$output" >& 2
  [ "$status" -eq 0 ]
}

# Test --enable --update-cluster
@test "test --enable --update-cluster ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --disable

  # Stop node3
  # store startup values
  ps_row3=$(ps aux | grep "mysqld" | grep "port=$PORT_3")
  restart_cmd3=$(echo $ps_row3 | sed 's:^.* /:/:')
  restart_user3=$(echo $ps_row3 | awk '{ print $1 }')
  pxc_socket3=$(echo $restart_cmd3 | grep -o "\-\-socket=[^ ]* ")

  # shutdown node3
  echo "$LINENO Shutting down node : $HOST_IP:$PORT_3..." >&2
  run $PXC_BASEDIR/bin/mysqladmin $pxc_socket3 -u root shutdown
  [ "$status" -eq 0 ]

  cluster_in_use=$(proxysql_exec "select count(*) from runtime_mysql_galera_hostgroups where writer_hostgroup = $WRITER_HOSTGROUP_ID")
  [[ $cluster_in_use -eq 0 ]]

  # Startup proxysql
  # -----------------------------------------------------------
  echo "$LINENO : proxysql-admin --enable --update-cluster" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --update-cluster <<< 'n'
  echo "$output" >& 2
  [ "$status" -eq 0 ]
  sleep 5

  # There should be an entry for this cluster
  cluster_in_use=$(proxysql_exec "select count(*) from runtime_mysql_galera_hostgroups where writer_hostgroup = $WRITER_HOSTGROUP_ID")
  [[ $cluster_in_use -eq 1 ]]

  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:1"  >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # Start node3
  echo "$LINENO Starting node : $HOST_IP:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  # Run --update-cluster
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin --enable --update-cluster
  echo "$LINENO : proxysql-admin --update-cluster" >&2
  echo "$output" >& 2
  [ "$status" -eq 0 ]

  # There should be an entry for this cluster
  cluster_in_use=$(proxysql_exec "select count(*) from runtime_mysql_galera_hostgroups where writer_hostgroup = $WRITER_HOSTGROUP_ID")
  [[ $cluster_in_use -eq 1 ]]

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # backup writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $BACKUP_WRITER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : backup writer count:$proxysql_cluster_count expected:2"  >&2
  [ "$proxysql_cluster_count" -eq 2 ]
  
}
