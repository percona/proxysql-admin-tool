## Generic bats tests

@test "run proxysql-admin under root privileges" {
if [[ $(id -u) -ne 0 ]] ; then
        skip "Skipping this test, because you are NOT running under root"
fi
run proxysql-admin
echo "$output"
    [ "$status" -eq  1 ]
    [ "${lines[0]}" = "Usage: [ options ]" ]
}

@test "run proxysql-admin without any arguments" {
run sudo proxysql-admin
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage: [ options ]" ]
}

@test "run proxysql-admin --help" {
run sudo proxysql-admin --help
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage: [ options ]" ]
}

@test "run proxysql-admin with wrong option" {
run sudo proxysql-admin test
echo "$output"
    [ "$status" -eq 0 ]
}

@test "run proxysql-admin --config-file without parameters" {
run sudo proxysql-admin --config-file
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin check default configuration file" {
run ls /etc/proxysql-admin.cnf 
echo "$output"
        [ "$status" -eq 0 ]
		[ "${lines[0]}" == "/etc/proxysql-admin.cnf" ]
}

@test "run proxysql-admin --proxysql-username without parameters" {
run sudo proxysql-admin --proxysql-username
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --proxysql-port without parameters" {
run sudo proxysql-admin --proxysql-port
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --proxysql-hostname without parameters" {
run sudo proxysql-admin --proxysql-hostname
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --cluster-username without parameters" {
run sudo proxysql-admin --cluster-username
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --cluster-port without parameters" {
run sudo proxysql-admin --cluster-port
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --cluster-hostname without parameters" {
run sudo proxysql-admin --cluster-hostname
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --cluster-app-username without parameters" {
run sudo proxysql-admin --cluster-app-username
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --monitor-username without parameters" {
run sudo proxysql-admin --monitor-username
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --mode without parameters" {
run sudo proxysql-admin --mode
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --write-node without parameters" {
run sudo proxysql-admin --write-node
echo "$output"
        [ "$status" -eq 1 ]
}

@test "run proxysql-admin --syncusers without parameters" {
run sudo proxysql-admin --syncusers
echo "$output"
        [ "$status" -eq 1 ]
}