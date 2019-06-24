FROM alpine:latest

COPY . /proxysql-admin-tool

RUN /bin/bash -c -- "while :; do sleep 60; done;"
