ProxySQL Admin
==============

The ProxySQL Admin (proxysql-admin) solution configures Percona XtraDB cluster nodes into ProxySQL.

Please log ProxySQL Admin bug reports here: https://jira.percona.com/projects/PSQLADM.

proxysql-admin usage info

```bash
Usage: proxysql-admin [ options ]
Options:
  --config-file=<config-file>        Read login credentials from a configuration file
                                     (command line and login-file options override any
                                     configuration file values)

  --login-file=<login-file-path>     Read login credentials from an encrypted file.
                                     If the --login-password or --login-password-file options
                                     are not specified, then the user will be prompted
                                     for the password.
                                     (command line options override any login file values)
  --login-password=<password>        The key used to decrypt the encrypted login-file.
                                     This cannot be used with --login-password-file.
  --login-password-file=<path>       Read the key from a file using the <path>.
                                     This cannot be used with --login-password

  --writer-hg=<number>               The hostgroup that all traffic will be sent to
                                     by default. Nodes that have 'read-only=0' in MySQL
                                     will be assigned to this hostgroup.
  --backup-writer-hg=<number>        If the cluster has multiple nodes with 'read-only=0'
                                     and max_writers set, then additional nodes (in excess
                                     of max_writers), will be assigned to this hostgroup.
  --reader-hg=<number>               The hostgroup that read traffic should be sent to.
                                     Nodes with 'read-only=0' in MySQL will be assigned
                                     to this hostgroup.
  --offline-hg=<number>              Nodes that are determined to be OFFLINE will
                                     assigned to this hostgroup.

  --proxysql-datadir=<datadir>       Specify the proxysql data directory location
  --proxysql-username=<user_name>    ProxySQL service username
  --proxysql-password[=<password>]   ProxySQL service password
  --proxysql-port=<port_num>         ProxySQL service port number
  --proxysql-hostname=<host_name>    ProxySQL service hostname

  --cluster-username=<user_name>     Percona XtraDB Cluster node username
  --cluster-password[=<password>]    Percona XtraDB Cluster node password
  --cluster-port=<port_num>          Percona XtraDB Cluster node port number
  --cluster-hostname=<host_name>     Percona XtraDB Cluster node hostname

  --cluster-app-username=<user_name> Percona XtraDB Cluster node application username
  --cluster-app-password[=<password>] Percona XtraDB Cluster node application passwrod
  --without-cluster-app-user         Configure Percona XtraDB Cluster without application user

  --monitor-username=<user_name>     Username for monitoring Percona XtraDB Cluster nodes through ProxySQL
  --monitor-password[=<password>]    Password for monitoring Percona XtraDB Cluster nodes through ProxySQL
  --use-existing-monitor-password    Do not prompt for a new monitor password if one is provided.

  --node-check-interval=<NUMBER>     The interval at which the proxy should connect
                                     to the backend servers in order to monitor the
                                     Galera staus of a node (in milliseconds).
                                     (default: 5000)
  --mode=[loadbal|singlewrite]       ProxySQL read/write configuration mode
                                     currently supporting: 'loadbal' and 'singlewrite'
                                     (default: 'singlewrite')
  --write-node=<IPADDRESS>:<PORT>    Specifies the node that is to be used for
                                     writes for singlewrite mode.  If left unspecified,
                                     the cluster node is then used as the write node.
                                     This only applies when 'mode=singlewrite' is used.
  --max-connections=<NUMBER>         Value for max_connections in the mysql_servers table.
                                     This is the maximum number of connections that
                                     ProxySQL will open to the backend servers.
                                     (default: 1000)
  --max-transactions-behind=<NUMBER> Determines the maximum number of writesets a node
                                     can have queued before the node is SHUNNED to avoid
                                     stale reads.
                                     (default: 100)
  --use-ssl=[yes|no]                 If set to 'yes', then connections between ProxySQL
                                     and the backend servers will use SSL.
                                     (default: no)
  --writers-are-readers=[yes|no|backup]
                                     If set to 'yes', then all writers (backup-writers also)
                                     are added to the reader hostgroup.
                                     If set to 'no', then none of the writers (backup-writers also)
                                     will be added to the reader hostgroup.
                                     If set to 'backup', then only the backup-writers
                                     will be added to the reader hostgroup.
                                     (default: backup)
  --remove-all-servers               When used with --update-cluster, this will remove all
                                     servers belonging to the current cluster before
                                     updating the list.
  --add-query-rule                   Create query rules for synced mysql user. This is applicable
                                     only for singlewrite mode and works only with --syncusers
                                     and --sync-multi-cluster-users options.
  --force                            This option will skip existing configuration checks in
                                     mysql_servers, mysql_users and mysql_galera_hostgroups tables.
                                     This option will only work with __proxysql-admin --enable__.
  --disable-updates                  Disable admin updates for ProxySQL cluster for the
                                     current operation. The default is to not change the
                                     admin variable settings.  If this option is specifed,
                                     these options will be set to false.
                                     (default: updates are not disabled)
  --use-stdin-for-credentials        If set, then the MySQL client will use stdin to send credentials
                                     to the client (instead of process substition).
                                     (default: process subsitution is used)
  --debug                            Enables additional debug logging.
  --help                             Dispalys this help text.

These options are the possible operations for proxysql-admin.
One of the options below must be provided.
  --adduser                          Adds the Percona XtraDB Cluster application user to the ProxySQL database
  --disable, -d                      Remove any Percona XtraDB Cluster configurations from ProxySQL
  --enable, -e                       Auto-configure Percona XtraDB Cluster nodes into ProxySQL
  --update-cluster                   Updates the cluster membership, adds new cluster nodes
                                     to the configuration.
  --update-mysql-version             Updates the mysql-server_version variable in ProxySQL with the version
                                     from a node in the cluster.
  --quick-demo                       Setup a quick demo with no authentication
  --syncusers                        Sync user accounts currently configured in MySQL to ProxySQL
                                     May be used with --enable.
                                     (deletes ProxySQL users not in MySQL)
  --sync-multi-cluster-users         Sync user accounts currently configured in MySQL to ProxySQL
                                     May be used with --enable.
                                     (doesn't delete ProxySQL users not in MySQL)
  --is-enabled                       Checks if the current configuration is enabled in ProxySQL.
  --status                           Returns a status report on the current configuration.
                                     If "--writer-hg=<NUM>" is specified, than the
                                     data corresponding to the galera cluster with that
                                     writer hostgroup is displayed. Otherwise, information
                                     for all clusters will be displayed.
  --version, -v                      Prints the version info
```

___Prerequisites___
-------------------
* ProxySQL and Percona XtraDB Cluster should be up and running.


___ProxySQL Admin Configuration File___
---------------------------------------
* For security purposes, please change the default user settings in the ProxySQL configuration file.
* _ProxySQL configuration file(/etc/proxysql-admin.cnf)_

```bash
  # proxysql admin interface credentials.
  export PROXYSQL_DATADIR='/var/lib/proxysql'
  export PROXYSQL_USERNAME='admin'
  export PROXYSQL_PASSWORD='admin'
  export PROXYSQL_HOSTNAME='localhost'
  export PROXYSQL_PORT='6032'

  # PXC admin credentials for connecting to the pxc-cluster-node.
  export CLUSTER_USERNAME='admin'
  export CLUSTER_PASSWORD='admin'
  export CLUSTER_HOSTNAME='localhost'
  export CLUSTER_PORT='3306'

  # proxysql monitoring user. proxysql admin script will create this user in pxc to monitor pxc-nodes.
  export MONITOR_USERNAME='monitor'
  export MONITOR_PASSWORD='monit0r'

  # Application user to connect to pxc-node through proxysql
  export CLUSTER_APP_USERNAME='proxysql_user'
  export CLUSTER_APP_PASSWORD='passw0rd'

  # ProxySQL hostgroup IDs
  export WRITER_HOSTGROUP_ID='10'
  export READER_HOSTGROUP_ID='11'
  export BACKUP_WRITER_HOSTGROUP_ID='12'
  export OFFLINE_HOSTGROUP_ID='13'

  # ProxySQL read/write configuration mode.
  export MODE="singlewrite"

  # max_connections default (used only when INSERTing a new mysql_servers entry)
  export MAX_CONNECTIONS="1000"

  # Determines the maximum number of writesets a node can have queued
  # before the node is SHUNNED to avoid stale reads.
  export MAX_TRANSACTIONS_BEHIND=100

  # Connections to the backend servers (from ProxySQL) will use SSL
  export USE_SSL="no"

  # Determines if a node should be added to the reader hostgroup if it has
  # been promoted to the writer hostgroup.
  # If set to 'yes', then all writers (including backup-writers) are added to
  # the read hostgroup.
  # If set to 'no', then none of the writers (including backup-writers) are added.
  # If set to 'backup', then only the backup-writers will be added to
  # the read hostgroup.
  export WRITERS_ARE_READERS="backup"
```

It is recommended that you use _--config-file_ to run this proxysql-admin script.


___ProxySQL Admin Login File___
-------------------------------
The login file contains the credentials needed by proxysql-admin in an encrypted format.

This is an example of the unencrypted data.

```bash
# --------------------------------
# This file is constructed as a set of "name=value" pairs.
# Notes:
# (1) Comment lines start with '#' and must be on separate lines
# (2) the name part
#   - The only acceptable values are shown below in this example.
#     Other values will be ignored.
# (3) The value part:
#   - This does NOT use quotes, so any quote character will be part of the value
#   - The entire line will be used (be careful with spaces)
#
# If a value is not specified here, than the default value from the
# configuration file will be used.
# --------------------------------

# --------------------------------
# proxysql admin interface credentials.
# --------------------------------
proxysql.user=admin
proxysql.password=admin
proxysql.host=localhost
proxysql.port=6032

# --------------------------------
# PXC admin credentials for connecting to pxc-cluster-node.
# --------------------------------
cluster.user=admin
cluster.password=admin
cluster.host=localhost
cluster.port=4110

# --------------------------------
# proxysql monitoring user. proxysql admin script will create
# this user in pxc to monitor pxc-nodes.
# --------------------------------
monitor.user=monitor
monitor.password=monitor

# --------------------------------
# Application user to connect to pxc-node through proxysql
# --------------------------------
cluster-app.user=cluster_one
cluster-app.password=passw0rd
```

The credentials information will be used in the following order:
1. credentials provided from the command-line
2. credentails provided in the login-file
3. credentials provided in the ProxySQL admin configuration file


___ProxySQL Admin Login File Usage___
-------------------------------------

### Creating the login-file (encrypting the data)
------------------------------------------------
1. Create the unencrypted data as shown above.
2. Encrypt the data with the proxysql-login-file script
3. Use the login-file with proxysql-admin

```bash
 # create the file as shown above
 $ echo "monitor.user=monitor" > data.cnf
 $ echo "monitor.password=password" >> data.cnf

 # Choose a secret password
 $ passwd="secret"


 # Method (1) : Encrypt this data with --password
 $ proxysql-login-file --in data.cnf --out login-file.cnf --password=${passwd}

 # Method (2a) : Encrypt the data with --password-file
 #               Sending the password via the command-line is insecure,
 #               it's better to use --password-file so that the
 #               password doesn't show up in the command-line
 $ proxysql-login-file --in data.cnf --out login-file.cnf \
      --password-file=<(echo "${passwd}")

 # Method (2b) : Running the command using sudo will not work with
 #               bash's process substition.  In this case, sending the
 #               password via stdin is another option.
 $ sudo echo "${passwd}" | proxysql-login-file --in data.cnf --out login-file.cnf \
                            --password-file=/dev/stdin

 # Method (3) : The script will prompt for the password
 #              if no password is provided via the command-line options.
 $ proxysql-login-file --in data.cnf --out login-file.cnf

 # Remove the unencrypted data file
 $ rm data.cnf


 # Call the proxysql-admin script with the login-file
 $ proxysql-admin --enable --login-file=login-file.cnf \
      --login-password-file=<(echo "${passwd}")

 # Call proxysql-status with the login-file
 $ proxysql-status --login-file=login-file.cnf \
      --login-password-file=<(echo "${passwd}")


```

### Viewing the login-file (decrypting the data)
-----------------------------------------------
1. Decrypt the login-file with the proxysql-login-file-script

```bash
  # Decrypt the login-file with the --decrypt option
  # If --in is not used, the input data will be read from stdin
  # If --out is not used, the unencrypted data will be written to stdout
  $ proxysql-login-file --in login-file.cnf --password=secret --decrypt

    monitor.user=monitor
    monitor.password=password
```


___ProxySQL Admin Functions___
------------------------------
This script can perform the following functions

  __1) --enable__

  This option will create the entry for the Galera hostgroups and add
  the Percona XtraDB Cluster nodes into ProxySQL.
  
  It will also add two new users into the Percona XtraDB Cluster with the USAGE privilege;
  one is for monitoring the cluster nodes through ProxySQL, and another is for connecting
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
+-----------+--------------+--------+-----------+
| hostname  | hostgroup_id | port   | weight    |
+-----------+--------------+--------+-----------+
| 127.0.0.1 | 10           | 25000  | 1000000   |
+-----------+--------------+--------+-----------+

ProxySQL configuration completed!

ProxySQL has been successfully configured to use with Percona XtraDB Cluster

You can use the following login credentials to connect your application through ProxySQL

mysql --user=proxysql_user -p --host=127.0.0.1 --port=6033 --protocol=tcp

$ 

mysql> select hostgroup_id,hostname,port,status from runtime_mysql_servers;
+--------------+-----------+-------+--------+
| hostgroup_id | hostname  | port  | status |
+--------------+-----------+-------+--------+
| 10           | 127.0.0.1 | 25000 | ONLINE |
| 11           | 127.0.0.1 | 25100 | ONLINE |
| 11           | 127.0.0.1 | 25200 | ONLINE |
| 12           | 127.0.0.1 | 25100 | ONLINE |
| 12           | 127.0.0.1 | 25200 | ONLINE |
+--------------+-----------+-------+--------+
5 rows in set (0.00 sec)


mysql> select * from mysql_galera_hostgroups\G
*************************** 1. row ***************************
       writer_hostgroup: 10
backup_writer_hostgroup: 12
       reader_hostgroup: 11
      offline_hostgroup: 13
                 active: 1
            max_writers: 1
  writer_is_also_reader: 2
max_transactions_behind: 100
                comment: NULL
1 row in set (0.00 sec)

mysql> 
```

  __--enable__ may be used at the same time as __--update-cluster__.  If the
  cluster has not been setup, then the enable function will be run.  If the
  cluster has been setup, then the update cluster function will be run.

  __2) --disable__ 
  
  This option will remove Percona XtraDB Cluster nodes from ProxySQL and stop
  the ProxySQL monitoring daemon.
```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --disable
Removing cluster application users from the ProxySQL database.
Removing cluster nodes from the ProxySQL database.
Removing query rules from the ProxySQL database if any.
Removing the cluster from the ProxySQL database.
ProxySQL configuration removed!
$ 

```

  A specific galera cluster can be disabled by using the __--writer-hg__
  option with __--disable__.

  __3) --adduser__

  This option will aid with adding the Cluster application user to the ProxySQL database for you

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --adduser

Adding Percona XtraDB Cluster application user to ProxySQL database
Enter Percona XtraDB Cluster application user name: root   
Enter Percona XtraDB Cluster application user password: 
Added Percona XtraDB Cluster application user to ProxySQL database!
$ 
```

  __4) --syncusers__

  This option will sync user accounts currently configured in Percona XtraDB Cluster
  with the ProxySQL database except password-less users and admin users.
  It also deletes ProxySQL users not in Percona XtraDB Cluster from the ProxySQL database.

  The __--server__ option can be used with __--syncusers__ to specify a
  specific server that will be synced (rather than a PXC cluster).

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

  __5) --sync-multi-cluster-users__

  This option works in the same way as --syncusers but it does not delete ProxySQL users
  that are not present in the Percona XtraDB Cluster. It is to be used when syncing proxysql
  instances that manage multiple clusters.
  
  The __--server__ option can be used with __--sync-multi-cluster-users__ to specify a
  specific server that will be synced (rather than a PXC cluster).


  __6) --add-query-rule__

  Create query rules for synced mysql user. This is applicable only for singlewrite mode and
  works only with --syncusers and --sync-multi-cluster-users options.

```bash
$ sudo proxysql-admin  --syncusers --add-query-rule

Syncing user accounts from PXC to ProxySQL

Note : 'admin' is in proxysql admin user list, this user cannot be addded to ProxySQL
-- (For more info, see https://github.com/sysown/proxysql/issues/709)
Adding user to ProxySQL: test_query_rule
  Added query rule for user: test_query_rule

Synced PXC users to the ProxySQL database!
$
```

  __7) --quick-demo__

  This option is used to setup a dummy proxysql configuration.

```bash
$ sudo  proxysql-admin --quick-demo

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

mysql> select hostgroup_id,hostname,port,status from runtime_mysql_servers;
+--------------+-----------+-------+--------+
| hostgroup_id | hostname  | port  | status |
+--------------+-----------+-------+--------+
| 10           | 127.0.0.1 | 25000 | ONLINE |
| 11           | 127.0.0.1 | 25100 | ONLINE |
| 11           | 127.0.0.1 | 25200 | ONLINE |
| 12           | 127.0.0.1 | 25100 | ONLINE |
| 12           | 127.0.0.1 | 25200 | ONLINE |
+--------------+-----------+-------+--------+
5 rows in set (0.00 sec)

mysql> 
 
```

  __8) --update-cluster__

  This option will check the Percona XtraDB Cluster to see if any new nodes
  have joined the cluster.  If so, the new nodes are added to ProxySQL.
  Any offline nodes are not removed from the cluster by default.

  If used with __--remove-all-servers__, then the server list for this configuration
  will be removed before running the update cluster function.

  A specific galera cluster can be updated by using the __--writer-hg__ option
  with __--update-cluster__.  Otherwise the cluster specified in the config file
  will be updated.

  If __--write-node__ is used with __--update-cluster__, then that node will
  be made the writer node (by giving it a larger weight), if the node is in
  the server list and is ONLINE.  This should only be used if the mode is _singlewrite_.


```bash
$ sudo proxysql-admin --update-cluster --writer-hg=10 --remove-all-servers
Removing all servers from ProxySQL
Cluster node (127.0.0.1:25000) does not exist in ProxySQL, adding to the writer hostgroup(10)
Cluster node (127.0.0.1:25100) does not exist in ProxySQL, adding to the writer hostgroup(10)
Cluster node (127.0.0.1:25200) does not exist in ProxySQL, adding to the writer hostgroup(10)
Waiting for ProxySQL to process the new nodes...

Cluster node info
+---------------+-------+-----------+-------+-----------+
| hostgroup     | hg_id | hostname  | port  | weight    |
+---------------+-------+-----------+-------+-----------+
| writer        | 10    | 127.0.0.1 | 25000 | 1000      |
| reader        | 11    | 127.0.0.1 | 25100 | 1000      |
| reader        | 11    | 127.0.0.1 | 25200 | 1000      |
| backup-writer | 12    | 127.0.0.1 | 25100 | 1000      |
| backup-writer | 12    | 127.0.0.1 | 25200 | 1000      |
+---------------+-------+-----------+------+------------+

Cluster membership updated in the ProxySQL database!

```

  __9) --is-enabled__

  This option will check if a galera cluster (specified by the writer hostgroup,
  either from __--writer-hg__ or from the config file) has any active entries
  in the mysql_galera_hostgroups table in ProxySQL.

  0 is returned if there is an entry corresponding to the writer hostgroup and
  is set to active in ProxySQL.
  1 is returned if there is no entry corresponding to the writer hostgroup.
  2 is returned if there is an entry corresponding to the writer hostgroup but
  is not active.

```bash

$ sudo proxysql-admin --is-enabled --writer-hg=10
The current configuration has been enabled and is active

$ sudo proxysql-admin --is-enabled --writer-hg=20
ERROR (line:2925) : The current configuration has not been enabled


```

  __10) --status__

  If used with the __--writer-hg__ option, this will display information about
  the given Galera cluster which uses that writer hostgroup.  Otherwise it will
  display information about all Galera hostgroups (and their servers) being
  supported by this ProxySQL instance.
  
```bash

$ sudo proxysql-admin --status --writer-hg=10

mysql_galera_hostgroups row for writer-hostgroup: 10
+--------+--------+---------------+---------+--------+-------------+-----------------------+------------------+
| writer | reader | backup-writer | offline | active | max_writers | writer_is_also_reader | max_trans_behind |
+--------+--------+---------------+---------+--------+-------------+-----------------------+------------------+
| 10     | 11     | 12            | 13      | 1      | 1           | 2                     | 100              |
+--------+--------+---------------+---------+--------+-------------+-----------------------+------------------+

mysql_servers rows for this configuration
+---------------+-------+-----------+-------+--------+-----------+----------+---------+-----------+
| hostgroup     | hg_id | hostname  | port  | status | weight    | max_conn | use_ssl | gtid_port |
+---------------+-------+-----------+-------+--------+-----------+----------+---------+-----------+
| writer        | 10    | 127.0.0.1 | 25000 | ONLINE | 1000000   | 1000     | 0       | 0         |
| reader        | 11    | 127.0.0.1 | 25100 | ONLINE | 1000      | 1000     | 0       | 0         |
| reader        | 11    | 127.0.0.1 | 25200 | ONLINE | 1000      | 1000     | 0       | 0         |
| backup-writer | 12    | 127.0.0.1 | 25100 | ONLINE | 1000      | 1000     | 0       | 0         |
| backup-writer | 12    | 127.0.0.1 | 25200 | ONLINE | 1000      | 1000     | 0       | 0         |
+---------------+-------+-----------+-------+--------+-----------+----------+---------+-----------+

```

  __11) --update-mysql-version__
  
  This option will updates mysql server version (specified by the writer hostgroup,
  either from __--writer-hg__ or from the config file) in proxysql db based on 
  online writer node.
  
```bash

$  sudo proxysql-admin --update-mysql-version --writer-hg=10
ProxySQL MySQL version changed to 5.7.26
$

```

___Extra options___
-------------------

__i) --mode__

This option allows you to setup the read/write mode for PXC cluster nodes in
the ProxySQL database based on the hostgroup. For now, the only supported modes
are _loadbal_ and _singlewrite_. _singlewrite_ is the default mode, and it will
configure Percona XtraDB Cluster to only accept writes on a single node only.
Depending on the value of __--writers-are-readers__, the write node may
accept read requests also.
All other remaining nodes will be read-only and will only receive read statements.

With the --write-node option we can control which node ProxySQL will use as the
writer node. The writer node is specified as an address:port - 10.0.0.51:3306
If --write-node is used, the writer node is given a weight of 1000000 (the default
weight is 1000).

The mode _loadbal_ on the other hand is a load balanced set of evenly weighted
read/write nodes.

_singlewrite_ mode setup:

```bash
$ sudo grep "MODE" /etc/proxysql-admin.cnf
export MODE="singlewrite"

$ sudo proxysql-admin --config-file=/etc/proxysql-admin.cnf --write-node=127.0.0.1:25000 --enable
ProxySQL read/write configuration mode is singlewrite
[..]
ProxySQL configuration completed!
$

mysql> select hostgroup_id,hostname,port,status from runtime_mysql_servers;
+--------------+-----------+-------+--------+
| hostgroup_id | hostname  | port  | status |
+--------------+-----------+-------+--------+
| 10           | 127.0.0.1 | 25000 | ONLINE |
| 11           | 127.0.0.1 | 25100 | ONLINE |
| 11           | 127.0.0.1 | 25200 | ONLINE |
| 12           | 127.0.0.1 | 25100 | ONLINE |
| 12           | 127.0.0.1 | 25200 | ONLINE |
+--------------+-----------+-------+--------+
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



mysql> select hostgroup_id,hostname,port,status from runtime_mysql_servers;
+--------------+-----------+-------+--------+
| hostgroup_id | hostname  | port  | status |
+--------------+-----------+-------+--------+
| 10           | 127.0.0.1 | 25000 | ONLINE |
| 10           | 127.0.0.1 | 25100 | ONLINE |
| 10           | 127.0.0.1 | 25200 | ONLINE |
+--------------+-----------+-------+--------+
3 rows in set (0.01 sec)

mysql>

```

__ii) --node-check-interval__

This option configures the interval for the cluster node health monitoring by ProxySQL
(in milliseconds).  This is a global variable and will be used by all clusters that
are being serverd by this ProxySQL instance.  This can only be used with __--enable__.

```bash
$ proxysql-admin --config-file=/etc/proxysql-admin.cnf --node-check-interval=5000 --enable
```

__iii) --write-node__

This option is used to choose which node will be the writer node when the mode
is _singlewrite_.  This option can be used with __--enable__ and __--update-cluster__.

A single IP address and port combination is expected.
For instance, "--write-node=127.0.0.1:3306"

__iv) --force__

  This will skip existing configuration checks with __--enable__ option in mysql_servers,
  mysql_users and mysql_galera_hostgroups tables
  This will also cause certain checks to issue warnings instead of an error,
  allowing the operation to proceed.


__v) --disable_updates__

This option (when used with any command), will disable updating of the
ProxySQL admin checksums (for the mysql query rules, mysql servers,
and mysql users tables). The default is to not to change the admin checksum
variable settings. If this option is specified, then the values of
the admin-checksum_mysql_query_rules, admin-checksum_mysql_servers,
and admin-checksum_mysql_users will be set to 'false'.

__vi) --server__

This option is used with __--syncusers__  or __--sync-multi-cluster-users__ to specify
a single server to sync, rather than a PXC cluster. This server does not have to belong
to a PXC cluster and can be a standalone MySQL node.

## ProxySQL Status

Simple script to dump ProxySQL config and stats

__Usage:__

```
proxysql-status admin admin 127.0.0.1 6032
```
