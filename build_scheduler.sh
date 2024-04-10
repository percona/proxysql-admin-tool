#!/bin/bash
# This script will assist with building the pxc_scheduler_handler
# Version 2.0
###############################################################################################

# This program is copyright 2016-2020 Percona LLC and/or its affiliates.
#
# THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, version 2 or later
#
# You should have received a copy of the GNU General Public License version 2
# along with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA.

# shellcheck disable=SC1094,SC2181,SC1091

source ./proxysql-common || exit

if [ ! -d percona-scheduler ]; then
    git submodule update --init
fi

pushd percona-scheduler || exit

if [[ ! -e $(command -v go 2> /dev/null)  ]]; then
  error "" "go packages not found. Please install golang package."
  exit 1
fi

go mod tidy
go build -v -a -ldflags "-X main.pxcSchedulerHandlerVersion=${PROXYSQL_ADMIN_VERSION}" -o pxc_scheduler_handler

if [ $? -ne 0 ]; then
  error "" "go build process failed with errors. Exiting.."
  exit 1
fi

popd || exit

cp percona-scheduler/pxc_scheduler_handler .
echo -e "Build was successful. The binary can be found in ./pxc_scheduler_handler"

echo -e
./pxc_scheduler_handler --version
