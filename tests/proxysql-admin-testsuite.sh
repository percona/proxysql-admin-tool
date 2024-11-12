#!/bin/bash -u
# Created by Ramesh Sivaraman, Percona LLC
# The script is used for testing proxysql-admin functionality

#
# List of test suites that will be run
# It is assumed that these files are in the proxysql-admin/tests directory
# ================================================
#
TEST_SUITES=()
TEST_SUITES+=("proxysql-admin-testsuite.bats")

# This is the 2nd set of tests
# These suites will be run AFTER the two passes through
# the first set of tests.
TEST_SUITES2=()
TEST_SUITES2+=("scheduler-admin-testsuite.bats")


#
# Variables
# ================================================
#
declare WORKDIR=""
declare SCRIPT_PATH=$0
declare SCRIPT_DIR=$(cd `dirname $0` && pwd)

declare PXC_START_TIMEOUT=60
declare SUSER=root
declare SPASS=
declare OS_USER=$(whoami)

# Used by the async replicas
declare REPL_USER="repl_user"
declare REPL_PASSWORD="pass1234"

# Set this to 1 to run the tests
declare RUN_TEST=1

# Options to skip killing old mysqld and proxysql processes
declare KILL_OLD_MYSQLD=1
declare KILL_OLD_PROXYSQL=1

# Set this to 1 to include creating and running the tests
# for cluster 2
declare USE_CLUSTER_TWO=1

# Set to either v4 or v6 (default is 'v4')
declare USE_IPVERSION="v4"

declare ALLOW_SHUTDOWN="Yes"

declare PROXYSQL_EXTRA_OPTIONS=""

declare TEST_NAMES=""

declare MYSQL_VERSION
declare MYSQL_CLIENT_VERSION

#
# Useful functions
# ================================================
#
function usage() {
  cat << EOF
Usage example:
  $ ${SCRIPT_PATH##*/} <workdir> [<options>]

This test script expects a certain directory layout for the workdir.

  <workdir>/
      proxysql-admin
      Percona-XtraDB-Cluster-XXX.tar.gz
      proxysql-2.0/
        etc/
          proxysql-admin.cnf
        usr/
          bin/
            proxysql


The log files and datadirs may also be found in the <workdir>

  <workdir>
    logs/
    <cluster datadirs>/

Options:
  --no-test           Starts up the test environment but does not run
                      the tests. The servers (PXC and ProxySQL) are
                      left up-and-running (useful for quickly starting
                      a test environment). This requires a manual running
                      of the proxysql-admin script.
  --no-kill-mysqld    Dont kill previous mysqld servers
  --no-kill-proxysql  Dont kill previous proxysql servers
  --cluster-one-only  Only starts up (and runs the tests) for cluster_one.
                      May be used with --no-test to startup only one cluster.
  --ipv4              Run the tests using IPv4 addresses (default)
  --ipv6              Run the tests using IPv6 addresses
  --proxysql-options=OPTIONS
                      Specify additional options that will be passed
                      to proxysql.
  --test=test1,test2  Specify a list of comma-separated test names to run.

EOF
}


function parse_args() {
  local param value
  local positional_params=""
  while [[ $# -gt 0 ]]; do
      param=`echo $1 | awk -F= '{print $1}'`
      value=`echo $1 | awk -F= '{print $2}'`

      # possible positional parameter
      if [[ ! $param =~ ^--[^[[:space:]]]* ]]; then
        positional_params+="$1 "
        shift
        continue
      fi
      case $param in
        -h | --help)
          usage
          exit
          ;;
        --no-test)
          RUN_TEST=0
          ;;
        --cluster-one-only)
          USE_CLUSTER_TWO=0
          ;;
        --ipv4)
          USE_IPVERSION="v4"
          ;;
        --ipv6)
          USE_IPVERSION="v6"
          ;;
        --proxysql-options)
          PROXYSQL_EXTRA_OPTIONS=$value
          ;;
        --test)
          TEST_NAMES=$value
          ;;
        --no-kill-mysqld)
          KILL_OLD_MYSQLD=0
          ;;
        --no-kill-proxysql)
          KILL_OLD_PROXYSQL=0
          ;;
        *)
          echo "ERROR: unknown parameter \"$param\""
          usage
          exit 1
          ;;
      esac
      shift
  done

  # handle positional parameters (we only expect one)
  for i in $positional_params; do
    WORKDIR=$(cd $i && pwd)
    break
  done
}

# Extracts the version from a version string
#
# Globals
#   None
#
# Arguments
#   Parameter 1: the path to the mysqld binary
#
# Outputs
#   Writes a string with the major/minor version numbers
#   Such as "5.7" or "8.0"
function get_mysql_version() {
  local mysqld_path="$1"
  local mysqld_version=$(${mysqld_path} --version)
  if echo "$mysqld_version" | grep -qe "[[:space:]]5\.5\."; then
    echo "5.5"
  elif echo "$mysqld_version" | grep -qe "[[:space:]]5\.6\."; then
    echo "5.6"
  elif echo "$mysqld_version" | grep -qe "[[:space:]]5\.7\."; then
    echo "5.7"
  elif echo "$mysqld_version" | grep -qe "[[:space:]]8\.0\."; then
    echo "8.0"
  elif echo "$mysqld_version" | grep -qe "[[:space:]]8\.4\."; then
    echo "8.4"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.1\."; then
    echo "10.1"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.2\."; then
    echo "10.2"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.3\."; then
    echo "10.3"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.4\."; then
    echo "10.4"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.5\."; then
    echo "10.5"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.6\."; then
    echo "10.6"
  elif echo "$version_string" | grep -qe "[[:space:]]10\.11\."; then
    echo "10.11"
  else
    echo "Line $LINENO: Cannot determine the MySQL version: $mysqld_version"
    echo "This script needs to be updated."
    exit 1
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
        echo "ERROR ($LINENO): Missing version string in comparison"
        return 1
    fi

    version_1="$( normalize_version "$version_1" )"
    version_2="$( normalize_version "$version_2" )"

    if [[ ! " = == > >= < <= != " =~ " $op " ]]; then
        echo "ERROR ($LINENO) Unknown operation : $op"
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

function start_pxc_node(){
  local cluster_name=$1
  local baseport=$2
  local NODES=3
  local addr="$LOCALHOST_IP"
  local WSREP_CLUSTER_NAME="--wsrep_cluster_name=$cluster_name"
  local bootstrap_node

  pushd "$PXC_BASEDIR" > /dev/null

  # Creating default my.cnf file
  echo "[mysqld]" > my.cnf
  echo "basedir=${PXC_BASEDIR}" >> my.cnf
  echo "innodb_file_per_table" >> my.cnf
  echo "innodb_autoinc_lock_mode=2" >> my.cnf
  echo "wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so" >> my.cnf
  echo "wsrep_node_incoming_address=$addr" >> my.cnf
  echo "core-file" >> my.cnf
  echo "log-output=none" >> my.cnf
  echo "server-id=1" >> my.cnf
  echo "skip-replica-start" >> my.cnf
  echo "gtid-mode=ON" >> my.cnf
  echo "enforce-gtid-consistency" >> my.cnf
  echo "log-replica-updates" >> my.cnf
  echo "log-bin" >> my.cnf
  echo "user=$OS_USER" >> my.cnf
  if compare_versions "5.6" "<" "$MYSQL_VERSION"; then
    echo "wsrep_slave_threads=2" >> my.cnf
    echo "pxc_maint_transition_period=1" >> my.cnf
  fi
  if [[ $USE_IPVERSION == "v6" ]]; then
    echo "bind-address = ::" >> my.cnf
  fi

  if compare_versions "$MYSQL_VERSION" "<" "8.0"; then
    echo "innodb_locks_unsafe_for_binlog=1" >> my.cnf
    echo "wsrep_sst_method=rsync" >> my.cnf
    echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
  else
    echo "log-error-verbosity=3" >> my.cnf
    echo "wsrep_sst_method=xtrabackup-v2" >> my.cnf
  fi
  # Add 8.4+ options here
  if compare_versions "$MYSQL_VERSION" ">=" "8.4"; then
    echo "mysql-native-password=ON" >> my.cnf
  fi

  echo "[sst]" >> my.cnf
  echo "wsrep_debug=1" >> my.cnf
  if [[ $USE_IPVERSION == "v6" ]]; then
    echo "sockopt=",pf=ip6"" >> my.cnf
  fi

  # Assume that node1 is the bootstrapped node
  bootstrap_node="${PXC_BASEDIR}/${cluster_name}1"

  WSREP_CLUSTER=""
  for i in `seq 1 $NODES`; do
    rbase1="$(( baseport + (10 * $i ) ))"
    local laddr
    if [[ $USE_IPVERSION == "v6" ]]; then
      laddr="[$addr]:$(( rbase1 + 1 ))"
    else
      laddr="$addr:$(( rbase1 + 1 ))"
    fi
    WSREP_CLUSTER+="${laddr},"
  done
  # remove trailing comma
  WSREP_CLUSTER=${WSREP_CLUSTER%,}
  WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm://$WSREP_CLUSTER"

  for i in `seq 1 $NODES`; do
    # Base port for this node
    rbase1="$(( baseport + (10 * $i ) ))"

    if [[ $USE_IPVERSION == "v6" ]]; then
      # gmcast.listen_addr
      LADDR1="[::]:$(( rbase1 + 1 ))"

      # wsrep_node_address
      LADDR2="[$addr]:$(( rbase1 + 1 ))"

      # IST receive address
      RADDR1="[$addr]:$(( rbase1 + 3 ))"

      # SST receive address
      RADDR2="[$addr]:$(( rbase1 + 5 ))"

      # wsrep_node_incoming_address
      MYADDR1="[$addr]:${rbase1}"
    else
      LADDR1="$addr:$(( rbase1 + 1 ))"
      LADDR2="$addr:$(( rbase1 + 1 ))"
      RADDR1="$addr:$(( rbase1 + 3 ))"
      RADDR2="$addr:$(( rbase1 + 5 ))"
    fi
    node="${PXC_BASEDIR}/${cluster_name}${i}"

    # clear the datadir
    rm -rf "$node"

    mkdir -p "$node"
    ${MID} --datadir=$node  > $WORKDIR/logs/startup_${cluster_name}${i}.err 2>&1 || exit 1;

    # Copy the certs from the bootstrapped node
    # Since the certs must all be from the same node
    if [[ $bootstrap_node != $node ]]; then
      cp ${bootstrap_node}/*.pem ${node}
    fi

    if [ $i -eq 1 ]; then
      WSREP_NEW_CLUSTER=" --wsrep-new-cluster "
    else
      WSREP_NEW_CLUSTER=""
    fi

    if [[ $USE_IPVERSION == "v6" ]]; then
      # Workaround, otherwise the wsrep_incoming_addresses isn't set correctly
      WSREP_IPV6_OPTIONS=" --wsrep_node_incoming_address=$MYADDR1 "
    else
      WSREP_IPV6_OPTIONS=""
    fi

    ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/my.cnf \
      --datadir=$node \
      $WSREP_CLUSTER_ADD  \
      --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;ist.recv_addr=$RADDR1" \
      --wsrep_node_address=$LADDR2 \
      $WSREP_IPV6_OPTIONS \
      --wsrep_sst_receive_address=$RADDR2 \
      --log-error=$WORKDIR/logs/${cluster_name}${i}.err \
      --socket=/tmp/${cluster_name}${i}.sock \
      --port=$rbase1 $WSREP_CLUSTER_NAME \
      $WSREP_NEW_CLUSTER > $WORKDIR/logs/${cluster_name}${i}.err 2>&1 &
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/${cluster_name}${i}.sock ping > /dev/null 2>&1; then
        echo "Started PXC ${cluster_name}${i}. BasePort: $rbase1  Socket: /tmp/${cluster_name}${i}.sock"
        break
      fi
      if [[ $X == ${PXC_START_TIMEOUT} ]]; then
          echo "One of the nodes failed to start even after waiting for ${PXC_START_TIMEOUT} seconds."
          echo "Please check the error logs for more information. Error logs can be foung in $WORKDIR/logs/"
          exit 1
      fi
    done
  done

  popd > /dev/null
}


function start_async_slave() {
  local cluster_name=$1
  local baseport=$2
  # Creating default my.cnf file

  pushd "$PXC_BASEDIR" > /dev/null

  echo "[mysqld]" > my-slave.cnf
  echo "basedir=${PXC_BASEDIR}" >> my-slave.cnf
  echo "innodb_file_per_table" >> my-slave.cnf
  echo "innodb_autoinc_lock_mode=2" >> my-slave.cnf
  if compare_versions "$MYSQL_VERSION" "<" "8.0"; then
    echo "innodb_locks_unsafe_for_binlog=1" >> my-slave.cnf
  fi
  echo "core-file" >> my-slave.cnf
  echo "log-output=none" >> my-slave.cnf
  echo "server-id=$baseport" >> my-slave.cnf
  echo "skip-replica-start" >> my-slave.cnf
  echo "gtid-mode=ON" >> my-slave.cnf
  echo "enforce-gtid-consistency" >> my-slave.cnf
  echo "log-replica-updates" >> my-slave.cnf
  echo "log-bin" >> my-slave.cnf
  echo "user=$OS_USER" >> my-slave.cnf
  if [[ $USE_IPVERSION == "v6" ]]; then
    echo "bind-address = ::" >> my-slave.cnf
  fi

  # Add 8.0+ options here
  if compare_versions "$MYSQL_VERSION" ">=" "8.0"; then
    echo "log-error-verbosity=3" >> my-slave.cnf
  fi
  # Add 8.4+ options here
  if compare_versions "$MYSQL_VERSION" ">=" "8.4"; then
    echo "mysql-native-password=ON" >> my-slave.cnf
  fi

  # This is a requirement for proxysql-admin
  echo "read-only=1" >> my-slave.cnf

  local rbase1="${baseport}"
  local node="${PXC_BASEDIR}/${cluster_name}_slave"

  # clear the datadir
  rm -rf "$node"

  if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
    mkdir -p $node
    if  [ ! "$(ls -A $node)" ]; then
      ${MID} --datadir=$node  > $WORKDIR/logs/startup_${cluster_name}_slave.err 2>&1 || exit 1;
    fi
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > $WORKDIR/logs/startup_${cluster_name}_slave.err 2>&1 || exit 1;
  fi

  ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/my-slave.cnf \
      --datadir=$node \
      --log-error=$WORKDIR/logs/${cluster_name}_slave.err \
      --socket=/tmp/${cluster_name}_slave.sock \
      --port=$rbase1 \
      > $WORKDIR/logs/${cluster_name}_slave.err 2>&1 &
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/${cluster_name}_slave.sock ping > /dev/null 2>&1; then
      echo "Started PXC ${cluster_name}_slave. BasePort: $rbase1  Socket: /tmp/${cluster_name}_slave.sock"
      break
    fi
  done

  popd > /dev/null
}

function cleanup_handler() {
  if [[ $ALLOW_SHUTDOWN == "Yes" ]]; then
    if [[ $RUN_TEST -ne 0 ]]; then
      echo "NOTICE: Terminating all mysqld, proxysql and other related processes"
      pkill -SIGTERM -x mysqld
      pkill -SIGTERM -x proxysql
      # wsrep_sst_xtrabackup-v2 could be hanging in some cases.
      pkill -SIGTERM -x wsrep_sst_xtrabackup-v2
    fi
  fi
}

#
# Start of script execution
# ================================================
#
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi
parse_args $*

if [[ -z $WORKDIR ]]; then
  echo "No valid parameters were passed. Need relative workdir setting. Retry."
  exit 1
fi

trap cleanup_handler EXIT

if [[ $USE_IPVERSION == "v4" ]]; then
  LOCALHOST_IP="127.0.0.1"
  LOCALHOST_DOMAIN="127.%"
elif [[ $USE_IPVERSION == "v6" ]]; then
  LOCALHOST_IP="::1"
  LOCALHOST_DOMAIN="%"
fi

# Find the localhost alias in /etc/hosts
LOCALHOST_NAME=$(grep "^${LOCALHOST_IP}" /etc/hosts | awk '{ print $2 }' | head -1)
echo "Localhost name:${LOCALHOST_NAME}  ip:${LOCALHOST_IP}  domain:${LOCALHOST_DOMAIN}"

# Check to if there are multiple matching entries for the localhost name
# If so, try to use the version-specific name if possible
if [[ $LOCALHOST_NAME == "localhost" ]]; then
  count=$(grep "[ \t]localhost[ \t]" /etc/hosts | wc -l)
  if [[ $count -gt 1 ]]; then
    if [[ $USE_IPVERSION == "v4" ]]; then
      LOCALHOST_NAME="localhost4"
    else
      LOCALHOST_NAME="localhost6"
    fi

    count=$(grep -w "${LOCALHOST_NAME}" /etc/hosts | wc -l)
    if [[ $count -ne 1 ]]; then
      echo "ERROR: Could not find a unique localhost entry in /etc/hosts, exiting"
      exit 1
    fi
  echo "Using ${LOCALHOST_NAME} for Localhost"
  fi
fi

declare ROOT_FS=$WORKDIR
mkdir -p $WORKDIR/logs

if [[ $KILL_OLD_MYSQLD -eq 1 ]]; then
  echo "Shutting down currently running mysqld instances"
  sudo pkill -9 -x mysqld
fi

if [[ $KILL_OLD_PROXYSQL -eq 1 ]]; then
  echo "Shutting down currently running proxysql instances"
  sudo pkill -9 -x proxysql
fi

#
# Check file locations before doing anything
#

pushd "$WORKDIR" > /dev/null

echo "Looking for ProxySQL directory..."
PROXYSQL_BASE=$(ls -1td proxysql-2* | grep -v ".tar" | head -n1)
if [[ -z $PROXYSQL_BASE ]]; then
  echo "ERROR! Could not find ProxySQL directory. Terminating"
  exit 1
fi
export PATH="$WORKDIR/$PROXYSQL_BASE/usr/bin:$PATH"
PROXYSQL_BASE="${WORKDIR}/$PROXYSQL_BASE"
echo "....Found ProxySQL directory at $PROXYSQL_BASE"

echo "Looking for ProxySQL executable"
if [[ ! -x $PROXYSQL_BASE/usr/bin/proxysql ]]; then
  echo "ERROR! Could not find proxysql executable in $PROXYSQL_BASE/usr/bin"
  exit 1
fi
echo "....Found ProxySQL executable in $PROXYSQL_BASE/usr/bin"

echo "Looking for proxysql-admin..."
if [[ ! -r $WORKDIR/proxysql-admin ]]; then
  echo "ERROR! Could not find proxysql-admin in $WORKDIR/"
  exit 1
fi
echo "....Found proxysql-admin in $WORKDIR/"

echo "Looking for percona-scheduler-admin..."
if [[ ! -r $WORKDIR/percona-scheduler-admin ]]; then
  echo "ERROR! Could not find percona-scheduler-admin in $WORKDIR/"
  exit 1
fi
echo "....Found percona-scheduler-admin in $WORKDIR/"

echo "Looking for proxysql-admin.cnf..."
if [[ ! -r $PROXYSQL_BASE/etc/proxysql-admin.cnf ]]; then
  echo ERROR! Cannot find $PROXYSQL_BASE/etc/proxysql-admin.cnf
  exit 1
fi
echo "....Found proxysql-admin.cnf in $PROXYSQL_BASE/etc/proxysql-admin.cnf"


#Check PXC binary tar ball
echo "Looking for the PXC tarball..."
PXC_TAR=$(ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1)
if [[ -z $PXC_TAR ]];then
  echo "ERROR! Percona-XtraDB-Cluster binary tarball does not exist. Terminating"
  exit 1
fi
echo "....Found PXC tarball at ./$PXC_TAR"

# Try to find the basedir from the tarball name
PXCBASE_DIR=${PXC_TAR%.gz}
PXCBASE_DIR=${PXC_TAR%.tar}

if [[ -d ${PXCBASE_DIR} ]]; then
  PXCBASE=${PXCBASE_DIR}
  echo "Using existing PXC directory : $PXCBASE"
else
  echo "Removing existing basedir (if found)"
  find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+

  echo "Extracting PXC tarball..."

  # Separate the gunzip from the tar (doesn't work on Centos7)
  if [[ $PXC_TAR =~ .*\.gz$ ]]; then
    gunzip "${PXC_TAR}"
    PXC_TAR=${PXC_TAR%.gz}
  fi

  if [[ -x ${PXC_TAR} ]]; then
    echo "ERROR! Cannot find the tar file : ${PXC_TAR}"
    exit 1
  fi
  tar -xf $PXC_TAR
  PXCBASE=$(ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1)
  echo "....PXC tarball extracted"
fi
export PATH="$WORKDIR/$PXCBASE/bin:$PATH"
export PXC_BASEDIR="${WORKDIR}/$PXCBASE"


echo "Looking for mysql client..."
if [[ ! -e $PXC_BASEDIR/bin/mysql ]] ;then
  echo "ERROR! Could not find the mysql client"
  exit 1
fi
echo "....Found the mysql client in $PXC_BASEDIR/bin"

echo "Looking for my_print_defaults client..."
if [[ ! -e $PXC_BASEDIR/bin/my_print_defaults ]] ;then
  echo "ERROR! Could not find the my_print_defaults client"
  exit 1
fi
echo "....Found the my_print_defaults in $PXC_BASEDIR/bin"

echo "Starting ProxySQL..."
rm -rf $WORKDIR/proxysql_db; mkdir $WORKDIR/proxysql_db
if [[ ! -r /etc/proxysql.cnf ]]; then
  echo "ERROR! This user($(whoami)) needs read permissions on /etc/proxysql.cnf"
  echo "something like: 'sudo chmod +r /etc/proxysl.cnf' needs to be run"
  echo "proxysql is started as this user and reads the cnf file"
  echo "This is for TEST purposes and should not be done in PRODUCTION."
  exit 1
fi

if [[ ! -x $PROXYSQL_BASE/usr/bin/proxysql ]]; then
  echo "ERROR! Could not find proxysql executable : $PROXYSQL_BASE/usr/bin/proxysql"
  exit 1
fi

echo "Removing the previous proxysql logs"
rm -f $WORKDIR/proxysql_db/proxysql.log
$PROXYSQL_BASE/usr/bin/proxysql -D $WORKDIR/proxysql_db $PROXYSQL_EXTRA_OPTIONS --foreground > $WORKDIR/proxysql_db/proxysql.log 2>&1 &
echo "....ProxySQL started. Redirecting the logs to $WORKDIR/proxysql_db/proxysql.log"


echo "Creating link: $WORKDIR/pxc-bin --> $PXC_BASEDIR"
rm -f $WORKDIR/pxc-bin
ln -s "$PXC_BASEDIR" "$WORKDIR/pxc-bin"

echo "Creating link: $WORKDIR/proxysql-bin --> $PROXYSQL_BASE"
rm -f $WORKDIR/proxysql-bin
ln -s "$PROXYSQL_BASE" "$WORKDIR/proxysql-bin"


MYSQL_VERSION=$(get_mysql_version "${PXC_BASEDIR}/bin/mysqld")
MYSQL_CLIENT_VERSION=$(get_mysql_version "${PXC_BASEDIR}/bin/mysql")

echo "MySQL Version is $MYSQL_VERSION"
echo "MySQL Client Version is $MYSQL_CLIENT_VERSION"

echo "Initializing PXC..."
if [[ $MYSQL_VERSION == "5.6" ]]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
elif [[ $MYSQL_VERSION == "5.7" ]]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [[ $MYSQL_VERSION == "8.0" ]]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [[ $MYSQL_VERSION == "8.4" ]]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
else
  echo "Unknown/unexpected MySQL version: $MYSQL_VERSION"
  exit 1
fi
echo "....PXC initialized"


echo "Starting cluster one..."
WSREP_CLUSTER=""
NODES=0
start_pxc_node cluster_one 4100
echo "....cluster one started"

# Create the needed accounts on the master
echo "Creating accounts on the cluster"
if [[ $MYSQL_VERSION == "5.6" ]]; then
  ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock <<EOF
GRANT ALL ON *.* TO admin@'${LOCALHOST_DOMAIN}' identified by 'admin' WITH GRANT OPTION;
GRANT SELECT ON SYS.* TO monitor@'${LOCALHOST_DOMAIN}' identified by 'monitor';
-- CREATE USER '${REPL_USER}'@'${LOCALHOST_NAME}' IDENTIFIED BY '${REPL_PASSWORD}';
-- GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${LOCALHOST_NAME}';
FLUSH PRIVILEGES;
EOF
elif [[ $MYSQL_VERSION == "5.7" ]]; then
  ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock <<EOF
GRANT ALL ON *.* TO admin@'%' IDENTIFIED BY 'admin' WITH GRANT OPTION;
-- CREATE USER '${REPL_USER}'@'${LOCALHOST_NAME}' IDENTIFIED BY '${REPL_PASSWORD}';
-- GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${LOCALHOST_NAME}';
FLUSH PRIVILEGES;
EOF
elif [[ $MYSQL_VERSION > "8.0" || $MYSQL_VERSION == "8.0" ]]; then
  # For 8.0+ separate out the user creation from the grant
  ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock <<EOF
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED WITH mysql_native_password BY 'admin';
GRANT ALL ON *.* TO admin@'%' WITH GRANT OPTION;
-- CREATE USER '${REPL_USER}'@'${LOCALHOST_NAME}' IDENTIFIED WITH mysql_native_password BY '${REPL_PASSWORD}';
-- GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${LOCALHOST_NAME}';
FLUSH PRIVILEGES;
EOF
fi

echo "Starting cluster one async slave..."
start_async_slave cluster_one 4190
echo "....cluster one async slave started"

# Setup the slave (note that slave is not started automatically)
echo "Setting up slave for async replication"

if [[ $MYSQL_VERSION == "5.6" ]]; then
  ${PXC_BASEDIR}/bin/mysql -S/tmp/cluster_one_slave.sock -uroot <<EOF
GRANT ALL ON *.* TO admin@'${LOCALHOST_NAME}' identified by 'admin' WITH GRANT OPTION;
GRANT REPLICATION CLIENT ON *.* TO 'monitor'@'${LOCALHOST_NAME}' IDENTIFIED BY 'monit0r';
CHANGE MASTER TO MASTER_HOST='$LOCALHOST_IP', MASTER_PORT=4110, MASTER_USER='${REPL_USER}', MASTER_PASSWORD='${REPL_PASSWORD}', MASTER_AUTO_POSITION=1;
FLUSH PRIVILEGES;
EOF
elif [[ $MYSQL_VERSION == "5.7" ]]; then
  ${PXC_BASEDIR}/bin/mysql -S/tmp/cluster_one_slave.sock -uroot <<EOF
GRANT ALL ON *.* TO admin@'%' identified by 'admin' WITH GRANT OPTION;
CHANGE MASTER TO MASTER_HOST='$LOCALHOST_IP', MASTER_PORT=4110, MASTER_USER='${REPL_USER}', MASTER_PASSWORD='${REPL_PASSWORD}', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master-a';
FLUSH PRIVILEGES;
EOF
elif [[ $MYSQL_VERSION > "8.0" || $MYSQL_VERSION == "8.0" ]]; then
  # For 8.0+ separate out the user creation from the grant
  ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one_slave.sock <<EOF
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED WITH mysql_native_password BY 'admin';
GRANT ALL ON *.* TO admin@'%' WITH GRANT OPTION;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='$LOCALHOST_IP', SOURCE_PORT=4110, SOURCE_USER='${REPL_USER}', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1 FOR CHANNEL 'source-a';
FLUSH PRIVILEGES;
EOF
fi


echo "Copying over proxysql-admin.cnf files to /etc"
if [[ ! -r $PROXYSQL_BASE/etc/proxysql-admin.cnf ]]; then
  echo ERROR! Cannot find $PROXYSQL_BASE/etc/proxysql-admin.cnf
  exit 2
fi
sudo cp $PROXYSQL_BASE/etc/proxysql-admin.cnf /etc/proxysql-admin.cnf
sudo chown $OS_USER:$OS_USER /etc/proxysql-admin.cnf
sudo sed -i "s|\/var\/lib\/proxysql|$PROXYSQL_BASE|" /etc/proxysql-admin.cnf

if [[ ! -e $(sudo which bats 2> /dev/null) ]] ;then
  pushd $ROOT_FS
  git clone https://github.com/sstephenson/bats
  cd bats
  sudo ./install.sh /usr
  popd
fi

CLUSTER_ONE_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -Bs -e "select @@port")
sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_ONE_PORT\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_HOSTNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_HOSTNAME[ \t]*=.*$|export CLUSTER_HOSTNAME=\"${LOCALHOST_NAME}\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_one\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$|export WRITER_HOSTGROUP_ID=\"10\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$|export READER_HOSTGROUP_ID=\"11\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$|export BACKUP_WRITER_HOSTGROUP_ID=\"12\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$|export OFFLINE_HOSTGROUP_ID=\"13\"|" /etc/proxysql-admin.cnf

if [[ $RUN_TEST -eq 1 ]]; then

  # Disable existing login.cnf usage
  if [ -e "/dummypathnonexisting/.mylogin.cnf" ]; then
    error "" "/dummypathnonexisting/.mylogin.cnf found. This should not happen.";
    exit 1
  fi
  export MYSQL_TEST_LOGIN_FILE="/dummypathnonexisting/.mylogin.cnf"

  echo ""
  echo "================================================================"
  echo "proxysql-admin generic bats test log"
  sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
        bats $SCRIPT_DIR/generic-test.bats
  echo "================================================================"
  echo ""

  echo ""
  echo "================================================================"
  echo "percona-scheduler-admin args test log"
  sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
        bats $SCRIPT_DIR/scheduler-args.bats
  echo "================================================================"
  echo ""

  if [[ ${#TEST_SUITES[@]} -gt 0 ]]; then
    for test_file in ${TEST_SUITES[@]}; do
      echo "cluster_one : $test_file"
      SECONDS=0

      sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
            bats $SCRIPT_DIR/$test_file
      rc=$?
      if (( $SECONDS > 60 )) ; then
        let "minutes=(SECONDS%3600)/60"
        let "seconds=(SECONDS%3600)%60"
        echo "Completed in $minutes minute(s) and $seconds second(s)"
      else
        echo "Completed in $SECONDS seconds"
      fi

      if [[ $rc -ne 0 ]]; then
        ${PXC_BASEDIR}/bin/mysql --user=admin --password=admin --host=$LOCALHOST_IP --port=6032 --protocol=tcp \
          -e "select hostgroup_id,hostname,port,status,weight,comment from runtime_mysql_servers order by hostgroup_id,status,hostname,port" 2>/dev/null
        echo "********************************"
        echo "* $test_file failed, the servers (ProxySQL+PXC) will be left running"
        echo "* for debugging purposes."
        echo "********************************"
        ALLOW_SHUTDOWN="No"
        exit 1
      fi
      echo "================================================================"
      echo ""
    done
    echo ""
  fi
fi

if [[ $USE_CLUSTER_TWO -eq 1 ]]; then

  echo "Starting cluster two..."
  WSREP_CLUSTER=""
  NODES=0
  start_pxc_node cluster_two 4200
  echo "....cluster two started"

  echo "Starting cluster two async slave..."
  start_async_slave cluster_two 4290
  echo "....cluster two async slave started"

  echo "Creating accounts on the cluster"
  if [[ $MYSQL_VERSION == "5.6" ]]; then
    ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock <<EOF
GRANT ALL ON *.* TO admin@'${LOCALHOST_NAME}' identified by 'admin' WITH GRANT OPTION;
GRANT SELECT ON SYS.* TO monitor@'${LOCALHOST_NAME}' identified by 'monitor';
FLUSH PRIVILEGES;
EOF
  elif [[ $MYSQL_VERSION == "5.7" ]]; then
    ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock <<EOF
GRANT ALL ON *.* TO admin@'%' IDENTIFIED BY 'admin' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  elif [[ $MYSQL_VERSION > "8.0" || $MYSQL_VERSION == "8.0" ]]; then
    # For 8.0 separate out the user creation from the grant
    ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock <<EOF
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED WITH mysql_native_password BY 'admin';
GRANT ALL ON *.* TO admin@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  fi

  # Setup the slave (note that slave is not started automatically)
  echo "Setting up slave for async replication"

  if [[ $MYSQL_VERSION == "5.6" ]]; then
    ${PXC_BASEDIR}/bin/mysql -S/tmp/cluster_two_slave.sock -uroot <<EOF
GRANT ALL ON *.* TO admin@'${LOCALHOST_NAME}' identified by 'admin' WITH GRANT OPTION;
GRANT REPLICATION CLIENT ON *.* TO 'monitor'@'${LOCALHOST_NAME}' IDENTIFIED BY 'monit0r';
CHANGE MASTER TO MASTER_HOST='$LOCALHOST_IP', MASTER_PORT=4210, MASTER_USER='${REPL_USER}', MASTER_PASSWORD='${REPL_PASSWORD}', MASTER_AUTO_POSITION=1;
FLUSH PRIVILEGES;
EOF
  elif [[ $MYSQL_VERSION == "5.7" ]]; then
    ${PXC_BASEDIR}/bin/mysql -S/tmp/cluster_two_slave.sock -uroot <<EOF
GRANT ALL ON *.* TO admin@'%' identified by 'admin' WITH GRANT OPTION;
CHANGE MASTER TO MASTER_HOST='$LOCALHOST_IP', MASTER_PORT=4210, MASTER_USER='${REPL_USER}', MASTER_PASSWORD='${REPL_PASSWORD}', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master-a';
FLUSH PRIVILEGES;
EOF
  elif [[ $MYSQL_VERSION > "8.0" || $MYSQL_VERSION == "8.0" ]]; then
    # For 8.0 separate out the user creation from the grant
    ${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two_slave.sock <<EOF
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED WITH mysql_native_password BY 'admin';
GRANT ALL ON *.* TO admin@'%' WITH GRANT OPTION;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='$LOCALHOST_IP', SOURCE_PORT=4210, SOURCE_USER='${REPL_USER}', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1 FOR CHANNEL 'source-a';
FLUSH PRIVILEGES;
EOF
  fi

  echo ""
  CLUSTER_TWO_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -Bs -e "select @@port")
  sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_TWO_PORT\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_two\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$|export WRITER_HOSTGROUP_ID=\"20\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$|export READER_HOSTGROUP_ID=\"21\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$|export BACKUP_WRITER_HOSTGROUP_ID=\"22\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$|export OFFLINE_HOSTGROUP_ID=\"23\"|" /etc/proxysql-admin.cnf
  echo "================================================================"
  echo ""

  if [[ $RUN_TEST -eq 1 ]]; then
    for test_file in ${TEST_SUITES[@]}; do
      echo "cluster_two : $test_file"
      SECONDS=0

      sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
            bats $SCRIPT_DIR/$test_file
      rc=$?

      if (( $SECONDS > 60 )) ; then
        let "minutes=(SECONDS%3600)/60"
        let "seconds=(SECONDS%3600)%60"
        echo "Completed in $minutes minute(s) and $seconds second(s)"
      else
        echo "Completed in $SECONDS seconds"
      fi

      if [[ $rc -ne 0 ]]; then
        ${PXC_BASEDIR}/bin/mysql --user=admin --password=admin --host=$LOCALHOST_IP --port=6032 --protocol=tcp \
          -e "select hostgroup_id,hostname,port,status,weight,comment from runtime_mysql_servers order by hostgroup_id,status,hostname,port" 2>/dev/null
        echo "********************************"
        echo "* $test_file failed, the servers (ProxySQL+PXC)will be left running"
        echo "* for debugging purposes."
        echo "********************************"
        ALLOW_SHUTDOWN="No"
        exit 1
      fi
      echo "================================================================"
      echo ""
    done
    echo ""
  fi
fi


# Run the second suite of tests (scheduler testing)
if [[ $RUN_TEST -eq 1 ]]; then

  # Disable existing login.cnf usage
  if [ -e "/dummypathnonexisting/.mylogin.cnf" ]; then
    error "" "/dummypathnonexisting/.mylogin.cnf found. This should not happen.";
    exit 1
  fi
  export MYSQL_TEST_LOGIN_FILE="/dummypathnonexisting/.mylogin.cnf"


  echo "================================================================"
  echo "Cleaning up ProxySQL config"
  # Need to clear out any previous entries in ProxySQL
  CLUSTER_ONE_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -Bs -e "select @@port")
  sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_ONE_PORT\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export CLUSTER_HOSTNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_HOSTNAME[ \t]*=.*$|export CLUSTER_HOSTNAME=\"${LOCALHOST_NAME}\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_one\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$|export WRITER_HOSTGROUP_ID=\"10\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$|export READER_HOSTGROUP_ID=\"11\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$|export BACKUP_WRITER_HOSTGROUP_ID=\"12\"|" /etc/proxysql-admin.cnf
  sudo sed -i "0,/^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$|export OFFLINE_HOSTGROUP_ID=\"13\"|" /etc/proxysql-admin.cnf
  sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH\
        bats $SCRIPT_DIR/disable_proxysql.bats

  if [[ $USE_CLUSTER_TWO -eq 1 ]]; then
    CLUSTER_TWO_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -Bs -e "select @@port")
    sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_TWO_PORT\"|" /etc/proxysql-admin.cnf
    sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_two\"|" /etc/proxysql-admin.cnf
    sudo sed -i "0,/^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITER_HOSTGROUP_ID[ \t]*=.*$|export WRITER_HOSTGROUP_ID=\"20\"|" /etc/proxysql-admin.cnf
    sudo sed -i "0,/^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READER_HOSTGROUP_ID[ \t]*=.*$|export READER_HOSTGROUP_ID=\"21\"|" /etc/proxysql-admin.cnf
    sudo sed -i "0,/^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export BACKUP_WRITER_HOSTGROUP_ID[ \t]*=.*$|export BACKUP_WRITER_HOSTGROUP_ID=\"22\"|" /etc/proxysql-admin.cnf
    sudo sed -i "0,/^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export OFFLINE_HOSTGROUP_ID[ \t]*=.*$|export OFFLINE_HOSTGROUP_ID=\"23\"|" /etc/proxysql-admin.cnf
    sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
          bats $SCRIPT_DIR/disable_proxysql.bats
  fi
  echo "================================================================"

  for test_file in ${TEST_SUITES2[@]}; do
    echo "cluster_one : $test_file"
    SECONDS=0

    sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
          bats $SCRIPT_DIR/$test_file
    rc=$?
    if (( $SECONDS > 60 )) ; then
      let "minutes=(SECONDS%3600)/60"
      let "seconds=(SECONDS%3600)%60"
      echo "Completed in $minutes minute(s) and $seconds second(s)"
    else
      echo "Completed in $SECONDS seconds"
    fi

    if [[ $rc -ne 0 ]]; then
      ${PXC_BASEDIR}/bin/mysql --user=admin --password=admin --host=$LOCALHOST_IP --port=6032 --protocol=tcp \
        -e "select hostgroup_id,hostname,port,status,weight,comment from runtime_mysql_servers order by hostgroup_id,status,hostname,port" 2>/dev/null
      echo "********************************"
      echo "* $test_file failed, the servers (ProxySQL+PXC) will be left running"
      echo "* for debugging purposes."
      echo "********************************"
      ALLOW_SHUTDOWN="No"
      exit 1
    fi
    echo "================================================================"
    echo ""
  done
  echo ""


  if [[ $USE_CLUSTER_TWO -eq 1 ]]; then
    for test_file in ${TEST_SUITES2[@]}; do
      echo "cluster_two : $test_file"
      SECONDS=0

      sudo WORKDIR=$WORKDIR SCRIPTDIR=$SCRIPT_DIR USE_IPVERSION=$USE_IPVERSION TEST_NAME=$TEST_NAMES PATH=$PATH \
            bats $SCRIPT_DIR/$test_file
      rc=$?

      if (( $SECONDS > 60 )) ; then
        let "minutes=(SECONDS%3600)/60"
        let "seconds=(SECONDS%3600)%60"
        echo "Completed in $minutes minute(s) and $seconds second(s)"
      else
        echo "Completed in $SECONDS seconds"
      fi

      if [[ $rc -ne 0 ]]; then
        ${PXC_BASEDIR}/bin/mysql --user=admin --password=admin --host=$LOCALHOST_IP --port=6032 --protocol=tcp \
          -e "select hostgroup_id,hostname,port,status,weight,comment from runtime_mysql_servers order by hostgroup_id,status,hostname,port" 2>/dev/null
        echo "********************************"
        echo "* $test_file failed, the servers (ProxySQL+PXC)will be left running"
        echo "* for debugging purposes."
        echo "********************************"
        ALLOW_SHUTDOWN="No"
        exit 1
      fi
      echo "================================================================"
      echo ""
    done
    echo ""
  fi
fi
