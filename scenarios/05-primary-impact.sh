#!/usr/bin/env bash
# 05 A heavy aggregation on the primary vs on a secondary, measured as the
# latency of point reads on the primary (scripts/probe.js). Each mongod is
# limited to 1 CPU (docker-compose.yml), like a busy production node.
. "$(dirname "$0")/../scripts/lib.sh"

PROBE_URI="mongodb://mongo1:27017/shop?directConnection=true"
AGG='db.orders.aggregate([{$unwind: "$items"}, {$sort: {"items.price": -1, amount: 1}}, {$group: {_id: "$items.sku", top: {$push: "$_id"}}}, {$count: "n"}]).toArray()'
probe() { docker exec -e SECS=12 agglab-client mongosh --quiet "$PROBE_URI" /lab/scripts/probe.js; }
wait_agg() { for _ in $(seq 1 90); do docker exec agglab-client sh -c 'pgrep -f "items.price" >/dev/null' || break; sleep 2; done; }
cpu() { docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' agglab-mongo1 agglab-mongo2 agglab-mongo3 | tr '\n' ' '; }
run_agg() { docker exec -d agglab-client sh -c "mongosh --quiet '$RS&readPreference=$1' --eval '$AGG' >/dev/null 2>&1"; }

note "primary: $(primary_node)"
cmd "aggregation: $AGG"
probe >/dev/null   # warm up
printf '%-22s %s\n' "no aggregation" "$(probe)"
for rp in primary secondary; do
  run_agg "$rp"; sleep 2
  ( sleep 5; printf '%-22s %s\n' "  cpu" "$(cpu)" ) &
  printf '%-22s %s\n' "aggregation on $rp" "$(probe)"
  wait; wait_agg
done
