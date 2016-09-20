#!/bin/bash
# This script will assist with configuring ProxySQL in combination with Percona XtraDB cluster.
# Version 1.0
###############################################################################################

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --user=user_name, -u user_name         User to use when connecting to the Percona XtraDB Cluster server node"
    echo " --password[=password], -p[password]    Password to use when connecting to the Percona XtraDB Cluster server node"
    echo " --port=port_num, -P port_num           Port to use when connecting to the Percona XtraDB Cluster server node"
    echo " --host=host_name, -h host_name         Hostname to use when connecting to the Percona XtraDB Cluster server node"
    echo " --socket=path, -S path                 socket to use when connecting to the Percona XtraDB Cluster server node"
    echo " --enable                               Auto-configure Percona XtraDB Cluster nodes into ProxySQL"
    echo " --disable                              Remove Percona XtraDB Cluster configurations from ProxySQL"
    echo " --start                                Starts Percona XTraDB Cluster ProxySQL monitoring daemon"
    echo " --stop                                 Stops Percona XtraDB Cluster ProxySQL monitoring daemon"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=u:p::S:h:P:ed \
  --longoptions=user:,password::,socket:,host:,port:,enable,disable,start,stop,status,help: \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -u | --user )
    usr="$2"
    shift 2
    ;;
    -p | --password )
    case "$2" in
      "")
      read -s -p "Enter PXC password:" INPUT_PASS
      if [ -z "$INPUT_PASS" ]; then
        pass=""
	printf "\nContinuing without PXC password...\n";
      else
        pass="-p$INPUT_PASS"
      fi
      printf "\n"
      ;;
      *)
      pass="-p$2"
      ;;
    esac
    shift 2
    ;;
    -S | --socket )
    socket="-S $2"
    shift 2
    ;;
    -h | --host )
    hostname="-h $2"
    shift 2
    ;;
    -P | --port )
    port="-P $2"
    shift 2
    ;;
    -e | --enable )
    shift
    enable=1
    ;;
    -d | --disable )
    shift
    disable=1
    ;;
    --start )
    shift
    start_daemon=1
    ;;
    --stop )
    shift
    stop_daemon=1
    ;;
    --status )
    shift
    status_daemon=1
    ;;
    --help )
    usage
    exit 0
    ;;
  esac
done

if [[ ! -e `which mysql 2> /dev/null` ]] ;then
  echo "mysql client is not found, please install the mysql client package" 
  exit 1
fi

# Check the options gathered from the command line
if [ -z "$usr" ];then
  echo "The Percona XtraDB Cluster username is required!"
  usage
  exit
elif [[ -z "$hostname" ]]; then
  hostname="-hlocalhost"
elif [[ -z "$port" ]]; then
  port="-P3306"
fi

if [[ -z "$socket" ]];then
  tcp_str="--protocol=tcp"
fi

PIDFILE=/tmp/pxc-proxysql-monitor.pid

proxysql_connection_check(){
  echo -e "\nUsing default ProxySQL connection parameters to configure Percona XtraDB Cluster nodes"
  read -p "Would you like to proceed with default ProxySQL connection parameters [y/n] ? " check_param
  case $check_param in
    y|Y)
    ADMIN_USER="admin"
    ADMIN_PASS="admin"
    PROXYSQL_IP="127.0.0.1"
    PROXYSQL_PORT="6032"
    ;;
    n|N)
    echo -e "\nPlease give custom ProxySQL connection parameters in following format"
    echo -e "<username>:<password>:<ProxySQL IP>:<ProxySQL port>\n"
    read -p "ProxySQL connection parameters : " read_param
    conn_array=(${read_param//:/ })
    if [ `echo ${conn_array[@]} | wc -w` -eq 4 ];then
      if ! mysql -u${conn_array[0]} -p${conn_array[1]} -h${conn_array[2]} -P${conn_array[3]} -e"show tables" >/dev/null 2>/dev/null; then 
        echo "Please enter valid connection parameters! Terminating.."
        exit 1
      else
        ADMIN_USER=${conn_array[0]}
        ADMIN_PASS=${conn_array[1]}
        PROXYSQL_IP=${conn_array[2]}
        PROXYSQL_PORT=${conn_array[3]}
      fi
    else
      echo "Please enter valid connection parameters! Terminating.."
      exit 1
    fi
    ;;
    *)
    echo "Please type [y/n]! Terminating.."
    ;;
  esac
}
check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! $ERROR_MSG. Terminating!"; exit 1; fi
}

check_proxysql(){
  if ! pidof proxysql >/dev/null ; then
    echo "ProxySQL is not running, please check the error log at /var/lib/proxysql/proxysql.log"
    exit 1
  fi
}

# Auto configure Percona XtraDB Cluster nodes into ProxySQL
enable_proxysql(){
  # Checking proxysql binary location
  if [[ ! -e `which proxysql 2> /dev/null` ]]; then
    echo "The proxysql binary was not found, please install the ProxySQL package"  
    exit 1
  elif [[ ! -e `which proxysql_galera_checker 2> /dev/null` ]] ;then
    echo "The proxysql_galera_checker binary was not found, please check ProxySQL package installation"  
    exit 1
  else
    PROXYSQL=`which proxysql`
    PROXYSQL_GALERA_CHECK=`which proxysql_galera_checker`
  fi
  # Check for existing proxysql process
  if ! pidof proxysql >/dev/null ; then
    echo "ProxySQL is not running; please start proxysql service"
    exit 1
  fi
  proxysql_connection_check
  echo -e "\nConfiguring ProxySQL monitoring user.."
  echo -n "Enter ProxySQL monitoring username: "
  read mon_uname
  while [[ -z "$mon_uname" ]]
  do
    echo -n "No input entered, Enter ProxySQL monitoring username: "
    read mon_uname
  done

  read -s -p "Enter ProxySQL monitoring password: " mon_password
  while [[ -z "$mon_password" ]]
  do
    read -s -p "No input entered, Enter ProxySQL monitoring password: " mon_password
  done

  mysql  -u$usr $pass $hostname $port $socket $tcp_str -e "GRANT USAGE ON *.* TO $mon_uname@'%' IDENTIFIED BY '$mon_password';" 2>/dev/null
  check_cmd $?  "Cannot create the ProxySQL monitoring user"
  echo "update global_variables set variable_value='$mon_uname' where variable_name='mysql-monitor_username'; update global_variables set variable_value='$mon_password' where variable_name='mysql-monitor_password'; " | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  check_cmd $?  "Cannot set the mysql-monitor variables in ProxySQL"
  echo "LOAD MYSQL VARIABLES TO RUNTIME;SAVE MYSQL VARIABLES TO DISK;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null

  # Adding Percona XtraDB Cluster nodes to ProxySQL
  echo -e "\n\nAdding the Percona XtraDB Cluster server nodes to ProxySQL"
  echo "DELETE FROM mysql_servers WHERE hostgroup_id=10" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  wsrep_address=(`mysql  -u$usr $pass $hostname $port $socket $tcp_str -Bse "show status like 'wsrep_incoming_addresses'" 2>/dev/null | awk '{print $2}' | sed 's|,| |g'`)
  for i in "${wsrep_address[@]}"; do	
    ws_ip=`echo $i | cut -d':' -f1`
    ws_port=`echo $i | cut -d':' -f2`
    echo "INSERT INTO mysql_servers (hostname,hostgroup_id,port,weight) VALUES ('$ws_ip',10,$ws_port,1000);" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
    check_cmd $? "Failed to add the Percona XtraDB Cluster server node $ws_ip:$ws_port"
  done
  echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null

  # Adding Percona XtraDB Cluster monitoring script

  echo "DELETE FROM SCHEDULER WHERE ID=10;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  check_cmd $?
  echo "INSERT  INTO SCHEDULER (id,active,interval_ms,filename,arg1,arg2,arg3,arg4,arg5) VALUES (10,1,2000,'$PROXYSQL_GALERA_CHECK',10,10,${#wsrep_address[@]},1,'/var/lib/proxysql/galera-check.log');" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  check_cmd $? "Failed to add the Percona XtraDB Cluster monitoring scheduler in ProxySQL"
  echo "LOAD SCHEDULER TO RUNTIME;SAVE SCHEDULER TO DISK;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null

  echo -e "\nConfiguring Percona XtraDB Cluster user to connect through ProxySQL"
  echo -n "Enter Percona XtraDB Cluster user name: "
  read pxc_uname
  while [[ -z "$pxc_uname" ]]
  do
    echo -n "No input entered, Enter Percona XtraDB Cluster user name: "
    read pxc_uname
  done
  read -s -p "Enter Percona XtraDB Cluster user password: " pxc_password
  while [[ -z "$pxc_password" ]]
  do
    read -s -p "No input entered, Enter Percona XtraDB Cluster user password: " pxc_password
  done
  check_user=`mysql  -u$usr $pass $hostname $port $socket $tcp_str -Bse"SELECT user,host FROM mysql.user where user='$pxc_uname' and host='%';"`

  if [[ -z "$check_user" ]]; then
    mysql  -u$usr $pass $hostname $port $socket $tcp_str -e "GRANT CREATE, DROP, LOCK TABLES, REFERENCES, EVENT, ALTER, DELETE, INDEX, INSERT, SELECT, UPDATE, CREATE TEMPORARY TABLES, TRIGGER, CREATE VIEW, SHOW VIEW, ALTER ROUTINE, CREATE ROUTINE  ON test.* TO $pxc_uname@'%' IDENTIFIED BY '$pxc_password';" 2>/dev/null
    check_cmd $? "Cannot add Percona XtraDB Cluster user : $pxc_uname (GRANT)"
    echo "INSERT INTO mysql_users (username,password,active,default_hostgroup) values ('$pxc_uname','$pxc_password',1,10);LOAD MYSQL USERS TO RUNTIME;SAVE MYSQL USERS FROM RUNTIME;SAVE MYSQL USERS TO DISK;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
    check_cmd $? "Cannot add Percona XtraDB Cluster user : $pxc_uname (mysql_users update)"
  else
    echo -e "\nUser ${pxc_uname}@'%' already present in Percona XtraDB Cluster"
  fi

  if [ -f $PIDFILE ]; then
    echo -e "\n$PIDFILE pid file exists"
    echo "Percona XtraDB Cluster ProxySQL monitoring daemon not started"
  else
    start_daemon  > /dev/null 2>&1 &
    echo $! > ${PIDFILE}
    echo -e "\nPercona XtraDB Cluster ProxySQL monitoring daemon started"
  fi
}

# Removing PXC configuration from proxysql
disable_proxysql(){
  proxysql_connection_check
  echo "DELETE FROM mysql_users WHERE default_hostgroup=10;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  check_cmd $? "Cannot delete Percona XtraDB Cluster users from ProxySQL"
  echo "DELETE FROM mysql_servers WHERE hostgroup_id=10;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
  check_cmd $? "Cannot delete Percona XtraDB Cluster nodes from ProxySQL"
  if [ -f $PIDFILE ]; then
    PID=$(cat ${PIDFILE});
    kill ${PID}
    rm -rf ${PIDFILE}
  else
    echo "Percona XtraDB Cluster ProxySQL monitoring daemon is not running"
  fi 
}

# Starts Percona XtraDB Cluster ProxySQL monitoring daemon
start_daemon(){
  while true
  do
    check_proxysql
    current_hosts=(`mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS -Bse"SELECT hostname,port FROM mysql_servers WHERE status='ONLINE'" | sed 's|\t|:|g' | tr '\n' ' '`)
    wsrep_address=(`mysql  -u$usr $pass $hostname $port $socket $tcp_str -Bse "SHOW STATUS LIKE 'wsrep_incoming_addresses'" 2>/dev/null | awk '{print $2}' | sed 's|,| |g'`)
    for i in "${wsrep_address[@]}"; do
      if [[ ! " ${current_hosts[@]} " =~ " ${i} " ]]; then
        echo "DELETE FROM mysql_servers WHERE hostgroup_id=10;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
        for i in "${wsrep_address[@]}"; do	
          ws_ip=`echo $i | cut -d':' -f1`
          ws_port=`echo $i | cut -d':' -f2`
          echo "INSERT INTO mysql_servers (hostname,hostgroup_id,port,weight) VALUES ('$ws_ip',10,$ws_port,1000);" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
          check_cmd $? "Cannot add Percona XtraDB Cluster server node $ws_ip:$ws_port"
        done
        echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" | mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS 2>/dev/null
        break
      fi
    done
    sleep 5
  done
}

# Stops Percona XtraDB Cluster ProxySQL monitoring daemon
stop_daemon(){
  if [ -f $PIDFILE ]; then
    PID=$(cat ${PIDFILE});
    kill ${PID}
    rm -rf ${PIDFILE}
  else
    echo "Percona XtraDB Cluster ProxySQL monitoring daemon is not running"
  fi 
}

# Check status of Percona XtraDB Cluster ProxySQL monitoring daemon

status_daemon(){
  if [ -f $PIDFILE ] ; then
    PID=`cat $PIDFILE`
    if [ -n $PID ]; then
      if ps -p $PID > /dev/null; then
        echo "Percona XtraDB Cluster ProxySQL monitoring daemon is running ($PID)"; 
      else
        echo "Percona XtraDB Cluster ProxySQL monitoring daemon is not running"; 
      fi
    fi
  else
    echo "Percona XtraDB Cluster ProxySQL monitoring daemon is not running"; 
  fi
}


if [ "$enable" == 1 -o "$disable" == 1 -o "$start_daemon"  == 1 -o "$stop_daemon" == 1 -o "$status_daemon" == 1 ]; then
  if [ "$enable" == 1 ];then
    enable_proxysql
    echo "ProxySQL configuration completed!"
  fi

  if [ "$disable" == 1 ];then
    disable_proxysql
    echo "ProxySQL configuration removed!"
  fi

  if [ "$start_daemon" == 1 ];then
    proxysql_connection_check
    if [ -f $PIDFILE ]; then
      echo "$PIDFILE pid file exists"
      echo "Percona XtraDB Cluster ProxySQL monitoring daemon not started"
    else
      check_proxysql
      PXC_NODES_CHECK=`mysql  -h$PROXYSQL_IP -P$PROXYSQL_PORT  -u$ADMIN_USER  -p$ADMIN_PASS -Bse"SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id=10;"`
      if [ $PXC_NODES_CHECK -eq 0 ]; then
        echo "Percona XtraDB Cluster is not configured in ProxySQL. Please add PXC nodes into ProxySQL before starting monitorning daemon."
        exit 1
      else
        start_daemon  > /dev/null 2>&1 &
        echo $! > ${PIDFILE}
        echo "Percona XtraDB Cluster ProxySQL monitoring daemon started"
      fi
    fi
  fi

  if [ "$stop_daemon" == 1 ];then
    stop_daemon
    echo "Percona XtraDB Cluster ProxySQL monitoring daemon stopped"
  fi

  if [ "$status_daemon" == 1 ];then
    status_daemon
  fi
else
  usage
fi

