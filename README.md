ProxySQL Admin
==============

The ProxySQL Admin (proxysql-admin) solution configures Percona XtraDB cluster nodes into ProxySQL.

proxysql-admin usage info

```bash
Usage: [ options ]
Options:
 --config-file                   Override login credentials from command line and read login credentials from config file.
 --proxysql-user=user_name       User to use when connecting to the ProxySQL service
 --proxysql-password[=password]  Password to use when connecting to the ProxySQL service
 --proxysql-port=port_num        Port to use when connecting to the ProxySQL service
 --proxysql-host=host_name       Hostname to use when connecting to the ProxySQL service
 --cluster-user=user_name        User to use when connecting to the Percona XtraDB Cluster node
 --cluster-password[=password]   Password to use when connecting to the Percona XtraDB Cluster node
 --cluster-port=port_num         Port to use when connecting to the Percona XtraDB Cluster node
 --cluster-host=host_name        Hostname to use when connecting to the Percona XtraDB Cluster node
 --monitor-user=user_name        User to use for monitoring Percona XtraDB Cluster nodes through ProxySQL
 --monitor-password[=password]   Password to for monitoring Percona XtraDB Cluster nodes through ProxySQL
 --pxc-app-user=user_name        Application user to use when connecting to the Percona XtraDB Cluster node
 --pxc-app-password[=password]   Application password to use when connecting to the Percona XtraDB Cluster node
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

PS : Please try to use _--config-file_ to run proxysql-admin script.

This script will accept two different options to configure Percona XtraDB Cluster nodes

  __1) --enable__

  This option will configure Percona XtraDB Cluster nodes into the ProxySQL database, and add two cluster monitoring scripts into the ProxySQL scheduler table for checking the cluster status.
  _scheduler script info :
  * proxysql_node_monitor : will check cluster node membership, and re-configure ProxySQL if cluster membership changes occur
  * proxysql_galera_checker : will check desynced nodes, and temporarily deactivate them

  It will also add two new users into Percona XtraDB Cluster with USAGE privilege. One is for monitoring cluster nodes through ProxySQL, and the other is for connecting to PXC node via ProxySQL console.

  PS : Please make sure to use super user credentials from PXC to setup to create default users.
```bash  
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --enable
Configuring ProxySQL monitoring user..
ProxySQL monitoring username as per command line is 'monitor'


User 'monitor'@'%' has been added with USAGE privilege


Adding the Percona XtraDB Cluster server nodes to ProxySQL

Configuring Percona XtraDB Cluster application user to connect through ProxySQL
Percona XtraDB Cluster application user name as per command line is 'pxc_app_user'


Percona XtraDB Cluster application user 'pxc_app_user'@'%' has been added with USAGE privilege, please make sure to grant appropriate privileges

ProxySQL configuration completed!
$
```
  __2) --disable__ 
  
  This option will remove Percona XtraDB cluster nodes from ProxySQL and stop the ProxySQL monitoring daemon.
```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --disable
ProxySQL configuration removed!
$ 

```

___Extra options___

__i) --mode__

It will setup read/write mode for cluster nodes in ProxySQL database based on the hostgroup. For now,  the only supported mode is _loadbal_  which will be the default for a load balanced set of evenly weighted read/write nodes.

__ii) --galera-check-interval__

Interval for monitoring proxysql_galera_checker script(in milliseconds)

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --galera-check-interval=5000 --enable
```
__iii) --adduser__

It will help to add Percona XtraDB Cluster application user to ProxySQL database

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --adduser

Adding Percona XtraDB Cluster application user to ProxySQL database
Enter Percona XtraDB Cluster application user name: root   
Enter Percona XtraDB Cluster application user password: 
Added Percona XtraDB Cluster application user to ProxySQL database!
$ 
```
