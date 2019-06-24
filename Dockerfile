FROM alpine:latest

COPY . /proxysql-admin-tool

CMD /bin/sh -c -- "while :; do sleep 60; done;"
