## percona-scheduler-admin setup tests
#

#
# Variable initialization
#
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

#
# Check that we can find my_print_defaults
#
if [[ ! -e $(which my_print_defaults 2>/dev/null) ]]; then
  echo "my_print_defaults was not found, please install the mysql client package." >&2
  exit 1
fi
MY_PRINT_DEFAULTS=$(which my_print_defaults)


#
# Useful functions
#
# Reads in the given line from the section in a config file
#
# Globals:
#   MY_PRINT_DEFAULTS (this must be setup beforehand)
#
# Arguments:
#   1: lineno
#   2: the path to the config file
#   3: the section in the config file
#   4: the option name
#   5: default value (if option does not exist)
#   6: required (set to 1 if a required value)
#
# Output:
#   Writes out the value of the option to stdout (if found)
#   Writes out the error message to stderr
#
# Returns:
#   0 (success) : if value is found
#                 if value is not found (returns 0 if not required)
#   1 (failure) : if value is not found and is required
#
function read_from_config_file()
{
  local lineno=$1
  local config_path="$2"
  local section=$3
  local option=$4
  local default=$5
  local required=$6
  local retval

  retval=$(${MY_PRINT_DEFAULTS} --defaults-file="${config_path}" --show "${section}" | \
          awk -F= '{
                     sub(/^--loose/,"-",$0);
                     st=index($0,"="); \
                     cur=$0; \
                     if ($1 ~ /_/) \
                         { gsub(/_/,"-",$1);} \
                     if (st != 0) \
                         { print $1"="substr(cur,st+1) } \
                     else { print cur }
                   }' | grep -- "--${option}=" | cut -d= -f2- | tail -1)

  # use default if we haven't found a value
  if [[ -z ${retval} ]]; then
      [[ -n ${default} ]] && retval=${default}
      if [[ $required -eq 1 ]]; then
        # This is a required value
        echo -e "Cannot find a required value : '${option}' in section '${section}'" \
           "\n-- in the config file:${config_path}" >&2
        echo ${retval}
        return 1
      fi
  fi
  echo ${retval}
  return 0
}


# Read variables from config file
declare CONFIG_PATH="testsuite.toml"

PROXYSQL_HOSTNAME=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "proxysql" "host" "" 1)
[[ $? -ne 0 ]] && exit 1

PROXYSQL_PORT=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "proxysql" "port" "" 1)
[[ $? -ne 0 ]] && exit 1

PROXYSQL_USERNAME=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "proxysql" "user" "" 1)
[[ $? -ne 0 ]] && exit 1

PROXYSQL_PASSWORD=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "proxysql" "password" "" 1)
[[ $? -ne 0 ]] && exit 1


CLUSTER_HOSTNAME=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "clusterHost" "" 1)
[[ $? -ne 0 ]] && exit 1

CLUSTER_PORT=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "clusterPort" "" 1)
[[ $? -ne 0 ]] && exit 1

CLUSTER_USERNAME=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "clusterUser" "" 1)
[[ $? -ne 0 ]] && exit 1

CLUSTER_PASSWORD=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "clusterUserPassword" "" 1)
[[ $? -ne 0 ]] && exit 1


MONITOR_USERNAME=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "monitorUser" "" 1)
[[ $? -ne 0 ]] && exit 1

MONITOR_PASSWORD=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "setup" "monitorUserPassword" "" 1)
[[ $? -ne 0 ]] && exit 1

WRITER_HOSTGROUP_ID=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "pxccluster" "hgW" "-1" 1)
[[ $? -ne 0 ]] && exit 1
READER_HOSTGROUP_ID=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "pxccluster" "hgR" "-1" 1)
[[ $? -ne 0 ]] && exit 1

declare config_range
declare maint_range
config_range=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "pxccluster" "configHgRange" "-1" 1)
[[ $? -ne 0 ]] && exit 1
WRITER_CONFIG_HOSTGROUP_ID=$(($config_range + $WRITER_HOSTGROUP_ID))
READER_CONFIG_HOSTGROUP_ID=$(($config_range + $READER_HOSTGROUP_ID))

maint_range=$(read_from_config_file "$LINENO" "$CONFIG_PATH" "pxccluster" "maintenanceHgRange" "-1" 1)
[[ $? -ne 0 ]] && exit 1
WRITER_MAINT_HOSTGROUP_ID=$((maint_range + $WRITER_HOSTGROUP_ID))
READER_MAINT_HOSTGROUP_ID=$((maint_range + $READER_HOSTGROUP_ID))

ALL_HOSTGROUPS="$WRITER_HOSTGROUP_ID,$READER_HOSTGROUP_ID,$WRITER_CONFIG_HOSTGROUP_ID,$WRITER_MAINT_HOSTGROUP_ID,$READER_CONFIG_HOSTGROUP_ID,$READER_MAINT_HOSTGROUP_ID"


WSREP_CLUSTER_NAME=$(cluster_exec "select @@wsrep_cluster_name" 2> /dev/null)
if [[ $WSREP_CLUSTER_NAME == "cluster_one" ]]; then
  PORT_1=4110
  PORT_2=4120
  PORT_3=4130
  ASYNC_PORT=4190
else
  PORT_1=4210
  PORT_2=4220
  PORT_3=4230
  ASYNC_PORT=4290
fi

if [[ $USE_IPVERSION == "v6" ]]; then
  HOST_IP="::1"
else
  HOST_IP="127.0.0.1"
fi

# Ensure that the config file has the same options at start
sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader = 1|" testsuite.toml
sudo sed -i "0,/^[ \t]*singlePrimary[ \t]*=.*$/s|^[ \t]*singlePrimary[ \t]*=.*$|singlePrimary = true|" testsuite.toml
sudo sed -i "0,/^[ \t]*maxNumWriters[ \t]*=.*$/s|^[ \t]*maxNumWriters[ \t]*=.*$|maxNumWriters = 1|" testsuite.toml



@test "run percona-scheduler-admin -d ($WSREP_CLUSTER_NAME)" {
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml -d
  echo "$output" >&2
  [ "$status" -eq  0 ]
}


@test "run percona-scheduler-admin -e ($WSREP_CLUSTER_NAME)" {

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml -e  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]

  # Need some time for this to converge
  sleep 7

  # check to see that there are entries for the cluster nodes
  dump_runtime_nodes "$LINENO" "dumping cluster data"

  # writer count
  local node_count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # reader config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # reader maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --is-enabled <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

@test "run percona-scheduler-admin --update-mysql-version ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_mysql_version ]] && skip;

  DEBUG_SQL_QUERY=1
  local mysql_version=$(mysql_exec "$HOST_IP" "$PORT_3" "SELECT VERSION();" | tail -1 | cut -d'-' -f1)
  local proxysql_mysql_version=$(proxysql_exec "select variable_value from runtime_global_variables where variable_name like 'mysql-server_version'" | awk '{print $0}')
  echo "$LINENO: mysql_version:$mysql_version  proxysql_mysql_version:$proxysql_mysql_version" >&2
  [[ -n $mysql_version ]]
  [[ -n $proxysql_mysql_version ]]

  if [[ $mysql_version != $proxysql_mysql_version ]]; then
    run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-mysql-version
    echo "$output" >&2
    [ "$status" -eq  0 ]

    mysql_version=$(mysql_exec "$HOST_IP" "$PORT_3" "SELECT VERSION();" | tail -1 | cut -d'-' -f1)
    proxysql_mysql_version=$(proxysql_exec "select variable_value from runtime_global_variables where variable_name like 'mysql-server_version'" | awk '{print $0}')
    echo "$LINENO: mysql_version:$mysql_version  proxysql_mysql_version:$proxysql_mysql_version" >&2
    [ "$mysql_version" = "$proxysql_mysql_version" ]
  else
    run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-mysql-version
    echo "$output" >&2
    [ "$status" -eq  0 ]
  fi
}

@test "run the check for --adduser ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ adduser ]] && skip;
  DEBUG_SQL_QUERY=1

  printf "proxysql_test_user1\ntest_user\ny" | sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --adduser --debug >&2
  [[ $? -eq 0 ]]

  run_check_user_command=$(proxysql_exec "select 1 from runtime_mysql_users where username='proxysql_test_user1'" | head -1 | awk '{print $0}')
  [ "$run_check_user_command" -eq 1 ]
}

@test "run percona-scheduler-admin --syncusers --add-query-rule ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ add_query_rule ]] && skip;

  # Check whether user and query rule exists in  ProxySQL DB
  DEBUG_SQL_QUERY=1
  run_check_user=$(proxysql_exec "select 1 from runtime_mysql_users where username='test_query_rule'" | awk '{print $0}')
  run_query_rule=$(proxysql_exec "select 1 from runtime_mysql_query_rules where username='test_query_rule'" | awk '{print $0}')
  echo "$LINENO : Check query rule user count(test_query_rule) found:$run_check_user expect:0"  >&2
  [[ "$run_check_user" -eq 0 ]]
  echo "$LINENO : Check query rule count for user(test_query_rule) found:$run_query_rule expect:0"  >&2
  [[ "$run_query_rule" -eq 0 ]]

  mysql_exec "$HOST_IP" "$PORT_3" "create user test_query_rule@'%' identified by 'test';"
  # Give the cluster some time for this to replicate
  sleep 3

  # Check to see if the user has replicated to a different node
  mysql_user_count=$(mysql_exec "$HOST_IP" "$PORT_1" "select count(*) from mysql.user where user='test_query_rule'")
  echo "$LINENO" "cluster count for user test_query_rule found:${mysql_user_count}  expect:1" >&2
  [[ $mysql_user_count -eq 1 ]]

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --syncusers --add-query-rule
  echo "$output" >&2
  [ "$status" -eq  0 ]
  [[ "${lines[2]}" =~ "Added query rule for user: test_query_rule" || "${lines[3]}" =~ "Added query rule for user: test_query_rule" ]]

  run_write_hg_query_rule_user=$(proxysql_exec "select 1 from runtime_mysql_query_rules where username='test_query_rule' and match_digest='^SELECT.*FOR UPDATE'" | awk '{print $0}')
  echo "$LINENO : Query rule count for user 'test_query_rule' with writer hostgroup found:$run_write_hg_query_rule_user expect:1"  >&2
  [[ $run_write_hg_query_rule_user -eq 1 ]]
  run_read_hg_query_rule_user=$(proxysql_exec "select 1 from runtime_mysql_query_rules where username='test_query_rule' and match_digest='^SELECT '" | awk '{print $0}')
  echo "$LINENO : Query rule count for user 'test_query_rule' with reader hostgroup found:$run_read_hg_query_rule_user expect:1"  >&2
  [[ $run_read_hg_query_rule_user -eq 1 ]]
  
  # Dropping user 'test_query_rule' from MySQL server to test the query rule delete operation 
  mysql_exec "$HOST_IP" "$PORT_3" "drop user test_query_rule@'%';"
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --syncusers --add-query-rule
  echo "$output" >&2
  [ "$status" -eq  0 ]
  run_check_user=$(proxysql_exec "select 1 from runtime_mysql_users where username='test_query_rule'" | awk '{print $0}')
  run_query_rule=$(proxysql_exec "select 1 from runtime_mysql_query_rules where username='test_query_rule'" | awk '{print $0}')
  echo "$LINENO : Check query rule user count(test_query_rule) found:$run_check_user expect:0"  >&2
  [[ "$run_check_user" -eq 0 ]]
  echo "$LINENO : Check query rule count for user(test_query_rule) found:$run_query_rule expect:0"  >&2
  [[ "$run_query_rule" -eq 0 ]]
}

@test "run the check for --syncusers ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ syncusers_basic ]] && skip;

  local mysql_version=$(cluster_exec "select @@version")
  local pass_field
  if [[ $mysql_version =~ ^5.6 ]]; then
    pass_field="password"
  else
    pass_field="authentication_string"
  fi
  cluster_user_count=$(cluster_exec "select count(distinct user) from mysql.user where ${pass_field} != '' and user not in ('admin') and user not like 'mysql.%'" -Ns)

  # HACK: this mismatch occurs because we are running the tests for cluster_two
  # right after the test for cluster_one (multi-cluster scenario), so the
  # user counts will be off (because user cluster_one will still be in proxysql users).
  if [[ $WSREP_CLUSTER_NAME == "cluster_two" ]]; then
    proxysql_user_count=$(proxysql_exec "select count(distinct username) from runtime_mysql_users where username not in ('cluster_one')" | awk '{print $0}')
  else
    proxysql_user_count=$(proxysql_exec "select count(distinct username) from runtime_mysql_users" | awk '{print $0}')
  fi

  # Dump the user lists for debugging
  echo "cluster users" >&2
  cluster_exec "select user,host from mysql.user where ${pass_field} != '' and user not in ('admin') and user not like 'mysql.%'" >&2
  echo "" >&2
  echo "proxysql users" >&2
  proxysql_exec "select * from runtime_mysql_users" "-t" >&2
  echo "" >&2

  echo "cluster_user_count:$cluster_user_count  proxysql_user_count:$proxysql_user_count" >&2
  [ "$cluster_user_count" -eq "$proxysql_user_count" ]
}


@test "run percona-scheduler-admin --syncusers --server ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ syncusers_server ]] && skip;

  local server_user
  local proxysql_count
  server_user="${WSREP_CLUSTER_NAME}_slave"

  DEBUG_SQL_QUERY=1

  # Verify that the user is not in ProxySQL
  proxysql_count=$(proxysql_exec "select count(distinct username) from mysql_users where username='${server_user}'")
  [[ $proxysql_count -eq 0 ]]

  # Create a user on the async node
  mysql_exec "$HOST_IP" "$ASYNC_PORT" "CREATE USER '${server_user}'@'%' IDENTIFIED WITH mysql_native_password BY 'passwd';"

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --syncusers --server=${HOST_IP}:${ASYNC_PORT}
  echo "$output" >&2
  [ "$status" -eq  0 ]

  # Verify that the user has been added to ProxySQL
  proxysql_count=$(proxysql_exec "select count(distinct username) from mysql_users where username='${server_user}'")
  [[ $proxysql_count -eq 1 ]]

  # Cleanup by removing the user on the async node
  mysql_exec "$HOST_IP" "$ASYNC_PORT" "DROP USER '${WSREP_CLUSTER_NAME}_slave'@'%';"

  # Remove the user from proxysql
  proxysql_exec "delete from mysql_users where username='${server_user}'; load mysql users to runtime"
}

@test "run percona-scheduler-admin --sync-multi-cluster-users --server ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ syncusers_multicluster_server ]] && skip;

  local server_user
  local proxysql_count
  server_user="${WSREP_CLUSTER_NAME}_slave"

  # Verify that the user is not in ProxySQL
  proxysql_count=$(proxysql_exec "select count(distinct username) from mysql_users where username='${server_user}'")
  [[ $proxysql_count -eq 0 ]]

  # Create a user on the async node
  mysql_exec "$HOST_IP" "$ASYNC_PORT" "CREATE USER '${server_user}'@'%' IDENTIFIED WITH mysql_native_password BY 'passwd';"

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --sync-multi-cluster-users --server=${HOST_IP}:${ASYNC_PORT}
  echo "$output" >&2
  [ "$status" -eq  0 ]

  # Verify that the user has been added to ProxySQL
  proxysql_count=$(proxysql_exec "select count(distinct username) from mysql_users where username='${server_user}'")
  [[ $proxysql_count -eq 1 ]]

  # Cleanup by removing the user on the async node
  mysql_exec "$HOST_IP" "$ASYNC_PORT" "DROP USER '${WSREP_CLUSTER_NAME}_slave'@'%'"

  # Remove the user from proxysql
  proxysql_exec "delete from mysql_users where username='${server_user}'; load mysql users to runtime"
}


@test "run the check for --force ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ force ]] && skip;

  # Cleaning existing configuration to test --force option as normal run
  dump_runtime_nodes $LINENO "before disable"
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

  dump_runtime_nodes $LINENO "before enable --force"
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml  --enable --force <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 10

  # Check the status of the system
  dump_runtime_nodes $LINENO "before count"

  local node_count

  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:2" >&2
  [ "$node_count" -eq 3 ]

  # writer config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # reader config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # reader maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # Run 'percona-scheduler-admin --enable --force' without removing existing configuration
  echo "$LINENO : running --enable --force (without removing existing config)"  >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml  --enable --force <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 10
  dump_runtime_nodes $LINENO "after enable"

  # Check the status of the system
  dump_runtime_nodes $LINENO "before count"

  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED' " | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:2" >&2
  [ "$node_count" -eq 3 ]

  # writer config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # reader config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # reader maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # Check percona-scheduler-admin run status without --force option
  echo "$LINENO : running --disable"  >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml  --disable
  [ "$status" -eq 0 ]
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml  --enable <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]

  # Check percona-scheduler-admin run status with following options
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml  --enable --update-cluster --force  <<< n
  echo "$output" >&2
  [ "$status" -eq 0 ]
  sleep 10
  dump_runtime_nodes $LINENO "after enable"
  
  # Check the status of the system
  dump_runtime_nodes $LINENO "before count"
  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:2" >&2
  [ "$node_count" -eq 3 ]
  
  # writer config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # reader config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # reader maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

}


@test "test for --writers-are-readers ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ writers_are_readers_basic ]] && skip;

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

  # -----------------------------------------------------------
  # Use default value for --writers-are-readers (default is 1 or yes)
  echo "$LINENO : percona-scheduler-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 10
  dump_runtime_nodes $LINENO "after enable"

  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:2" >&2
  [ "$node_count" -eq 3 ]


  # -----------------------------------------------------------
  # Now run with --writers-are-readers=no
  echo "$LINENO : percona-scheduler-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  [ "$status" -eq 0 ]

  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=0|" testsuite.toml

  echo "$LINENO : percona-scheduler-admin --enable --writers-are-readers=no" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5
  dump_runtime_nodes $LINENO "after enable (writers-are-readers=no)"

  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'  " | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:3" >&2
  [ "$node_count" -eq 2 ]


  # restore the system
  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=1|" testsuite.toml
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

}


@test "test for --writers-are-readers with a read-only node ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ writes_are_readers_read_only ]] && skip;

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

  # -----------------------------------------------------------
  # change node3 to be a read-only node
  echo "$LINENO : changing node3 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=1"
  [ "$?" -eq 0 ]

  # -----------------------------------------------------------
  # Use default value for --writers-are-readers
  # This will fail because read-only nodes are not allowed in configurations
  # that use --writers-are-ready=yes (which is the default)
  echo "$LINENO : percona-scheduler-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 10

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 3 ]


  # -----------------------------------------------------------
  # Now run with --writers-are-readers=no
  echo "$LINENO : percona-scheduler-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  [ "$status" -eq 0 ]


  echo "$LINENO : percona-scheduler-admin --enable --writers-are-readers=no" >&2
  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=0|" testsuite.toml
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 10

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 2 ]


  # -----------------------------------------------------------
  # revert node3 to be a read/write node
  echo "$LINENO : changing node3 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=0"
  [ "$?" -eq 0 ]

  # restore the system
  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=1|" testsuite.toml
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5

}


# TODO: test that the mode is set correctly
# Test loadbal
@test "test for --mode=loadbal ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ loadbal_basic ]] && skip;

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=0|" testsuite.toml
  sudo sed -i "0,/^[ \t]*singlePrimary[ \t]*=.*$/s|^[ \t]*singlePrimary[ \t]*=.*$|singlePrimary=false|" testsuite.toml
  sudo sed -i "0,/^[ \t]*maxNumWriters[ \t]*=.*$/s|^[ \t]*maxNumWriters[ \t]*=.*$|maxNumWriters=9999|" testsuite.toml

  echo "$LINENO : percona-scheduler-admin --enable --mode=loadbal" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 10

   # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:3" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:0" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

  # Reset the system
  sudo sed -i "0,/^[ \t]*writerIsAlsoReader[ \t]*=.*$/s|^[ \t]*writerIsAlsoReader[ \t]*=.*$|writerIsAlsoReader=1|" testsuite.toml
  sudo sed -i "0,/^[ \t]*singlePrimary[ \t]*=.*$/s|^[ \t]*singlePrimary[ \t]*=.*$|singlePrimary=true|" testsuite.toml
  sudo sed -i "0,/^[ \t]*maxNumWriters[ \t]*=.*$/s|^[ \t]*maxNumWriters[ \t]*=.*$|maxNumWriters=1|" testsuite.toml
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable <<< 'n'
  [ "$status" -eq 0 ]
  sleep 5
}


# Test --update-cluster
@test "test --update-cluster ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_cluster_basic ]] && skip;

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

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
  echo "$LINENO : percona-scheduler-admin --enable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable  <<< 'n'
  echo "$output" >& 2
  [ "$status" -eq 0 ]
  sleep 10

  # Check the status of the system
  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 2 ]

  # Start node3
  echo "$LINENO Starting node : $HOST_IP:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  sleep 10

  dump_runtime_nodes "$LINENO" "after cluster update (runtime)"

  # Run --update-cluster
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster
  echo "$LINENO : percona-scheduler-admin --update-cluster" >&2
  echo "$output" >& 2
  [ "$status" -eq 0 ]

  sleep 10

  dump_runtime_nodes "$LINENO" "after cluster update (runtime)"

  # writer count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$proxysql_cluster_count expected:1" >&2
  [ "$proxysql_cluster_count" -eq 1 ]

  # reader count
  proxysql_cluster_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$proxysql_cluster_count expected:2" >&2
  [ "$proxysql_cluster_count" -eq 3 ]

}

# Test --enable --update-cluster
@test "test --enable --update-cluster ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_cluster_enable ]] && skip;

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable

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
  echo "$LINENO : percona-scheduler-admin --enable --update-cluster" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --update-cluster <<< 'n'
  echo "$output" >& 2
  [ "$status" -eq 0 ]
  sleep 10

  # Check the status of the system
  # writer count
  local node_count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:1" >&2
  [ "$node_count" -eq 2 ]

  # Start node3
  echo "$LINENO Starting node : $HOST_IP:$PORT_3..." >&2
  restart_server "$restart_cmd3" "$restart_user3"
  wait_for_server_start $pxc_socket3 3

  sleep 10

  # Run --update-cluster
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --update-cluster
  echo "$LINENO : percona-scheduler-admin --update-cluster" >&2
  echo "$output" >& 2
  [ "$status" -eq 0 ]

  sleep 10

  # writer count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:2" >&2
  [ "$node_count" -eq 3 ]
  
}

# Test --update-cluster with --write-node
@test "test --update-cluster --write-node ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_cluster_basic ]] && skip;

  # Reset before the test
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --remove-all-servers

  # Save the existing writer node
  local saved_hgw_port writer_node
  saved_hgw_port=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')

  # Test with PORT_1
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --write-node="$HOST_IP:$PORT_1"
  echo "$output" >&2
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ "$writer_node" -eq "$PORT_1" ]
  [ "$status" -eq 0 ]

  # Test with PORT_2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --write-node="$HOST_IP:$PORT_2"
  echo "$output" >&2
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ "$writer_node" -eq "$PORT_2" ]
  [ "$status" -eq 0 ]

  # Test with PORT_3
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --write-node="$HOST_IP:$PORT_3"
  echo "$output" >&2
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ "$writer_node" -eq "$PORT_3" ]
  [ "$status" -eq 0 ]

  # Reset to saved_hgw_port
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --write-node="$HOST_IP:$saved_hgw_port"
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ "$writer_node" -eq "$saved_hgw_port" ]
  [ "$status" -eq 0 ]

}

@test "test upgrade from proxy-admin script ($WSREP_CLUSTER_NAME)" {

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml -d  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]
  local saved_hgw saved_hgr
  saved_hgw=$WRITER_HOSTGROUP_ID
  saved_hgr=$READER_HOSTGROUP_ID

  echo "Running proxysql-admin --enable" >&2
  source /etc/proxysql-admin.cnf
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -e  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]

  echo "Running proxysql-admin --disable" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/proxysql-admin -d  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]

  WRITER_HOSTGROUP_ID=$saved_hgw
  READER_HOSTGROUP_ID=$saved_hgr
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml -e  <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]

  # Need some time for this to converge
  sleep 7

  # check to see that there are entries for the cluster nodes
  dump_runtime_nodes "$LINENO" "dumping cluster data"

  # writer count
  local node_count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID and status != 'SHUNNED'" | awk '{print $0}')
  echo "$LINENO : hg:${WRITER_HOSTGROUP_ID} writer count:$node_count expected:1" >&2
  [ "$node_count" -eq 1 ]

  # reader count
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # reader config
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader config count:$node_count expected:1" >&2
  [ "$node_count" -eq 3 ]

  # writer maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : writer maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  # reader maint
  node_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_MAINT_HOSTGROUP_ID " | awk '{print $0}')
  echo "$LINENO : reader maint count:$node_count expected:1" >&2
  [ "$node_count" -eq 0 ]

  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --is-enabled <<< 'n'
  echo "$output" >&2
  [ "$status" -eq  0 ]
}

# Test --update-cluster with --update-read-weight
@test "test --update-cluster --update-read-weight and --update-write-weight ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_cluster_basic ]] && skip;

  # Update node weight using --update-weight option
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --update-read-weight="$HOST_IP:$PORT_1,1234"

  # Validate
  node_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostname='$HOST_IP' AND port=$PORT_1 AND hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  [ $node_weight -eq 1234 ]

  node_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostname='$HOST_IP' AND port=$PORT_1 AND hostgroup_id = $READER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  [ $node_weight -eq 1234 ]
  [ "$status" -eq 0 ]

  # Update node weight using --update-write-weight option
  writer_port=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --update-write-weight="$HOST_IP:$writer_port,2340"

  # Validate
  node_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostname='$HOST_IP' AND port=$writer_port AND hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ $node_weight -eq 2340 ]

  node_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostname='$HOST_IP' AND port=$writer_port AND hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID " | awk '{print $0}')
  [ $node_weight -eq 2340 ]
  [ "$status" -eq 0 ]

  # Reset weights
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --remove-all-servers
}

# Test --update-cluster with --auto-assign-weights
@test "test --update-cluster --auto-assign-weights ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ update_cluster_basic ]] && skip;

  # Update node weight using --update-weight option
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --auto-assign-weights

  # There should be only one writer.
  writer_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ $writer_count -eq 1 ]
  [ "$status" -eq 0 ]

  # Writer weight should be 1000
  writer_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  [ $writer_weight -eq 1000 ]
  [ "$status" -eq 0 ]

  # Writer should have less weight for reads
  writer_port=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  writer_reader_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID and port=$writer_port" | awk '{print $0}')
  [ $writer_reader_weight -eq 900 ]

  # There should be 3 readers
  reader_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID " | awk '{print $0}')
  [ $reader_count -eq 3 ]
  [ "$status" -eq 0 ]

  # All readers should have weight as 1000 except the writer node.
  reader_1000_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $READER_HOSTGROUP_ID and weight=1000 and port != $writer_port" | awk '{print $0}')
  proxysql_exec "select * from runtime_mysql_servers "
  [ $reader_1000_count -eq 2 ]
  [ "$status" -eq 0 ]

  # There should be one node with writer weight 999 in writer config hostgroup
  writer_999_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID and weight=999" | awk '{print $0}')
  [ $writer_999_count -eq 1 ]

  # There should be one node with writer weight 998 in writer config hostgroup
  writer_998_count=$(proxysql_exec "select count(*) from runtime_mysql_servers where hostgroup_id = $WRITER_CONFIG_HOSTGROUP_ID and weight=998" | awk '{print $0}')
  [ $writer_998_count -eq 1 ]

  # Reset weights
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --remove-all-servers
}

# Test --enable with --write-node
@test "test --enable --write-node ($WSREP_CLUSTER_NAME)" {


  # Test with PORT_1
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --write-node="$HOST_IP:$PORT_1"
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  writer_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')

  [ $writer_weight -eq 1000000 ]
  [ "$writer_node" -eq "$PORT_1" ]
  [ "$status" -eq 0 ]

  # Test with PORT_2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --write-node="$HOST_IP:$PORT_2"
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  writer_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')

  [ $writer_weight -eq 1000000 ]
  [ "$writer_node" -eq "$PORT_2" ]
  [ "$status" -eq 0 ]

  # Test with PORT_3
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --write-node="$HOST_IP:$PORT_3"
  writer_node=$(proxysql_exec "select port from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')
  writer_weight=$(proxysql_exec "select weight from runtime_mysql_servers where hostgroup_id = $WRITER_HOSTGROUP_ID " | awk '{print $0}')

  [ $writer_weight -eq 1000000 ]
  [ "$writer_node" -eq "$PORT_3" ]
  [ "$status" -eq 0 ]

  # Reset
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --remove-all-servers
}

# Test singlewrite with --write-node is a read-only node
@test "test for --enable --write-node on a read-only node ($WSREP_CLUSTER_NAME)" {
  [[ -n $TEST_NAME && ! $TEST_NAME =~ singlewrite_read_only ]] && skip;

  # Disable
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --disable

  # -----------------------------------------------------------
  # change node3 to be a read-only node
  echo "$LINENO : changing node3 to read-only" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=1;"
  [ "$?" -eq 0 ]

  # -----------------------------------------------------------
  # This should fail, since a write-node cannot be read-only
  echo "$LINENO : percona-scheduler-admin --enable --write-node=${HOST_IP}:${PORT_3}" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --write-node=${HOST_IP}:${PORT_3}
  [ "$status" -eq 1 ]

  # -----------------------------------------------------------
  # This should pass, since --force option suppresses error
  echo "$LINENO : percona-scheduler-admin --enable --write-node=${HOST_IP}:${PORT_3} --force" >&2
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --enable --write-node=${HOST_IP}:${PORT_3} --force
  [[ ${lines[10]} =~ ^WARNING.*The.specified.write.node.*is.read-only.$ ]]
  [ "$status" -eq 0 ]

  # -----------------------------------------------------------
  # revert node3 to be a read/write node
  echo "$LINENO : changing node3 back to read-only=0" >&2
  mysql_exec "$HOST_IP" "$PORT_3" "SET global read_only=0"
  [ "$?" -eq 0 ]

  # Reset
  run sudo PATH=$WORKDIR:$PATH $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-cluster --remove-all-servers
}
