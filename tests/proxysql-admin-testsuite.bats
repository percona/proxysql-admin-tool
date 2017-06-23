## proxysql-admin setup tests

@test "run proxysql-admin -d" {
run sudo proxysql-admin -d
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run proxysql-admin -e" {
run sudo proxysql-admin -e <<< 'n'
echo "$output"
    [ "$status" -eq  0 ]
}

@test "run proxysql-admin --syncusers" {
run sudo proxysql-admin --syncusers
echo "$output"
    [ "$status" -eq  0 ]
}
