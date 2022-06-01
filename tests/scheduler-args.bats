## Test of go-scheduler argument handling

#
# Variable initialization
#
source /etc/proxysql-admin.cnf
PXC_BASEDIR=$WORKDIR/pxc-bin
PROXYSQL_BASEDIR=$WORKDIR/proxysql-bin

@test "run percona-scheduler-admin under root privileges" {
    if [[ $(id -u) -ne 0 ]] ; then
        skip "Skipping this test, because you are NOT running under root"
    fi
    run $WORKDIR/percona-scheduler-admin
    echo "$output" >&2
    [ "$status" -eq  1 ]
    [ "${lines[0]}" = "Usage: percona-scheduler-admin [ options ]" ]
}

@test "run percona-scheduler-admin without any arguments" {
    run sudo $WORKDIR/percona-scheduler-admin
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage: percona-scheduler-admin [ options ]" ]
}

@test "run percona-scheduler-admin --help" {
    run sudo $WORKDIR/percona-scheduler-admin --help
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage: percona-scheduler-admin [ options ]" ]
}

@test "run percona-scheduler-admin with wrong option" {
    run sudo $WORKDIR/percona-scheduler-admin test
    echo "$output" >&2
    [ "$status" -eq 2 ]
}

@test "run percona-scheduler-admin --config-file without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --config-file with incorrect filename" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=$SCRIPTDIR/missing_file.txt
    echo "$output" >&2
    [ "$status" -eq 2 ]
}

@test "run percona-scheduler-admin --proxysql-username without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --proxysql-username
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --proxysql-port without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --proxysql-port
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --proxysql-hostname without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --proxysql-hostname
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --cluster-username without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --cluster-username
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --cluster-port without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --cluster-port
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --cluster-hostname without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --cluster-hostname
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --cluster-app-username without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --cluster-app-username
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --monitor-username without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --monitor-username
    echo "$output" >&2
    [ "$status" -eq 1 ]
}

@test "run percona-scheduler-admin --write-node without parameters" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --write-node
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ .*--write-node.* ]]
}

@test "run percona-scheduler-admin --write-node with missing port" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --write-node=1.1.1.1,2.2.2.2:44 --disable
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*--write-node.*expects.* ]]

    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --write-node=[1:1:1:1],[2:2:2:2]:44 --disable
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*--write-node.*expects.* ]]
}

@test "run percona-scheduler-admin --version check" {
    admin_version=$(sudo $WORKDIR/percona-scheduler-admin -v | head -1 | grep --extended-regexp -oe '[1-9]\.[0-9]\.[0-9]+')
    scheduler_version=$(sudo $WORKDIR/percona-scheduler-admin -v | head -1 | grep --extended-regexp -oe '[1-9]\.[0-9]\.[0-9]+')
    proxysql_version=$(sudo $PROXYSQL_BASEDIR/usr/bin/proxysql --help | grep --extended-regexp -oe '[1-9]\.[0-9]\.[0-9]+')
    echo "proxysql_version:$proxysql_version  admin_version:$admin_version  scheduler_version:$scheduler_version" >&2

    # All the versions should be the same
    [ "${proxysql_version}" = "${admin_version}" ]
    [ "${admin_version}" = "${scheduler_version}" ]
}

# Mutually exclusive options
@test "run percona-scheduler-admin --auto-assign-weights, write-node and --update-write-weight options" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --auto-assign-weights --write-node=1.1.1.1,2.2.2.2:44
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*options.are.mutually.exclusive.* ]]

    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --write-node=2.2.2.2:44 --update-write-weight="[::1]:4130,2000"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*options.are.mutually.exclusive.* ]]

    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-write-weight="[::1]:4130,2000" --auto-assign-weights
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*options.are.mutually.exclusive.* ]]
}

# Malformed address in --update-write-weight
@test "run percona-scheduler-admin --update-write-weight" {
    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-write-weight="[::1]:4130av,20s00"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*expected.address.in.format.* ]]

    run sudo $WORKDIR/percona-scheduler-admin --config-file=testsuite.toml --update-write-weight="[::1]:4130,20s00"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ ERROR.*Weight.in.--update-write-weight.requires.a.number.* ]]
}
