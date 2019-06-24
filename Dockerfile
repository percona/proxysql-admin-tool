FROM centos:latest

COPY . /proxysql-admin-tool

CMD /bin/bash -c -- "while :; do sleep 60; done;"
