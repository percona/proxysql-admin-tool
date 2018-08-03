#!/bin/bash -u
# Created by Ramesh Sivaraman, Percona LLC
# The script is used for testing proxysql-admin functionality

# User Configurable Variables
if [[ $# -eq 0 ]]; then
  cat << EOF
No valid parameters were passed. Need relative workdir setting. Retry.

Usage example:
  $ ${path##*/} /sda/proxysql-testing

This test script expects a certain directory layout for the workdir.

  <workdir>/
      proxysql-admin
      proxysql_galera_checker
      Percona-XtraDB-Cluster-XXX.tar.gz
      proxysql-1.4.XXX/
        etc/
          proxysql-admin.cnf
        usr/
          bin/
            proxysql

EOF
  exit 1
fi

WORKDIR=$1

SCRIPT_DIR=$(cd `dirname $0` && pwd)
PXC_START_TIMEOUT=30
SUSER=root
SPASS=
OS_USER=$(whoami)

ROOT_FS=$WORKDIR

mkdir -p $WORKDIR/logs

ps -ef | egrep "mysqld" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null
ps -ef | egrep "node..sock" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null

#
# Check file locations before doing anything
#

cd ${WORKDIR}

echo "Looking for ProxySQL directory..."
PROXYSQL_BASE=$(ls -1td proxysql-1* | grep -v ".tar" | head -n1)
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


#Check PXC binary tar ball
echo "Looking for the PXC tarball..."
PXC_TAR=$(ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1)
if [[ -z $PXC_TAR ]];then
  echo "ERROR! Percona-XtraDB-Cluster binary tarball does not exist. Terminating"
  exit 1
fi
echo "....Found PXC tarball at ./$PXC_TAR"

if [[ -d ${PXC_TAR%.tar.gz} ]]; then
  PXCBASE=${PXC_TAR%.tar.gz}
  echo "Using existing PXC directory : $PXCBASE"
else
  echo "Removing existing basedir (if found)"
  find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+

  echo "Extracting PXC tarball..."
  tar -xzf $PXC_TAR
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

echo "Starting ProxySQL..."
rm -rf $WORKDIR/proxysql_db; mkdir $WORKDIR/proxysql_db
if [[ ! -x $PROXYSQL_BASE/usr/bin/proxysql ]]; then
  echo "ERROR! Could not find proxysql executable : $PROXYSQL_BASE/usr/bin/proxysql"
  exit 1
fi
$PROXYSQL_BASE/usr/bin/proxysql -D $WORKDIR/proxysql_db  $WORKDIR/proxysql_db/proxysql.log &
echo "....ProxySQL started"


echo "Creating link: $WORKDIR/pxc-bin --> $PXC_BASEDIR"
rm -f $WORKDIR/pxc-bin
ln -s "$PXC_BASEDIR" "$WORKDIR/pxc-bin"

echo "Creating link: $WORKDIR/proxysql-bin --> $PROXYSQL_BASE"
rm -f $WORKDIR/proxysql-bin
ln -s "$PROXYSQL_BASE" "$WORKDIR/proxysql-bin"

echo "Initializing PXC..."
if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
fi
echo "....PXC initialized"

function start_pxc_node(){
  local CLUSTER_NAME=$1
  local BASEPORT=$2
  local NODES=3
  local ADDR="127.0.0.1"
  local WSREP_CLUSTER_NAME="--wsrep_cluster_name=$CLUSTER_NAME"
  # Creating default my.cnf file

  pushd "$PXC_BASEDIR" > /dev/null

  cd $PXC_BASEDIR
  echo "[mysqld]" > my.cnf
  echo "basedir=${PXC_BASEDIR}" >> my.cnf
  echo "innodb_file_per_table" >> my.cnf
  echo "innodb_autoinc_lock_mode=2" >> my.cnf
  echo "innodb_locks_unsafe_for_binlog=1" >> my.cnf
  echo "wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so" >> my.cnf
  echo "wsrep_node_incoming_address=$ADDR" >> my.cnf
  echo "wsrep_sst_method=rsync" >> my.cnf
  echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
  echo "wsrep_node_address=$ADDR" >> my.cnf
  echo "core-file" >> my.cnf
  echo "log-output=none" >> my.cnf
  echo "server-id=1" >> my.cnf
  echo "wsrep_slave_threads=2" >> my.cnf
  echo "pxc_maint_transition_period=1" >> my.cnf

  for i in `seq 1 $NODES`;do
    RBASE1="$(( BASEPORT + (10 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 1 ))"
    WSREP_CLUSTER="$LADDR1,${WSREP_CLUSTER}"
    node="${PXC_BASEDIR}/${CLUSTER_NAME}${i}"

    # clear the datadir
    rm -rf "$node"

    if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
      mkdir -p $node
      if  [ ! "$(ls -A $node)" ]; then
        ${MID} --datadir=$node  > $WORKDIR/logs/startup_node${CLUSTER_NAME}${i}.err 2>&1 || exit 1;
      fi
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > $WORKDIR/logs/startup_node${CLUSTER_NAME}${i}.err 2>&1 || exit 1;
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm://$WSREP_CLUSTER"
    fi

    ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/my.cnf \
      --datadir=$node \
      $WSREP_CLUSTER_ADD  \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$WORKDIR/logs/${CLUSTER_NAME}${i}.err \
      --socket=/tmp/${CLUSTER_NAME}${i}.sock --port=$RBASE1 $WSREP_CLUSTER_NAME > $WORKDIR/logs/${CLUSTER_NAME}${i}.err 2>&1 &
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/${CLUSTER_NAME}${i}.sock ping > /dev/null 2>&1; then
        echo "Started PXC ${CLUSTER_NAME}${i}. BasePort: $RBASE1  Socket: /tmp/${CLUSTER_NAME}${i}.sock"
        break
      fi
    done
  done

  popd > /dev/null
}

echo "Starting cluster one..."
WSREP_CLUSTER=""
NODES=0
start_pxc_node cluster_one 4100
echo "....Cluster one started"

echo "Starting cluster two..."
WSREP_CLUSTER=""
NODES=0
start_pxc_node cluster_two 4200
echo "....Cluster two started"

echo "Granting admin privileges on test clusters..."
${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -e"GRANT ALL ON *.* TO admin@'%' identified by 'admin';flush privileges;"
${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -e"GRANT ALL ON *.* TO admin@'%' identified by 'admin';flush privileges;"

echo "Copying over proxysql-admin.cnf files..."
if [[ ! -r $PROXYSQL_BASE/etc/proxysql-admin.cnf ]]; then
  echo ERROR! Cannot find $PROXYSQL_BASE/etc/proxysql-admin.cnf
  exit 2
fi
sudo cp $PROXYSQL_BASE/etc/proxysql-admin.cnf /etc/proxysql-admin.cnf
sudo chown $OS_USER:$OS_USER /etc/proxysql-admin.cnf
sudo sed -i "s|\/var\/lib\/proxysql|$PROXYSQL_BASE|" /etc/proxysql-admin.cnf

echo "Copying over proxysql to /usr/bin"
sudo cp $PROXYSQL_BASE/usr/bin/* /usr/bin/

if [[ ! -e $(sudo which bats 2> /dev/null) ]] ;then
  pushd $ROOT_FS
  git clone https://github.com/sstephenson/bats
  cd bats
  sudo ./install.sh /usr
  popd
fi

echo "proxysql-admin generic bats test log"
sudo WORKDIR=$WORKDIR TERM=xterm bats \
      $SCRIPT_DIR/generic-test.bats

echo ""
echo "proxysql-admin testsuite bats test log for cluster_one"
CLUSTER_ONE_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_one1.sock -Bse"select @@port")
sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_ONE_PORT\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_one\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$|export WRITE_HOSTGROUP_ID=\"10\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$|export READ_HOSTGROUP_ID=\"11\"|" /etc/proxysql-admin.cnf
sudo WORKDIR=$WORKDIR TERM=xterm bats \
      $SCRIPT_DIR/proxysql-admin-testsuite.bats

echo ""
echo "proxysql-admin testsuite bats test log for cluster_two"
CLUSTER_TWO_PORT=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/cluster_two1.sock -Bse"select @@port")
sudo sed -i "0,/^[ \t]*export CLUSTER_PORT[ \t]*=.*$/s|^[ \t]*export CLUSTER_PORT[ \t]*=.*$|export CLUSTER_PORT=\"$CLUSTER_TWO_PORT\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$/s|^[ \t]*export CLUSTER_APP_USERNAME[ \t]*=.*$|export CLUSTER_APP_USERNAME=\"cluster_two\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export WRITE_HOSTGROUP_ID[ \t]*=.*$|export WRITE_HOSTGROUP_ID=\"20\"|" /etc/proxysql-admin.cnf
sudo sed -i "0,/^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$/s|^[ \t]*export READ_HOSTGROUP_ID[ \t]*=.*$|export READ_HOSTGROUP_ID=\"21\"|" /etc/proxysql-admin.cnf
sudo WORKDIR=$WORKDIR TERM=xterm bats \
      $SCRIPT_DIR/proxysql-admin-testsuite.bats


if [[ -e /tmp/cluster_one1.sock ]]; then
  echo "Shutting down cluster_one1"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one1.sock  -u root shutdown
fi
if [[ -e /tmp/cluster_one2.sock ]]; then
  echo "Shutting down cluster_one2"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one2.sock  -u root shutdown
fi
if [[ -e /tmp/cluster_one3.sock ]]; then
  echo "Shutting down cluster_one3"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_one3.sock  -u root shutdown
fi


if [[ -e /tmp/cluster_two1.sock ]]; then
  echo "Shutting down cluster_two1"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two1.sock  -u root shutdown
fi
if [[ -e /tmp/cluster_two2.sock ]]; then
  echo "Shutting down cluster_two2"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two2.sock  -u root shutdown
fi
if [[ -e /tmp/cluster_two3.sock ]]; then
  echo "Shutting down cluster_two3"
  ${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/cluster_two3.sock  -u root shutdown
fi
