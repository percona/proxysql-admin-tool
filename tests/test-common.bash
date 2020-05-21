# Common helper file for bats test script

# The minimum required openssl version
readonly    REQUIRED_OPENSSL_VERSION="1.1.1"

# The name of the openssl binary packaged with proxysql-admin
readonly    PROXYSQL_ADMIN_OPENSSL_NAME="proxysql-admin-openssl"



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

  data=$(proxysql_exec "SELECT hostname,port,status,comment,hostgroup_id,weight,max_connections
                        FROM runtime_mysql_servers
                        WHERE $query and STATUS != 'SHUNNED'
                        ORDER BY status,hostname,port,hostgroup_id")
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  while read line; do
    HOSTS+=($(echo -e "$line" | cut -f1))
    PORTS+=($(echo -e "$line" | cut -f2))
    STATUS+=($(echo -e "$line" | cut -f3))
    COMMENTS+=($(echo -e "$line" | cut -f4))
    HOSTGROUPS+=($(echo -e "$line" | cut -f5))
    WEIGHTS+=($(echo -e "$line" | cut -f6))
    MAX_CONNECTIONS+=($(echo -e "$line" | cut -f7))
  done< <(printf "%s\n" "$data")
}

function retrieve_reader_info() {
  get_node_data $READER_HOSTGROUP_ID
  read_host=("${HOSTS[@]}")
  read_port=("${PORTS[@]}")
  read_status=("${STATUS[@]}")
  read_comment=("${COMMENTS[@]}")
  read_hostgroup=("${HOSTGROUPS[@]}")
  read_weight=("${WEIGHTS[@]}")
  read_max_connections=("${MAX_CONNECTIONS[@]}")
}

function retrieve_writer_info() {
  local hg_id=$1
  get_node_data $hg_id
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

  data=$(proxysql_exec "SELECT
                            hostgroup_id,hostname,port,status,comment
                        FROM runtime_mysql_servers
                        WHERE hostgroup_id in ($ALL_HOSTGROUPS)
                        AND comment = 'SLAVEREAD'
                        ORDER BY hostgroup_id,hostname,port,status")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  while read line; do
    HOSTGROUPS+=($(echo -e "$line" | cut -f1))
    HOSTS+=($(echo -e "$line" | cut -f2))
    PORTS+=($(echo -e "$line" | cut -f3))
    STATUS+=($(echo -e "$line" | cut -f4))
    COMMENTS+=($(echo -e "$line" | cut -f5))
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
  proxysql_exec "SELECT
                    hostgroup_id,hostname,port,status,comment,weight
                 FROM mysql_servers
                 WHERE hostgroup_id IN ($ALL_HOSTGROUPS)
                 ORDER BY hostgroup_id,status,hostname,port" >&2
  echo "" >&2
}

function dump_runtime_nodes() {
  local lineno=$1
  local msg=$2
  echo "$lineno Dumping runtime server info : $msg" >&2
  proxysql_exec "SELECT hostgroup_id,hostname,port,status,comment,weight
                 FROM runtime_mysql_servers
                 WHERE hostgroup_id IN ($ALL_HOSTGROUPS)
                 ORDER BY hostgroup_id,status,hostname,port" >&2
  echo "" >&2
}

function require_pxc_maint_mode() {
  if [[ $MYSQL_VERSION =~ ^5.5 || $MYSQL_VERSION =~ ^5.6 ]]; then
    skip "requires pxc_maint_mode"
  fi
}



# Returns the version string in a standardized format
# Input "1.2.3" => echoes "010203"
# Wrongly formatted values => echoes "000000"
#
# Globals:
#   None
#
# Arguments:
#   Parameter 1: a version string
#                like "5.1.12"
#                anything after the major.minor.revision is ignored
# Outputs:
#   A string that can be used directly with string comparisons.
#   So, the string "5.1.12" is transformed into "050112"
#   Note that individual version numbers can only go up to 99.
#
function normalize_version()
{
    local major=0
    local minor=0
    local patch=0

    # Only parses purely numeric version numbers, 1.2.3
    # Everything after the first three values are ignored
    if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([^ ])* ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        patch=${BASH_REMATCH[3]}
    fi

    printf %02d%02d%02d $major $minor $patch
}


# Compares two version strings
#   The version strings passed in will be normalized to a
#   string-comparable version.
#
# Globals:
#   None
#
# Arguments:
#   Parameter 1: The left-side of the comparison (for example: "5.7.25")
#   Parameter 2: the comparison operation
#                   '>', '>=', '=', '==', '<', '<=', "!="
#   Parameter 3: The right-side of the comparison (for example: "5.7.24")
#
# Returns:
#   Returns 0 (success) if param1 op param2
#   Returns 1 (failure) otherwise
#
function compare_versions()
{
    local version_1="$1"
    local op=$2
    local version_2="$3"

    if [[ -z $version_1 || -z $version_2 ]]; then
        echo "$LINENO : Missing version string in comparison" >&2
        echo -e "-- left-side:$version_1  operation:$op  right-side:$version_2" >&2
        return 1
    fi

    version_1="$( normalize_version "$version_1" )"
    version_2="$( normalize_version "$version_2" )"

    if [[ ! " = == > >= < <= != " =~ " $op " ]]; then
        echo "$LINENO : Unknown operation : $op" >&2
        echo -e "-- Must be one of : = == > >= < <=" >&2
        return 1
    fi

    [[ $op == "<"  &&   $version_1 <  $version_2 ]] && return 0
    [[ $op == "<=" && ! $version_1 >  $version_2 ]] && return 0
    [[ $op == "="  &&   $version_1 == $version_2 ]] && return 0
    [[ $op == "==" &&   $version_1 == $version_2 ]] && return 0
    [[ $op == ">"  &&   $version_1 >  $version_2 ]] && return 0
    [[ $op == ">=" && ! $version_1 <  $version_2 ]] && return 0
    [[ $op == "!=" &&   $version_1 != $version_2 ]] && return 0

    return 1
}



# Looks for a version of OpenSSL 1.1.1
#   This could be openssl, openssl11, or the proxysql-admin-openssl binary.
#
# Globals:
#   REQUIRED_OPENSSL_VERSION
#   PROXYSQL_ADMIN_OPENSSL_NAME
#
# Arguments:
#   Parameter 1: the lineno where this function was called
#
# Returns 0 if a binary was found (with version 1.1.1+)
#   and writes the path to the binary to stdout
# Returns 1 otherwise (and prints out its own error message)
#
function find_openssl_binary()
{
  local lineno=$1
  local path_to_openssl
  local openssl_executable=""
  local value
  local openssl_version

  # Check for the proper version of the executable
  path_to_openssl=$(which openssl 2> /dev/null)
  if [[ $? -eq 0 && -n ${path_to_openssl} && -e ${path_to_openssl} ]]; then

    # We found a possible binary, check the version
    value=$(${path_to_openssl} version)
    openssl_version=$(expr match "$value" '.*[ \t]\+\([0-9]\+\.[0-9]\+\.[0-9]\+\)[^0-9].*')

    # Extract the version from version string
    if compare_versions "${openssl_version}" ">=" "$REQUIRED_OPENSSL_VERSION"; then
      openssl_executable=${path_to_openssl}
    fi
  fi

  # If we haven't found an acceptable openssl, look for openssl11
  if [[ -z $openssl_executable ]]; then
    # Check for openssl 1.1 executable (if installed alongside 1.0)
    openssl_executable=$(which openssl11 2> /dev/null)
  fi

  # If we haven't found openssl/openssl11 look for our own binary
  if [[ -z $openssl_executable ]]; then
    openssl_executable=$(which "${WORKDIR}/${PROXYSQL_ADMIN_OPENSSL_NAME}" 2> /dev/null)
  fi

  if [[ -z $openssl_executable ]]; then
    echo -e "$LINENO : Could not find a v${REQUIRED_OPENSSL_VERSION}+ OpenSSL executable in the path." \
                  "\n-- Please check that OpenSSL v${REQUIRED_OPENSSL_VERSION} or greater is installed and in the path." >&2
    return 1
  fi

  # Verify the openssl versions
  value=$(${openssl_executable} version)

  # Extract the version from version string
  openssl_version=$(expr match "$value" '.*[ \t]\+\([0-9]\+\.[0-9]\+\.[0-9]\+\)[^0-9].*')

  if compare_versions "$openssl_version" "<" "$REQUIRED_OPENSSL_VERSION"; then
    echo -e "$LINENO : Could not find OpenSSL with the required version. required:${REQUIRED_OPENSSL_VERSION} found:${openssl_version}" \
                  "\n-- Please check that OpenSSL v${REQUIRED_OPENSSL_VERSION} or greater is installed and in the path." >& 2
    return 1
  fi

  echo "$LINENO : Found openssl executable:${openssl_executable} ${openssl_version}" >&2

  printf "%s" "${openssl_executable}"
  return 0
}
