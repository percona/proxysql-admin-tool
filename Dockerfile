FROM centos:latest

RUN yum -y install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
RUN yum -y install Percona-XtraDB-Cluster-client

RUN yum -y install which

RUN mkdir -p /opt/proxysql-admin-tool/etc /opt/proxysql-admin-tool/var

COPY . /opt/proxysql-admin-tool

# CMD /bin/bash -c -- "while :; do sleep 60; done;"
