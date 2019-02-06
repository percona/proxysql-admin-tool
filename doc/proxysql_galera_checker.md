# proxysql_galera_checker usage info.

`proxysql_galera_checker` script will check Percona XtraDB Cluster desynced nodes, and temporarily deactivate them. Currently, this script is developed to work with proxysql-admin [script](https://github.com/percona/proxysql-admin-tool/blob/v1.4.14-dev/README.md)

This script will also call `proxysql_node_monitor` script. Monitor script will check cluster node membership, and re-configure ProxySQL if cluster membership changes occur. 

eg: If any node goes out from cluster this script will mark as `OFFLINE_HARD` in proxysql database. When it comes back it will mark the node as `ONLINE`.

The galera checker script will be added in ProxySQL [scheduler](https://github.com/sysown/proxysql/blob/master/doc/scheduler.md) table if you use `proxysql-admin` script.

Galera checker usage
```
Usage: proxysql_galera_checker <hostgroup_id write> [hostgroup_id read] [number writers] [writers are readers 0|1] [log_file]

- HOSTGROUP WRITERS   (required)  (0..)   The hostgroup_id that contains nodes that will server 'writes'
- HOSTGROUP READERS   (optional)  (0..)   The hostgroup_id that contains nodes that will server 'reads'
- NUMBER WRITERS      (optional)  (0..)   Maximum number of write hostgroup_id node that can be marked ONLINE
                                          When 0 (default), all nodes can be marked ONLINE
- WRITERS ARE READERS (optional)  (0|1)   When 1 (default), ONLINE nodes in write hostgroup_id will prefer not
                                          to be ONLINE in read hostgroup_id
- LOG_FILE            (optional)  file    logfile where node state checks & changes are written to (verbose)

- LOG_FILE            (optional)  file    logfile where node state checks & changes are written to (verbose)


Notes about the mysql_servers in ProxySQL:

- WEIGHT           Hosts with a higher weight will be prefered to be put ONLINE
- NODE STATUS      * Nodes that are in status OFFLINE_HARD will not be checked nor will their status be changed
                   * SHUNNED nodes are not to be used with Galera based systems, they will be checked and status
                     will be changed to either ONLINE or OFFLINE_SOFT.
```				 
					 
You can configure these parameter in scheduler table with custom configuration as follows:
```
       arg1: HOSTGROUP WRITERS 
       arg2: HOSTGROUP READERS
       arg3: NUMBER WRITERS
       arg4: WRITERS ARE READERS
       arg5: LOG_FILE
```
scheduler table entry.
```
mysql> select * from scheduler\G
*************************** 1. row ***************************
         id: 11
     active: 1
interval_ms: 5000
   filename: /bin/proxysql_galera_checker
       arg1: 10
       arg2: 11
       arg3: 1
       arg4: 1
       arg5: /var/lib/proxysql/cluster_one_proxysql_galera_check.log
    comment: cluster_one
```

You can also use galera checker script with custom PXC proxysql configurations. But there are some limitations to this configuration.
