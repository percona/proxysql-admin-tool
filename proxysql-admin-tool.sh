#!/bin/bash
# This script will help us to configure proxysql with Percona XtraDB cluster.
# Version 1.0
#############################################################################

# User Configurable Variables
PIDFILE=/tmp/pxc-proxysql-monitor.pid

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --user=user_name, -u user_name         user to use when connecting to PXC server"
    echo " --password[=password], -p[password]    password to use when connecting to PXC server"
    echo " --port=port_num, -P port_num           port to use when connecting to PXC server"
    echo " --host=host_name, -h host_name         hostname to use when connecting to PXC server"
    echo " --socket=path, -S path                 socket to use when connecting to PXC server"
    echo " --enable                               Auto configure PXC nodes into ProxySQL"
    echo " --disable                              Remove PXC configurations from ProxySQL"
    echo " --start                                Starts PXC ProxySQL monitoring daemon"
    echo " --stop                                 Stops PXC ProxySQL monitoring daemon"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=u:p::S:h:P:ed \
  --longoptions=user:,password::,socket:,host:,port:,enable,disable,start,stop,help: \
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
      read -s -p "Enter password:" INPUT_PASS
      if [ -z "$INPUT_PASS" ]; then
        pass=""
	printf "\nContinuing without password...\n";
      else
        pass="-p$INPUT_PASS"
      fi
      printf "\n\n"
      ;;
      *)
      pass="$2"
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
    --help )
    usage
    exit 0
    ;;
  esac
done

# Check the options which gathered from command line
if [ -z "$usr" ];then
  echo "PXC username is must!"
  usage
  exit
elif [[ -z "$hostname" ]]; then
  hostname="-hlocalhost"
elif [[ -z "$port" ]]; then
  port="-P3306"
fi

# Make sure only root can run this script
if [ $(id -u) -ne 0 ]; then
  echo "ERROR: This script must be run as root!" 1>&2
  exit
fi

check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! $ERROR_MSG. Terminating!"; exit 1; fi
}

check_proxysql(){
  IS_ALIVE=`/etc/init.d/proxysql status | grep -c "ProxySQL is running"`
  if [ "$IS_ALIVE" != "1" ]; then
    echo "ProxySQL not running, please check error log /var/lib/proxysql/proxysql.log"
    exit 1
  fi
}
#Auto configure PXC nodes into ProxySQL
enable_proxysql(){
  #Checking existing proxysql process
  IS_ALIVE=`/etc/init.d/proxysql status | grep -c "ProxySQL is running"`
  PROCESS_CHK=`ps ax | grep -v grep | grep -c proxysql`
  if [ "$IS_ALIVE" == "1" -o "$PROCESS_CHK" != "0" ]; then
    echo "ProxySQL process is running please clean existing process"
    exit 1
  fi

  if [[ ! -e `which proxysql` ]];then 
    echo "proxysql not found, Please install proxysql package" 
    exit 1
  else
    PROXYSQL=`which proxysql`
  fi

  #Starting proxysql with default configuration
  echo -e "Starting proxysql.."
  /etc/init.d/proxysql initial > /dev/null 2>&1 
  check_cmd $? "ProxySQL initialization failed"

  check_proxysql

  echo -e "\nConfiguring ProxySQL montioring user.."
  echo -n "Enter monitoring username: "
  read mon_uname
  echo -n "Enter monitoring password: "
  read mon_password
  mysql  -u$usr $pass $hostname $port $socket --protocol=tcp -e "GRANT USAGE ON *.* TO $mon_uname@'%' IDENTIFIED BY '$mon_password';" 2>/dev/null
  check_cmd $?  "Cannot create monitoring user"
  echo "update global_variables set variable_value='$mon_uname' where variable_name='mysql-monitor_username'; update global_variables set variable_value='$mon_password' where variable_name='mysql-monitor_password'; " | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
  check_cmd $?  "Cannot set mysql-monitor variables in ProxySQL"
  echo "LOAD MYSQL VARIABLES TO RUNTIME;SAVE MYSQL VARIABLES TO DISK;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null

  echo "Adding PXC nodes to ProxySQL"
  #Adding PXC nodes to ProxySQL
  wsrep_address=(`mysql  -u$usr $pass $hostname $port $socket --protocol=tcp -Bse "show status like 'wsrep_incoming_addresses'" 2>/dev/null | awk '{print $2}' | sed 's|,| |g'`)
  for i in "${wsrep_address[@]}"; do	
    ws_ip=`echo $i | cut -d':' -f1`
    ws_port=`echo $i | cut -d':' -f2`
    echo "INSERT INTO mysql_servers (hostname,hostgroup_id,port,weight) VALUES ('$ws_ip',10,$ws_port,1000);" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
    check_cmd $? "Cannot add PXC node $ws_ip:$ws_port"
  done
  echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null

  #Adding PXC monitoring script
  if [[ ! -e `which galera_check.pl` ]];then 
    wget -O /var/lib/proxysql/galera_check.pl https://raw.githubusercontent.com/Tusamarco/proxy_sql_tools/master/galera_check.pl
    chmod 755 /var/lib/proxysql/galera_check.pl 
    ln -s /var/lib/proxysql/galera_check.pl /usr/bin/galera_check.pl
    GALERA_CHK=`which galera_check.pl`
  else
    GALERA_CHK=`which galera_check.pl`
  fi

  echo "DELETE FROM SCHEDULER WHERE ID=10;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
  check_cmd $?
  echo "INSERT  INTO SCHEDULER (id,active,interval_ms,filename,arg1) VALUES (10,1,2000,'$GALERA_CHK','-u=admin -p=admin -h=127.0.0.1 -H=10:W,10:R -P=6032 --execution_time=1 --retry_down=2 --retry_up=1 --main_segment=1 --debug=0  --log=/var/lib/proxysql/galera-check.log');" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
  check_cmd $? "Cannot add PXC monitoring scheduler in ProxySQL"
  echo "LOAD SCHEDULER TO RUNTIME;SAVE SCHEDULER TO DISK;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null

  echo -e "\nConfiguring PXC user to connect through ProxySQL"
  echo -n "Enter PXC user name: "
  read pxc_uname
  echo -n "Enter PXC user password: "
  read pxc_password
  mysql  -u$usr $pass $hostname $port $socket --protocol=tcp -e "GRANT ALL ON test.* TO $pxc_uname@'%' IDENTIFIED BY '$pxc_password';" 2>/dev/null
  check_cmd $? "Cannot add PXC user : $pxc_uname"
  echo "INSERT INTO mysql_users (username,password,active,default_hostgroup,default_schema) values ('$pxc_uname','$pxc_password',1,10,'test');" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
  check_cmd $? "Cannot add PXC user : $pxc_uname"
  if [ -f $PIDFILE ]; then
    echo "$PIDFILE pid file exists"
  else
    start_daemon  > /dev/null 2>&1 &
    echo $! > ${PIDFILE}
  fi
}

#Stop proxysql service
disable_proxysql(){
  /etc/init.d/proxysql stop > /dev/null 2>&1 
}

#Starts PXC ProxySQL monitoring daemon
start_daemon(){
  check_proxysql
  while true
  do
    check_proxysql
    current_hosts=(`mysql -h127.0.0.1 -P6032 -uadmin -padmin -Bse"SELECT hostname,port FROM mysql_servers WHERE status='ONLINE'" | sed 's|\t|:|g' | tr '\n' ' '`)
    wsrep_address=(`mysql  -u$usr $pass $hostname $port $socket --protocol=tcp -Bse "SHOW STATUS LIKE 'wsrep_incoming_addresses'" 2>/dev/null | awk '{print $2}' | sed 's|,| |g'`)
    for i in "${wsrep_address[@]}"; do
      if [[ ! " ${current_hosts[@]} " =~ " ${i} " ]]; then
        echo "DELETE FROM mysql_servers;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
        for i in "${wsrep_address[@]}"; do	
          ws_ip=`echo $i | cut -d':' -f1`
          ws_port=`echo $i | cut -d':' -f2`
          echo "INSERT INTO mysql_servers (hostname,hostgroup_id,port,weight) VALUES ('$ws_ip',10,$ws_port,1000);" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
          check_cmd $? "Cannot add PXC node $ws_ip:$ws_port"
        done
        echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" | mysql -h127.0.0.1 -P6032 -uadmin -padmin 2>/dev/null
        break
      fi
    done
    sleep 5
  done
}

#Stops PXC ProxySQL monitoring daemon
stop_daemon(){
  if [ -f $PIDFILE ]; then
    PID=$(cat ${PIDFILE});
    kill ${PID}
  else
    echo "PXC proxysql monitoring daemon is not running"
  fi 
}
if [ "$enable" == 1 -o "$disable" == 1 -o "$start_daemon"  == 1 -o "$stop_daemon" == 1 ]; then
  if [ "$enable" == 1 ];then
    enable_proxysql
  fi

  if [ "$disable" == 1 ];then
    disable_proxysql
  fi

  if [ "$start_daemon" == 1 ];then
    if [ -f $PIDFILE ]; then
      echo "$PIDFILE pid file exists"
    else
      start_daemon  > /dev/null 2>&1 &
      echo $! > ${PIDFILE}
    fi
  fi

  if [ "$stop_daemon" == 1 ];then
    stop_daemon
  fi
else
  usage
fi

