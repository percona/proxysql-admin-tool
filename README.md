ProxySQL Admin
==============

The ProxySQL Admin (proxysql-admin) solution configures Percona XtraDB cluster nodes into ProxySQL.

Please log ProxySQL Admin bug reports here: https://jira.percona.com/projects/PSQLADM.

proxysql-admin usage info

```bash
Usage: [ options ]
Options:
  --config-file                      Read login credentials from a configuration file
                                     (command line credentials override any configuration file credentials)
  --quick-demo                       Setup a quick demo with no authentication
  --proxysql-datadir=<datadir>       Specify proxysql data directory location
  --proxysql-username=user_name      Username for connecting to the ProxySQL service
  --proxysql-password[=password]     Password for connecting to the ProxySQL service
  --proxysql-port=port_num           Port Nr. for connecting to the ProxySQL service
  --proxysql-hostname=host_name      Hostname for connecting to the ProxySQL service
  --cluster-username=user_name       Username for connecting to the Percona XtraDB Cluster node
  --cluster-password[=password]      Password for connecting to the Percona XtraDB Cluster node
  --cluster-port=port_num            Port Nr. for connecting to the Percona XtraDB Cluster node
  --cluster-hostname=host_name       Hostname for connecting to the Percona XtraDB Cluster node
  --cluster-app-username=user_name   Application username for connecting to the Percona XtraDB Cluster node
  --cluster-app-password[=password]  Application password for connecting to the Percona XtraDB Cluster node
  --use-existing-monitor-password    Do not prompt for a new monitor password if one is provided.
  --without-cluster-app-user         Configure Percona XtraDB Cluster without application user
  --monitor-username=user_name       Username for monitoring Percona XtraDB Cluster nodes through ProxySQL
  --monitor-password[=password]      Password for monitoring Percona XtraDB Cluster nodes through ProxySQL
  --enable, -e                       Auto-configure Percona XtraDB Cluster nodes into ProxySQL
  --disable, -d                      Remove any Percona XtraDB Cluster configurations from ProxySQL
  --node-check-interval=3000         Interval for monitoring node checker script (in milliseconds)
                                     (default: 3000)
  --mode=[loadbal|singlewrite]       ProxySQL read/write configuration mode
                                     currently supporting: 'loadbal' and 'singlewrite'
                                     (default: 'singlewrite')
  --write-node=host_name:port        Writer node to accept write statments.
                                     This option is supported only when using --mode=singlewrite
                                     Can accept a comma delimited list with the first listed being
                                     the highest priority.
  --include-slaves=host_name:port    Add specified slave node(s) to ProxySQL, these nodes will go
                                     into the reader hostgroup and will only be put into
                                     the writer hostgroup if all cluster nodes are down.
                                     Slaves must be read only.  Can accept a comma delimited list.
                                     If this is used make sure 'read_only=1' is in the slave's my.cnf

These options are the possible operations for proxysql-admin.
One of the options below must be provided.
  --adduser                          Adds the Percona XtraDB Cluster application user to the ProxySQL database
  --disable, -d                      Remove any Percona XtraDB Cluster configurations from ProxySQL
  --enable, -e                       Auto-configure Percona XtraDB Cluster nodes into ProxySQL
  --quick-demo                       Setup a quick demo with no authentication
  --syncusers                        Sync user accounts currently configured in MySQL to ProxySQL
                                     (deletes ProxySQL users not in MySQL)
  --sync-multi-cluster-users         Sync user accounts currently configured in MySQL to ProxySQL
                                     (doesn't delete ProxySQL users not in MySQL)
```
Prerequisites
--------------
* ProxySQL and Percona XtraDB Cluster should be up and running.
* For security purposes, please change the default user settings in the ProxySQL configuration file.
* _ProxySQL configuration file(/etc/proxysql-admin.cnf)_
```bash
  # proxysql admin interface credentials.
  export PROXYSQL_DATADIR='/var/lib/proxysql'
  export PROXYSQL_USERNAME='admin'
  export PROXYSQL_PASSWORD='admin'
  export PROXYSQL_HOSTNAME='localhost'
  export PROXYSQL_PORT='6032'

  # PXC admin credentials for connecting to the pxc-cluster-nodes.
  export CLUSTER_USERNAME='admin'
  export CLUSTER_PASSWORD='admin'
  export CLUSTER_HOSTNAME='localhost'
  export CLUSTER_PORT='3306'

  # proxysql monitoring user. the proxysql admin script will create this user
  # in pxc to monitor pxc-nodes.
  export MONITOR_USERNAME='monitor'
  export MONITOR_PASSWORD='monit0r'

  # Application user to connect to pxc-node through proxysql
  export CLUSTER_APP_USERNAME='proxysql_user'
  export CLUSTER_APP_PASSWORD='passw0rd'

  # ProxySQL read/write hostgroup 
  export WRITE_HOSTGROUP_ID='10'
  export READ_HOSTGROUP_ID='11'

  # ProxySQL read/write configuration mode.
  export MODE="singlewrite"
```

It is recommended that you use _--config-file_ to run this proxysql-admin script.

This script will accept two different options to configure Cluster nodes

  __1) --enable__

  This option will add the Percona XtraDB Cluster nodes into the ProxySQL database,
  and will add the cluster monitoring script into the ProxySQL scheduler table for
  checking the cluster status.
  
 ___scheduler___ script info :
  * __proxysql_galera_checker__ : will check desynced nodes, and temporarily deactivate them. This will also call the __proxysql_node_monitor__ script to check cluster node membership, and re-configure ProxySQL if cluster membership changes occur.

```
Note:
         As proxysql_galera_check runs in regular intervals, there is the possibility of a race 
      condition in certain circumstances, for example starting this script twice or more at the 
      same time. To avoid such situations from occuring, a Galera process identifier check file
      was added, which will prevent duplicate  script execution in most cases. Still, it may be 
      possible in some rare cases to circumvent this check if you execute more then one copy of 
      proxysql_galera_check  simultaneously.  Please  note that  running  more then one copy of 
      proxysql_galera_check in the same runtime environment at the same  time is not supported,
      and may lead to undefined behavior.
```
  It will also add two new users into the Percona XtraDB Cluster with the USAGE privilege;
  one is for monitoring cluster nodes through ProxySQL, and another is for connecting
  to the PXC Cluster node via the ProxySQL console.
  
  Note: Please make sure to use super user credentials from Percona XtraDB Cluster
  to setup the default users.

```bash  
$ sudo proxysql-admin --config-file=/etc/proxysql-admin.cnf --enable

This script will assist with configuring ProxySQL for use with
Percona XtraDB Cluster (currently only PXC in combination
with ProxySQL is supported)

ProxySQL read/write configuration mode is singlewrite

Configuring the ProxySQL monitoring user.
ProxySQL monitor user name as per command line/config-file is monitor

User 'monitor'@'127.%' has been added with USAGE privileges

Configuring the Percona XtraDB Cluster application user to connect through ProxySQL
Percona XtraDB Cluster application user name as per command line/config-file is cluster_one

Percona XtraDB Cluster application user 'proxysql_user'@'127.%' has been added with ALL privileges, this user is created for testing purposes

Adding the Percona XtraDB Cluster server nodes to ProxySQL

Write node info
+-----------+--------------+-------+---------+---------+
| hostname  | hostgroup_id | port  | weight  | comment |
+-----------+--------------+-------+---------+---------+
| 127.0.0.1 | 10           | 25000 | 1000000 | WRITE   |
+-----------+--------------+-------+---------+---------+

ProxySQL configuration completed!

ProxySQL has been successfully configured to use with Percona XtraDB Cluster

You can use the following login credentials to connect your application through ProxySQL

mysql --user=proxysql_user -p --host=127.0.0.1 --port=6033 --protocol=tcp 


$ 

mysql> select hostgroup_id,hostname,port,status,comment from mysql_servers;
+--------------+-----------+-------+--------+---------+
| hostgroup_id | hostname  | port  | status | comment |
+--------------+-----------+-------+--------+---------+
| 11           | 127.0.0.1 | 25400 | ONLINE | READ    |
| 10           | 127.0.0.1 | 25000 | ONLINE | WRITE   |
| 11           | 127.0.0.1 | 25100 | ONLINE | READ    |
| 11           | 127.0.0.1 | 25200 | ONLINE | READ    |
| 11           | 127.0.0.1 | 25300 | ONLINE | READ    |
+--------------+-----------+-------+--------+---------+
5 rows in set (0.00 sec)

mysql> 
```
  __2) --disable__ 
  
  This option will remove Percona XtraDB Cluster nodes from ProxySQL and stop
  the ProxySQL monitoring daemon.
```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --disable
Removing default cluster application user from ProxySQL database.
Removing cluster nodes from ProxySQL database.
Removing scheduler script from ProxySQL database.
Removing query rules from ProxySQL database if any.
ProxySQL configuration removed!
$ 

```

___Extra options___
-------------------

__i) --mode__

This option allows you to setup the read/write mode for PXC cluster nodes in
the ProxySQL database based on the hostgroup. For now, the only supported modes
are _loadbal_ and _singlewrite_. _singlewrite_ is the default mode, and it will
configure Percona XtraDB Cluster to only accept writes on a single node only.
All other remaining nodes will be read-only and will only accept read statements. 

With the --write-node option we can control the priority order of what host will
become the writer at any given time. When used the feature will create a config file
which is by default stored as `${CLUSTER_NAME}_host_priority` under your `$PROXYSQL_DATADIR`
folder. Servers can be specified as comma delimited - 10.0.0.51:3306, 10.0.0.52:3306 -
The 51 node will always be in the writer hostgroup if it is ONLINE, if it is OFFLINE
the 52 node will go into the writer hostgroup, and if that node goes down, a node
from the remaining nodes will be randomly chosen for the writer hostgroup.
This new config file will be deleted when --disable is used. This will ensure
a specified writer-node will always be the writer node while it is ONLINE.

The mode _loadbal_ on the other hand is a load balanced set of evenly weighted read/write nodes.
 
_singlewrite_ mode setup:
```bash
$ sudo grep "MODE" /etc/proxysql-admin.cnf
export MODE="singlewrite"
$ 
$ sudo proxysql-admin --config-file=/etc/proxysql-admin.cnf --write-node=127.0.0.1:25000 --enable
ProxySQL read/write configuration mode is singlewrite
[..]
ProxySQL configuration completed!
$

mysql> select hostgroup_id,hostname,port,status,comment from mysql_servers;
+--------------+-----------+-------+--------+---------+
| hostgroup_id | hostname  | port  | status | comment |
+--------------+-----------+-------+--------+---------+
| 11           | 127.0.0.1 | 25400 | ONLINE | READ    |
| 10           | 127.0.0.1 | 25000 | ONLINE | WRITE   |
| 11           | 127.0.0.1 | 25100 | ONLINE | READ    |
| 11           | 127.0.0.1 | 25200 | ONLINE | READ    |
| 11           | 127.0.0.1 | 25300 | ONLINE | READ    |
+--------------+-----------+-------+--------+---------+
5 rows in set (0.00 sec)

mysql> 
```

_loadbal_ mode setup:
```bash
$ sudo proxysql-admin --config-file=/etc/proxysql-admin.cnf --mode=loadbal --enable
This script will assist with configuring ProxySQL (currently only Percona XtraDB cluster in combination with ProxySQL is supported)

ProxySQL read/write configuration mode is loadbal
[..]
ProxySQL has been successfully configured to use with Percona XtraDB Cluster

You can use the following login credentials to connect your application through ProxySQL

mysql --user=proxysql_user --password=*****  --host=127.0.0.1 --port=6033 --protocol=tcp 

$ 

mysql> select hostgroup_id,hostname,port,status,comment from mysql_servers;
+--------------+-----------+-------+--------+-----------+
| hostgroup_id | hostname  | port  | status | comment   |
+--------------+-----------+-------+--------+-----------+
| 10           | 127.0.0.1 | 25400 | ONLINE | READWRITE |
| 10           | 127.0.0.1 | 25000 | ONLINE | READWRITE |
| 10           | 127.0.0.1 | 25100 | ONLINE | READWRITE |
| 10           | 127.0.0.1 | 25200 | ONLINE | READWRITE |
| 10           | 127.0.0.1 | 25300 | ONLINE | READWRITE |
+--------------+-----------+-------+--------+-----------+
5 rows in set (0.01 sec)

mysql> 
```

__ii) --node-check-interval__

This option configures the interval for monitoring via the proxysql_galera_checker script (in milliseconds)

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --node-check-interval=5000 --enable
```
__iii) --adduser__

This option will aid with adding the Cluster application user to the ProxySQL database for you

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --adduser

Adding Percona XtraDB Cluster application user to ProxySQL database
Enter Percona XtraDB Cluster application user name: root   
Enter Percona XtraDB Cluster application user password: 
Added Percona XtraDB Cluster application user to ProxySQL database!
$ 
```
__iv) --syncusers__
                         
This option will sync user accounts currently configured in Percona XtraDB Cluster
with the ProxySQL database except password-less users and admin users.
It also deletes ProxySQL users not in Percona XtraDB Cluster from the ProxySQL database.

```bash
$ /usr/bin/proxysql-admin --syncusers

Syncing user accounts from Percona XtraDB Cluster to ProxySQL

Synced Percona XtraDB Cluster users to the ProxySQL database!
$

From ProxySQL DB
mysql> select username from mysql_users;
+---------------+
| username      |
+---------------+
| monitor       |
| one           |
| proxysql_user |
| two           |
+---------------+
4 rows in set (0.00 sec)

mysql>

From PXC

mysql> select user,host from mysql.user where authentication_string!='' and user not in ('admin','mysql.sys');
+---------------+-------+
| user          | host  |
+---------------+-------+
| monitor       | 192.% |
| proxysql_user | 192.% |
| two           | %     |
| one           | %     |
+---------------+-------+
4 rows in set (0.00 sec)

mysql>

```
__v) --sync-multi-cluster-users__

This option works in the same way as --syncusers but it does not delete ProxySQL users
that are not present in the Percona XtraDB Cluster. It is to be used when syncing proxysql
instances that manage multiple clusters.

__vi) --quick-demo__

This option is used to setup a dummy proxysql configuration.

```bash
$ sudo  proxysql-admin  --enable --quick-demo

You have selected the dry test run mode. WARNING: This will create a test user (with all privileges) in the Percona XtraDB Cluster & ProxySQL installations.

You may want to delete this user after you complete your testing!

Would you like to proceed with '--quick-demo' [y/n] ? y

Setting up proxysql test configuration!

Do you want to use the default ProxySQL credentials (admin:admin:6032:127.0.0.1) [y/n] ? y
Do you want to use the default Percona XtraDB Cluster credentials (root::3306:127.0.0.1) [y/n] ? n

Enter the Percona XtraDB Cluster username (super user): root
Enter the Percona XtraDB Cluster user password: 
Enter the Percona XtraDB Cluster port: 25100
Enter the Percona XtraDB Cluster hostname: localhost


ProxySQL read/write configuration mode is singlewrite

Configuring ProxySQL monitoring user..

User 'monitor'@'127.%' has been added with USAGE privilege

Configuring the Percona XtraDB Cluster application user to connect through ProxySQL

Percona XtraDB Cluster application user 'pxc_test_user'@'127.%' has been added with ALL privileges, this user is created for testing purposes

Adding the Percona XtraDB Cluster server nodes to ProxySQL

ProxySQL configuration completed!

ProxySQL has been successfully configured to use with Percona XtraDB Cluster

You can use the following login credentials to connect your application through ProxySQL

mysql --user=pxc_test_user  --host=127.0.0.1 --port=6033 --protocol=tcp 

$

mysql> select hostgroup_id,hostname,port,status,comment from mysql_servers;
+--------------+-----------+-------+--------+---------+
| hostgroup_id | hostname  | port  | status | comment |
+--------------+-----------+-------+--------+---------+
| 11           | 127.0.0.1 | 25300 | ONLINE | READ    |
| 10           | 127.0.0.1 | 25000 | ONLINE | WRITE   |
| 11           | 127.0.0.1 | 25100 | ONLINE | READ    |
| 11           | 127.0.0.1 | 25200 | ONLINE | READ    |
+--------------+-----------+-------+--------+---------+
4 rows in set (0.00 sec)

mysql> 
 
```

__vii) --include-slaves=host_name:port__

This option will help include specified slave node(s) to the ProxySQL database.
These nodes will go into the reader hostgroup and will only be put into
the writer hostgroup if all cluster nodes are down.  Slaves must be read only.
Can accept a comma delimited list. If this is used make sure 'read_only=1'
is in the slave's my.cnf.

PS : With _loadbal_ mode slave hosts only accepts read/write requests
when all cluster nodes are down.

## ProxySQL Status

Simple script to dump ProxySQL config and stats

__Usage:__

```
proxysql-status admin admin 127.0.0.1 6032
```
