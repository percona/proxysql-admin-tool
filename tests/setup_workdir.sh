#!/bin/bash
# Created by Mohit Joshi, Percona LLC
# Creation date: 15-April-2021
#
# The script is used for creating the workdir which must be passed to proxysql-admin-testsuite.sh
# for testing the proxysql-admin functionality

# Create Helper Functions

help() {
cat << EOF
Usage:
  ./setup_workdir.sh /path/where/the/workdir/should/be/created
  eg.
  1) ./setup_workdir.sh ~/workdir1
  2) ./setup_workdir.sh /tmp/workdir2
  3) ./setup_workdir.sh workdir3

Note: The script will exit if there exists a directory by the same name
EOF
}

enable_repo() {
# parameters are:
  local repo_name=$1
  local repo_type=$2

# Assuming percona-release utility is installed on the machine
  sudo percona-release enable "$repo_name" "$repo_type"
}

install_package() {
# parameters are stored in array varible:
  local -a pkg_name_arr=("$@")

  if [ -f /usr/bin/yum ]; then
    for file in "${pkg_name_arr[@]}"; do
      sudo yum install -y "$file"
    done
  elif [ -f /usr/bin/apt ]; then
    for file in "${pkg_name_arr[@]}"; do
      sudo apt-get update -y
      sudo apt-get install -y "$file"
    done
  fi
}

# Call the helper function if no argument is passed
if [[ $# -eq 0 ]]; then
  help 
  exit 1
fi

# Check if Proxysql is installed
echo "Looking for proxysql package installed on the machine"
if [[ ! -e $(which proxysql) ]];then
  echo "...ProxySQL not found"
  echo "Installing proxysql2 package"
  enable_repo proxysql testing
  install_package proxysql2
  echo "...ProxySQL installed successfully"
  PROXYSQL=$(which proxysql)
else
  PROXYSQL=$(which proxysql)
  echo "...ProxySQL found at $PROXYSQL"
fi

# Ensure we have read permission on ProxySQL configuration file
sudo chmod 644 /etc/proxysql*.cnf

# Check if mysql client is installed
echo "Looking for mysql client installed on the machine"
if [[ ! -e $(which mysql) ]]; then
  echo "...mysql client not found"
  echo "Installing latest mysql client"
  enable_repo pxc-80 release
  install_package percona-xtradb-cluster-client
  echo "...mysql client install successfully"
else
  echo "...mysql client found at $(which mysql)"
fi

WORKDIR=$1
SKIP_DOWNLOAD=$2
SKIP_DOWNLOAD=${SKIP_DOWNLOAD:=0}

# Fetch PXC versions
LATEST_VERSION=$(git ls-remote --refs --sort='version:refname' --tags https://github.com/percona/percona-xtradb-cluster | \
    grep 'Percona-XtraDB-Cluster-8.0' | tail -n1 | cut -d '/' -f3 | cut -d '-' -f4)
VERSION_SUFFIX=$(git ls-remote --refs --sort='version:refname' --tags https://github.com/percona/percona-xtradb-cluster | \
    grep 'Percona-XtraDB-Cluster-8.0' | tail -n1 | cut -d '/' -f3 | cut -d '-' -f5)

if [ -d "$WORKDIR" ]; then
  echo "Directory with the provided name already exist."
  echo "Exiting..."
  exit 1
else
  mkdir -p "$WORKDIR" "$WORKDIR"/proxysql-2.0/usr/bin "$WORKDIR"/proxysql-2.0/etc
  if [ -d "$WORKDIR" ]; then
    echo "...Work Directory created successfully";
  fi
fi

echo "Looking for ProxySQL Admin Base directory";
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
PROXYSQL_ADMIN_BASEDIR=$(realpath "$SCRIPTPATH"/../)

if [ -f "$PROXYSQL_ADMIN_BASEDIR"/proxysql-admin ]; then
  echo "...ProxySQL Base Directory found at $PROXYSQL_ADMIN_BASEDIR"
else
  echo "...ProxySQL Base Directory not found. Exiting!"
  exit 1
fi

echo "Looking for Percona Scheduler Handler";
if [ -f "$PROXYSQL_ADMIN_BASEDIR"/pxc_scheduler_handler ]; then
  echo "...Percona Scheduler binary found at $PROXYSQL_ADMIN_BASEDIR/pxc_scheduler_handler"
else
  echo "...Not found. Building percona scheduler"
  pushd "$PROXYSQL_ADMIN_BASEDIR" > /dev/null || exit
  bash build_scheduler.sh > /dev/null 2>&1
  popd > /dev/null || exit
fi

echo "Creating Symbolic links"
ln -s "$PROXYSQL" "$WORKDIR"/proxysql-2.0/usr/bin
ln -s "$PROXYSQL_ADMIN_BASEDIR"/proxysql-admin.cnf "$WORKDIR"/proxysql-2.0/etc
for file in proxysql-admin proxysql-common proxysql-admin-common percona-scheduler-admin proxysql-login-file pxc_scheduler_handler
do
  ln -s "$PROXYSQL_ADMIN_BASEDIR"/$file "$WORKDIR"
done;


echo "...Symbolic links created successfully"


echo "Copying config files required for the test"
cp $PROXYSQL_ADMIN_BASEDIR/tests/testsuite.toml $WORKDIR
echo "...Copying done"

if [[ ! $SKIP_DOWNLOAD -eq 1 ]];then
  echo "Fetching the PXC tarball packages"
  wget -O $WORKDIR/Percona-XtraDB-Cluster_${LATEST_VERSION}_Linux.x86_64.glibc2.17-minimal.tar.gz https://www.percona.com/downloads/Percona-XtraDB-Cluster-LATEST/Percona-XtraDB-Cluster-${LATEST_VERSION}/binary/tarball/Percona-XtraDB-Cluster_${LATEST_VERSION}-${VERSION_SUFFIX}_Linux.x86_64.glibc2.17-minimal.tar.gz
  echo "...Successful"
fi

echo "The workdir is ready for use located at: $WORKDIR"
echo "Run: $PROXYSQL_ADMIN_BASEDIR/tests/proxysql-admin-testsuite.sh $WORKDIR"

