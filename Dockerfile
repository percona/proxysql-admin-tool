# FROM centos:latest
FROM ellerbrock/alpine-mysql-client

RUN mkdir -p /opt/proxysql-admin-tool/etc /opt/proxysql-admin-tool/var

COPY . /opt/proxysql-admin-tool

# CMD /bin/bash -c -- "while :; do sleep 60; done;"
