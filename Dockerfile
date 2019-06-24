FROM alpine:latest

COPY . /proxysql-admin-tool

RUN /bin/sh -c -- "while :; do sleep 60; done;"
