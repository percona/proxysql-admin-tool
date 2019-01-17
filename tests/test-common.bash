# Common helper file for bats test script


function exec_sql() {
  local user=$1
  local password=$2
  local hostname=$3
  local port=$4
  local query=$5
  local args="--skip-column_names"
  local retvalue
  local retoutput

  if [[ $# -ge 6 ]]; then
    args=$6
  fi

  retoutput=$(printf "[client]\nuser=${user}\npassword=\"${password}\"\nhost=${hostname}\nport=${port}"  \
      | $PXC_BASEDIR/bin/mysql --defaults-file=/dev/stdin --protocol=tcp \
            --unbuffered --batch --silent ${args} -e "${query}")
  retvalue=$?

  printf "%s" "${retoutput}"
  return $retvalue
}

function proxysql_exec() {
  local query=$1
  local args=""

  if [[ $# -ge 2 ]]; then
    args=$2
  fi

  exec_sql "$PROXYSQL_USERNAME" "$PROXYSQL_PASSWORD" \
           "$PROXYSQL_HOSTNAME" "$PROXYSQL_PORT" \
           "$query" "$args"

  return $?
}

function cluster_exec() {
  local query=$1
  local args=""

  if [[ $# -ge 2 ]]; then
    args=$2
  fi

  exec_sql "$CLUSTER_USERNAME" "$CLUSTER_PASSWORD" \
           "$CLUSTER_HOSTNAME" "$CLUSTER_PORT" \
           "$query" "$args"

  return $?
}

function mysql_exec() {
  local hostname=$1
  local port=$2
  local query=$3
  local args=""

  if [[ $# -ge 4 ]]; then
    args=$4
  fi

  exec_sql "$CLUSTER_USERNAME" "$CLUSTER_PASSWORD" \
           "$hostname" "$port" \
           "$query" "$args"

  return $?
}


# Returns information about the nodes in the hostgroup
#
# Globals:
#   HOSTS
#   PORTS
#   STATUS
#   COMMENTS
#   HOSTGROUPS
#   WEIGHTS
#   MAX_CONNECTIONS
#
# Arguments:
#   1: hostgroup
#
function get_node_data() {
  local hostgroup=$1
  local query=""
  local data

  HOSTS=()
  PORTS=()
  STATUS=()
  COMMENTS=()
  HOSTGROUPS=()
  WEIGHTS=()
  MAX_CONNECTIONS=()

  if [[ -n $hostgroup ]]; then
    if [[ $hostgroup =~ ',' ]]; then
      query+="hostgroup_id IN ($hostgroup)"
    else
      query+="hostgroup_id=$hostgroup"
    fi
  fi

  # Exclude slaves
  if [[ -n $query ]]; then
    query+=" AND "
  fi
  query+="comment <> 'SLAVEREAD'"

  data=$(proxysql_exec "SELECT hostname,port,status,comment,hostgroup_id,weight,max_connections FROM mysql_servers WHERE $query ORDER BY status,hostname,port,hostgroup_id")
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  while read line; do
    HOSTS+=($(echo $line | awk '{ print $1 }'))
    PORTS+=($(echo $line | awk '{ print $2 }'))
    STATUS+=($(echo $line | awk '{ print $3 }'))
    COMMENTS+=($(echo $line | awk '{ print $4 }'))
    HOSTGROUPS+=($(echo $line | awk '{ print $5 }'))
    WEIGHTS+=($(echo $line | awk '{ print $6 }'))
    MAX_CONNECTIONS+=($(echo $line | awk '{ print $7 }'))
  done< <(printf "%s\n" "$data")
}

function retrieve_reader_info() {
  get_node_data $READ_HOSTGROUP_ID
  read_host=("${HOSTS[@]}")
  read_port=("${PORTS[@]}")
  read_status=("${STATUS[@]}")
  read_comment=("${COMMENTS[@]}")
  read_hostgroup=("${HOSTGROUPS[@]}")
  read_weight=("${WEIGHTS[@]}")
  read_max_connections=("${MAX_CONNECTIONS[@]}")
}

function retrieve_writer_info() {
  get_node_data $WRITE_HOSTGROUP_ID
  write_host=("${HOSTS[@]}")
  write_port=("${PORTS[@]}")
  write_status=("${STATUS[@]}")
  write_comment=("${COMMENTS[@]}")
  write_hostgroup=("${HOSTGROUPS[@]}")
  write_weight=("${WEIGHTS[@]}")
  write_max_connections=("${MAX_CONNECTIONS[@]}")
}


function retrieve_slave_info() {
  local data=""

  local HOSTGROUPS=()
  local HOSTS=()
  local PORTS=()
  local STATUS=()
  local COMMENTS=()

  data=$(proxysql_exec "SELECT hostgroup_id,hostname,port,status,comment FROM mysql_servers WHERE hostgroup_id in ($READ_HOSTGROUP_ID,$WRITE_HOSTGROUP_ID) AND comment = 'SLAVEREAD' ORDER BY hostgroup_id,hostname,port,status")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  while read line; do
    HOSTGROUPS+=($(echo $line | awk '{ print $1 }'))
    HOSTS+=($(echo $line | awk '{ print $2 }'))
    PORTS+=($(echo $line | awk '{ print $3 }'))
    STATUS+=($(echo $line | awk '{ print $4 }'))
    COMMENTS+=($(echo $line | awk '{ print $5 }'))
  done< <(printf "$data\n")

  slave_hostgroup=("${HOSTGROUPS[@]}")
  slave_host=("${HOSTS[@]}")
  slave_port=("${PORTS[@]}")
  slave_status=("${STATUS[@]}")
  slave_comment=("${COMMENTS[@]}")
}

# Queries the node for it's slave status and returns the
# data in a a string with four fields:
#   master_host:slave_io_running:slave_sql_running:seconds_behind_master
# This is to get around the lack of associative array support in
# the distros.
#
# Globals:
#   slave_status
#
# Arguments:
#   1: host address
#   2: port
#
function retrieve_slavenode_status() {
  local host=$1
  local port=$2
  local status

  status=$(mysql_exec "${host}" "${port}" 'SHOW SLAVE STATUS\G' "--silent" | sed 's/ //g')

  result=""
  result+=$(echo "$status" | grep "^Master_Host:" | cut -d: -f2-)
  result+="\t"
  result+=$(echo "$status" | grep "^Slave_IO_Running:" | cut -d: -f2)
  result+="\t"
  result+=$(echo "$status" | grep "^Slave_SQL_Running:" | cut -d: -f2)
  result+="\t"
  result+=$(echo "$status" | grep "^Seconds_Behind_Master:" | cut -d: -f2)

  echo "$result"
}


function wait_for_server_start() {
  local socket=$1
  local cluster_size=$2

  for X in $( seq 0 30 ); do
    sleep 1
    if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S${socket} ping > /dev/null 2>&1; then
      # Check the WSREP_READY status
      ready_status=$(${PXC_BASEDIR}/bin/mysql -uroot -$${socket} -Ns -e "show status like 'wsrep_ready'")
      if [[ -n $ready_status ]]; then
        ready_status=$(echo "$ready_status" | awk '{ print $2 }')
        if [[ $ready_status == "ON" ]]; then
          size=$(${PXC_BASEDIR}/bin/mysql -uroot -$${socket} -Ns -e "show status like 'wsrep_cluster_size'")
          if [[ -n $size ]]; then
            size=$(echo "$size" | awk '{ print $2 }')
            if [[ $size -eq $cluster_size ]]; then
              break
            fi
          fi
        fi
      fi

    fi
  done
}

function wait_for_server_shutdown() {
  local socket=$1
  local cluster_size=$2

  for X in $( seq 0 30 ); do
    sleep 1
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S${socket} ping > /dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}



function restart_server() {
  local restart_cmd=$1
  local restart_user=$2
  local bootstrap=""
  local pxc_datadir
  local options=""

  if [[ $# -ge 3 ]]; then
    bootstrap=$3
  fi

  local new_start_cmd=$restart_cmd

  if [[ $bootstrap == "bootstrap" ]]; then
    if echo "$restart_cmd" | grep -q -v "\-\-wsrep-new-cluster"; then
      # There is no --wsrep-new-cluster, so add it to the command line
      options+=" --wsrep-new-cluster "
    fi

    # Extract the datadir
    pxc_datadir=$(echo $restart_cmd | grep -o "\-\-datadir=[^ ]*")
    pxc_datadir=$(echo "$pxc_datadir" | cut -d'=' -f2)

    # Update the grastate.dat file to ensure that the node can bootstrap
    # Ensure that safe_to_bootstrap is set to 1
    sed -i "s/^safe_to_bootstrap:[ \t]0/safe_to_bootstrap: 1/" "${pxc_datadir}/grastate.dat"
  else
    new_start_cmd=$(echo "$new_start_cmd" | sed "s/\-\-wsrep-new-cluster//g")
  fi

  if [[ ! $new_start_cmd =~ --user=$restart_user ]]; then
    options+="--user=$restart_user"
  fi
  nohup $new_start_cmd $options 3>&- &>/dev/null &
}

function dump_nodes() {
  local lineno=$1
  local msg=$2
  echo "$lineno Dumping server info : $msg" >&2
  proxysql_exec "SELECT hostgroup_id,hostname,port,status,comment,weight FROM mysql_servers WHERE hostgroup_id IN ($WRITE_HOSTGROUP_ID, $READ_HOSTGROUP_ID) ORDER BY hostgroup_id,status,hostname,port" >&2
  echo "" >&2
}

function dump_runtime_nodes() {
  local lineno=$1
  local msg=$2
  echo "$lineno Dumping runtime server info : $msg" >&2
  proxysql_exec "SELECT hostgroup_id,hostname,port,status,comment,weight FROM runtime_mysql_servers WHERE hostgroup_id IN ($WRITE_HOSTGROUP_ID, $READ_HOSTGROUP_ID) ORDER BY hostgroup_id,status,hostname,port" >&2
  echo "" >&2
}

function require_pxc_maint_mode() {
  if [[ $MYSQL_VERSION =~ ^5.5 || $MYSQL_VERSION =~ ^5.6 ]]; then
    skip "requires pxc_maint_mode"
  fi
}
