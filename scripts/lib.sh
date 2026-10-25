# Shared helpers for lab.sh and scenarios/*.sh (sourced, runs on the host).
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$LAB"

RS="mongodb://mongo1:27017,mongo2:27017,mongo3:27017/shop?replicaSet=rs0"
MONGO_NODES="mongo1 mongo2 mongo3"

step() { printf '\n\033[1;35m== %s ==\033[0m\n' "$*"; }
note() { printf '\033[2m# %s\033[0m\n' "$*"; }
cmd()  { printf '\033[36m%s\033[0m\n' "$*"; }

# SQL on MySQL from the client box (shown as typed).
#   sql 'SELECT ...'          prints the statement and runs it
#   sql_quiet 'SELECT ...'    runs it without printing the statement
sql() {
  cmd "mysql> $1"
  docker exec -i agglab-client mysql -h mysql -uroot -plab shop --table -e "$1" 2>&1 | grep -v "Using a password"
}
sql_quiet() { docker exec -i agglab-client mysql -h mysql -uroot -plab shop "$@" 2>&1 | grep -v "Using a password"; }

# JavaScript in mongosh against the replica set (or another URI with MONGO_URI).
#   js 'db.orders.aggregate(...)'    prints the code and runs it
#   js_quiet '...'                   runs it without printing
js() {
  cmd "> $1"
  docker exec -i agglab-client mongosh --quiet "${MONGO_URI:-$RS}" --eval "$1" 2>&1
}
js_quiet() { docker exec -i agglab-client mongosh --quiet "${MONGO_URI:-$RS}" --eval "$1" 2>&1; }

member_state() {
  docker exec "agglab-$1" mongosh --quiet --eval \
    'const h = db.hello(); print(h.isWritablePrimary ? "PRIMARY" : h.secondary ? "SECONDARY" : "OTHER")' 2>/dev/null || echo DOWN
}
primary_node() {
  local n
  for n in $MONGO_NODES; do [ "$(member_state "$n")" = PRIMARY ] && { echo "$n"; return 0; }; done
  return 1
}
wait_primary() {  # wait_primary CONTAINER
  local i
  for i in $(seq 1 90); do
    [ "$(docker exec "agglab-$1" mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = true ] && return 0
    sleep 1
  done
  echo "agglab-$1 did not become primary within 90s" >&2
  return 1
}
