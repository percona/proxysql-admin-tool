proxysql-admin-tool
===================

proxysql-admin-tool is one step solution to configure Percona XtraDB cluster nodes into ProxySQL.

proxysql-admin-tool usage info

```bash
Usage: [ options ]
Options:
 --proxysql-user=user_name              User to use when connecting to the ProxySQL service
 --proxysql-password[=password]         Password to use when connecting to the ProxySQL service
 --proxysql-port=port_num               Port to use when connecting to the ProxySQL service
 --proxysql-host=host_name              Hostname to use when connecting to the ProxySQL service
 --cluster-user=user_name               User to use when connecting to the Percona XTraDB Cluster node
 --cluster-password[=password]          Password to use when connecting to the Percona XTraDB Cluster node
 --cluster-port=port_num                Port to use when connecting to the Percona XTraDB Cluster node
 --cluster-host=host_name               Hostname to use when connecting to the Percona XTraDB Cluster node
 --enable                               Auto-configure Percona XtraDB Cluster nodes into ProxySQL
 --disable                              Remove Percona XtraDB Cluster configurations from ProxySQL
 --galera-check-interval                Interval for monitoring proxysql_galera_checker script(in milliseconds)
 --mode                                 ProxySQL read/write configuration mode, currently it only support 'loadbal' mode
```
Pre-requisites 
--------------
* ProxySQL and Percona XtraDB cluster should be up and running.
* As part of security, make sure to change default user settings in ProxySQL configuration file.

This script will accept two different options to configure Percona XtraDB Cluster nodes

  __1) --enable__

  It will configure Percona XtraDB Cluster nodes into ProxySQL database and add two cluster monitoring scripts into ProxySQL scheduler table for checking cluster status.
  _scheduler script info :_
  * proxysql_node_monitor : will be checking cluster node membership and re-configure ProxySQL if cluster membership changes occur
  * proxysql_galera_checker : will be checking desynced nodes and temporarily deactivate them

  It will also add two new users into Percona XtraDB Cluster with USAGE privilege. One is for monitoring cluster nodes through ProxySQL and another for connecting to PXC node via ProxySQL console.

  PS : Please make sure to use super user credentials from PXC to setup to create default users.
```bash  
$  ./proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=root --cluster-password=root --cluster-port=3306 --cluster-host=10.101.6.1 --enable

Configuring ProxySQL monitoring user..
Enter ProxySQL monitoring username: monitor
Enter ProxySQL monitoring password: 

User monitor@'%' has been added with USAGE privilege



Adding the Percona XtraDB Cluster server nodes to ProxySQL

Configuring Percona XtraDB Cluster user to connect through ProxySQL
Enter Percona XtraDB Cluster user name: proxysql_user
Enter Percona XtraDB Cluster user password: 

User proxysql_user@'%' has been added with USAGE privilege, please make sure to grant appropriate privileges


Percona XtraDB Cluster ProxySQL monitoring daemon started
ProxySQL configuration completed!
$
```
  __2) --disable__ 
  
  It will remove Percona XtraDB cluster nodes from ProxySQL and stop ProxySQL monitoring daemon.
```bash
  $ ./proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=root --cluster-password=root --cluster-port=3306 --cluster-host=10.101.6.1 --disable
  ProxySQL configuration removed! 
  $ ./proxysql-admin --proxysql-user=admin --proxysql-password=admin  --proxysql-port=6032 --proxysql-host=127.0.0.1 --cluster-user=root --cluster-password=root --cluster-port=3306 --cluster-host=10.101.6.1 --status
  Percona XtraDB Cluster ProxySQL monitoring daemon is not running
  $ 
```
