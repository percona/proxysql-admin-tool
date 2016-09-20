proxysql-admin-tool
===================

proxysql-admin-tool is one step solution to configure Percona XtraDB cluster nodes into ProxySQL.

proxysql-admin-tool usage info

```bash
Usage: [ options ]
Options:
 --user=user_name, -u user_name         User to use when connecting to the ProxySQL service
 --password[=password], -p[password]    Password to use when connecting to the ProxySQL service
 --port=port_num, -P port_num           Port to use when connecting to the ProxySQL service
 --host=host_name, -h host_name         Hostname to use when connecting to the ProxySQL service
 --enable                               Auto-configure Percona XtraDB Cluster nodes into ProxySQL
 --disable                              Remove Percona XtraDB Cluster configurations from ProxySQL
 --start                                Starts Percona XtraDB Cluster ProxySQL monitoring daemon
 --stop                                 Stops Percona XtraDB Cluster ProxySQL monitoring daemon
 --status                               Checks Percona XtraDB Cluster ProxySQL monitoring daemon status.
```
Pre-requisites 
--------------
* ProxySQL and Percona XtraDB cluster should be up and running.
* As part of security, make sure to change default user settings in ProxySQL configuration file.

This script will accept five different options to configure/monitor Percona XtraDB Cluster nodes

  __1) --enable__

  It will configure Percona XtraDB Cluster nodes into ProxySQL and start ProxySQL monitoring daemon. ProxySQL monitoring daemon will be running as backgound service to check cluster node membership and re-configure ProxySQL if cluster membership changes occur.
  It will also add two new users into Percona XtraDB Cluster. One is for monitoring cluster nodes through ProxySQL and another for connecting to PXC node via ProxySQL console.

  PS : Please make sure to use super user credentials from PXC to setup to create default users. 
```bash  
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --enable

  Please provide Percona XtraDB Cluster connection parameters to configure PXC nodes into ProxySQL in following format
  <username>:<password>:<hostname>:<port> : root:root:208.88.225.240:3306

  Configuring ProxySQL monitoring user..
  Enter ProxySQL monitoring username: monitor
  Enter ProxySQL monitoring password: 

  Adding the Percona XtraDB Cluster server nodes to ProxySQL

  Configuring Percona XtraDB Cluster user to connect through ProxySQL
  Enter Percona XtraDB Cluster user name: proxysql_user 
  Enter Percona XtraDB Cluster user password:

  Percona XtraDB Cluster ProxySQL monitoring daemon started
  ProxySQL configuration completed!
  $ 
```
  __2) --disable__ 
  
  It will remove Percona XtraDB cluster nodes from ProxySQL and stop ProxySQL monitoring daemon.
```bash
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --disable
  ProxySQL configuration removed! 
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --status
  Percona XtraDB Cluster ProxySQL monitoring daemon is not running
  $ 
```
  __3) --start__ 
  
  Starts Percona XtraDB Cluster ProxySQL monitoring daemon
```bash
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --start
  mysql: [Warning] Using a password on the command line interface can be insecure.

  Please provide Percona XtraDB Cluster connection parameters to configure PXC nodes into ProxySQL in following format
  <username>:<password>:<hostname>:<port> : root:root:208.88.225.240:3306
  Percona XtraDB Cluster ProxySQL monitoring daemon started
  $ 
```

  __4) --stop__
  
  Stops Percona XtraDB Cluster ProxySQL monitoring daemon
```bash
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --stop
  Percona XtraDB Cluster ProxySQL monitoring daemon stopped
  $ 
```
  __5) --status__
  
  Checks status of Percona XtraDB Cluster ProxySQL monitoring daemon
```bash
  $ ./proxysql-admin -uadmin -padmin -h127.0.0.1 -P6032 --status
  Percona XtraDB Cluster ProxySQL monitoring daemon is running (13355)
  $ 
```

