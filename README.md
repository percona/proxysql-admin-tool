ProxySQL Admin
==============

The ProxySQL Admin (proxysql-admin) solution configures Percona XtraDB cluster nodes into ProxySQL.

proxysql-admin usage info

```bash
Usage: [ options ]
Options:
 --proxysql-user=user_name       User to use when connecting to the ProxySQL service
 --proxysql-password[=password]  Password to use when connecting to the ProxySQL service
 --proxysql-port=port_num        Port to use when connecting to the ProxySQL service
 --proxysql-host=host_name       Hostname to use when connecting to the ProxySQL service
 --cluster-user=user_name        User to use when connecting to the Percona XTraDB Cluster node
 --cluster-password[=password]   Password to use when connecting to the Percona XTraDB Cluster node
 --cluster-port=port_num         Port to use when connecting to the Percona XTraDB Cluster node
 --cluster-host=host_name        Hostname to use when connecting to the Percona XTraDB Cluster node
 --enable                        Auto-configure Percona XtraDB Cluster nodes into ProxySQL
 --disable                       Remove Percona XtraDB Cluster configurations from ProxySQL
 --galera-check-interval         Interval for monitoring proxysql_galera_checker script(in milliseconds)
 --mode                          ProxySQL read/write configuration mode, currently it only support 'loadbal' mode
 --adduser                       Add Percona XtraDB Cluster application user to ProxySQL database
```
Pre-requisites 
--------------
* ProxySQL and Percona XtraDB cluster should be up and running.
* As part of security, make sure to change default user settings in ProxySQL configuration file.

This script will accept two different options to configure Percona XtraDB Cluster nodes

  __1) --enable

  This option will configure Percona XtraDB Cluster nodes into the ProxySQL database, and add two cluster monitoring scripts into the ProxySQL scheduler table for checking the cluster status.
  _scheduler script info :
  * proxysql_node_monitor : will check cluster node membership, and re-configure ProxySQL if cluster membership changes occur
  * proxysql_galera_checker : will check desynced nodes, and temporarily deactivate them

  It will also add two new users into Percona XtraDB Cluster with USAGE privilege. One is for monitoring cluster nodes through ProxySQL, and the other is for connecting to PXC node via ProxySQL console.

  PS : Please make sure to use super user credentials from PXC to setup to create default users.
```bash  
$  ../proxysql-admin-tool/proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=admin --cluster-password=admin --cluster-port=26000 --cluster-host=10.101.6.1 --galera-check-interval=3000 --enable

Configuring ProxySQL monitoring user..
Enter ProxySQL monitoring username: monitor
Enter ProxySQL monitoring password: 

User monitor@'%' has been added with USAGE privilege


Adding the Percona XtraDB Cluster server nodes to ProxySQL

Configuring Percona XtraDB Cluster application user to connect through ProxySQL
Enter Percona XtraDB Cluster application user name: proxysql_user
Enter Percona XtraDB Cluster application user password: 

Percona XtraDB Cluster application user proxysql_user@'%' has been added with USAGE privilege, please make sure to grant appropriate privileges

ProxySQL configuration completed!
$
```
  __2) --disable__ 
  
  This option will remove Percona XtraDB cluster nodes from ProxySQL and stop the ProxySQL monitoring daemon.
```bash
$  ../proxysql-admin-tool/proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=admin --cluster-password=admin --cluster-port=26000 --cluster-host=10.101.6.1 --galera-check-interval=3000 --disable
ProxySQL configuration removed!
$ 

```

Extra options

__i) --mode__

It will setup read/write mode for cluster nodes in ProxySQL database based on the hostgroup. For now,  the only supported mode is _loadbal_  which will be the default for a load balanced set of evenly weighted read/write nodes.

_ii) --galera-check-interval_

Interval for monitoring proxysql_galera_checker script(in milliseconds)

_iii) --adduser_

It will help to add Percona XtraDB Cluster application user to ProxySQL database

```bash
$   ./proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=admin --cluster-password=admin --cluster-port=26000 --cluster-host=10.101.6.1 --galera-check-interval=3000 --adduser

Adding Percona XtraDB Cluster application user to ProxySQL database
Enter Percona XtraDB Cluster application user name: app_read
Enter Percona XtraDB Cluster application user password: 


Application app_read does not exists in Percona XtraDB Cluster. Would you like to proceed [y/n] ? y

Added Percona XtraDB Cluster application user to ProxySQL database!
$ 
```
