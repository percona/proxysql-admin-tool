#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# The script is used for testing proxysql-admin functionality

# User Configurable Variables
if [ -z $1 ]; then
  echo "No valid parameters were passed. Need relative workdir setting. Retry.";
  echo "Usage example:"
  echo "$./proxysql-admin-testsuite.sh /sda/proxysql-testing"
  exit 1
else
  WORKDIR=$1
fi
SBENCH="sysbench"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PXC_START_TIMEOUT=200
WORKDIR="${WORKDIR}/$PROXYSQL_BASE_NUMBER"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
ADDR="127.0.0.1"
SUSER=root
SPASS=

if [ -z $WORKDIR ];then
  WORKDIR="${PWD}"
fi 
ROOT_FS=$WORKDIR

mkdir -p $WORKDIR/logs

ps -ef | egrep "mysqld" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null
ps -ef | egrep "node..sock" | grep "$(whoami)" | egrep -v "grep" | xargs kill -9 2>/dev/null

cd ${WORKDIR}

echo "Removing existing basedir"
find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+
find . -maxdepth 1 -type d -name 'proxysql-1.*' -exec rm -rf {} \+

#Check PXC binary tar ball
PXC_TAR=$(ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1)
if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=$(ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1)
  export PATH="$WORKDIR/$PXCBASE/bin:$PATH"
  PXC_BASEDIR="${WORKDIR}/$PXCBASE"
else
  echo "ERROR! Percona-XtraDB-Cluster binary tarball does not exist. Terminating"
  exit 1
fi


PROXYSQL_TAR=$(ls -1td proxysql-*.tar.gz | grep ".tar" | head -n1)
if [ ! -z $PROXYSQL_TAR ];then
  tar -xzf $PROXYSQL_TAR
  PROXYSQL_BASE=$(ls -1td proxysql-1* | grep -v ".tar" | head -n1)
  export PATH="$WORKDIR/$PXCBASE/usr/bin/:$PATH"
  PROXYSQL_BASE="${WORKDIR}/$PROXYSQL_BASE"
else
  echo "ERROR! proxysql binary tarball does not exist. Terminating"
  exit 1
fi

$PROXYSQL_BASE/usr/bin/proxysql -D $PROXYSQL_BASE  $PROXYSQL_BASE/proxysql.log &


if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
fi


start_pxc_node(){
  NODES=3
  # Creating default my.cnf file
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

  for i in `seq 1 $NODES`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    node="${PXC_BASEDIR}/node$i"
    if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
      mkdir -p $node $keyring_node
      if  [ ! "$(ls -A $node)" ]; then 
        ${MID} --datadir=$node  > $WORKDIR/logs/startup_node$i.err 2>&1 || exit 1;
      fi
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > $WORKDIR/logs/startup_node$i.err 2>&1 || exit 1;
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
	  BASEPORT=$RBASE1
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/my.cnf \
      --datadir=$node $WSREP_CLUSTER_ADD \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$WORKDIR/logs/node$i.err \
      --socket=/tmp/node$i.sock --port=$RBASE1 > $WORKDIR/logs/node$i.err 2>&1 &
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/node$i.sock ping > /dev/null 2>&1; then
        echo "Started PXC node$i. Socket : /tmp/node$i.sock"
        break
      fi
    done
  done
}

start_pxc_node

${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/node1.sock -e"GRANT ALL ON *.* TO admin@'%' identified by 'admin';flush privileges;"
sed -i "s/3306/${BASEPORT}/" $PROXYSQL_BASE/etc/proxysql-admin.cnf
sed -i "s|\/var\/lib\/proxysql|$PROXYSQL_BASE|" $PROXYSQL_BASE/etc/proxysql-admin.cnf
sudo cp $PROXYSQL_BASE/etc/proxysql-admin.cnf /etc/proxysql-admin.cnf
sudo cp $PROXYSQL_BASE/usr/bin/* /usr/bin/
 
if [[ ! -e $(which bats 2> /dev/null) ]] ;then
  pushd $ROOT_FS
  git clone https://github.com/sstephenson/bats
  cd bats
  sudo ./install.sh /usr/local
  popd
fi

echo "proxysql-admin generic bats test log"
sudo TERM=xterm bats $SCRIPT_PWD/generic-test.bats 
echo "proxysql-admin testsuite bats test log"
sudo TERM=xterm bats $SCRIPT_PWD/proxysql-admin-testsuite.bats 

${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/node1.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/node2.sock  -u root shutdown
${PXC_BASEDIR}/bin/mysqladmin  --socket=/tmp/node3.sock  -u root shutdown
