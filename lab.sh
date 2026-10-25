#!/usr/bin/env bash
# MySQL vs MongoDB aggregation lab. Run ./lab.sh help for commands.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

rs_bootstrap() {
  if [ -z "$(docker exec agglab-mongo1 mongosh --quiet --eval 'db.hello().setName ?? ""')" ]; then
    docker exec agglab-mongo1 mongosh --quiet --eval '
      rs.initiate({_id: "rs0", members: [
        {_id: 0, host: "mongo1:27017", priority: 2}, {_id: 1, host: "mongo2:27017"}, {_id: 2, host: "mongo3:27017"}]})' >/dev/null
    echo "initiated rs0 (mongo1 preferred as primary)"
  fi
  wait_primary mongo1
}

sharded_bootstrap() {
  docker compose --profile sharded up -d --wait cfg shard1 shard2
  docker exec agglab-cfg mongosh --quiet --eval \
    'if (!db.hello().setName) rs.initiate({_id: "cfg", configsvr: true, members: [{_id: 0, host: "cfg:27017"}]})' >/dev/null
  for s in 1 2; do
    docker exec "agglab-shard$s" mongosh --quiet --eval \
      "if (!db.hello().setName) rs.initiate({_id: 'sh$s', members: [{_id: 0, host: 'shard$s:27017'}]})" >/dev/null
  done
  wait_primary cfg; wait_primary shard1; wait_primary shard2
  docker compose --profile sharded up -d --wait mongos
  docker exec agglab-mongos mongosh --quiet --eval '
    for (const s of ["sh1/shard1:27017", "sh2/shard2:27017"])
      if (!db.getSiblingDB("config").shards.findOne({host: s})) sh.addShard(s)' >/dev/null
  local n=${1:-400000}
  docker exec agglab-mongos mongosh --quiet shop --eval '
    if (!db.getSiblingDB("config").collections.findOne({_id: "shop.orders"})) {
      sh.enableSharding("shop");
      sh.shardCollection("shop.orders", {customer_id: "hashed"});
    }' >/dev/null
  if [ "$(docker exec agglab-mongos mongosh --quiet shop --eval 'db.orders.estimatedDocumentCount()')" = 0 ]; then
    docker exec -e N="$n" -e KEEP=1 agglab-client mongosh --quiet "mongodb://mongos:27017/shop" /lab/scripts/load-mongo.js
  fi
  echo "sharded cluster ready: mongos -> cfg, sh1, sh2; shop.orders hashed on customer_id"
}

case "${1:-help}" in
  up)
    docker compose up -d --build --wait
    rs_bootstrap
    echo "ready: mysql, rs0 (mongo1-3), client"
    ;;
  load)
    n=${2:-2000000}
    echo "loading $n orders into MySQL and MongoDB"
    { echo "SET @n = $n;"; cat scripts/load-mysql.sql; } | docker exec -i agglab-client mysql -h mysql -uroot -plab -N 2>&1 | grep -v "Using a password" | tail -1
    docker exec -e N="$n" agglab-client mongosh --quiet "$RS" /lab/scripts/load-mongo.js
    ;;
  up-sharded)
    sharded_bootstrap "${2:-400000}"
    ;;
  run)
    f=$(ls scenarios/"${2:?usage: ./lab.sh run NN}"-*.sh 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "no scenario $2"; exit 1; }
    bash "$f"
    ;;
  status)
    for n in $MONGO_NODES; do printf '  %-7s %s\n' "$n" "$(member_state "$n")"; done
    sql_quiet -N -e "SELECT CONCAT('mysql orders: ', COUNT(*)) FROM orders" 2>/dev/null || echo "mysql: no data"
    js_quiet 'print("mongo orders: " + db.orders.estimatedDocumentCount())' 2>/dev/null || true
    ;;
  down)
    docker compose --profile sharded down
    ;;
  destroy)
    docker compose --profile sharded down -v
    ;;
  help|*)
    cat <<'EOF'
./lab.sh up            start MySQL, the rs0 replica set and the client
./lab.sh load [N]      load N orders (default 2,000,000) into both databases
./lab.sh up-sharded    also start a sharded cluster (cfg, shard1, shard2, mongos)
./lab.sh run NN        run scenarios/NN-*.sh
./lab.sh status        replica set members and row counts
./lab.sh down          stop everything, keep data
./lab.sh destroy       stop everything and delete all data
EOF
    ;;
esac
