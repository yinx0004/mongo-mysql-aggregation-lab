#!/usr/bin/env bash
# 08 Putting a time limit on aggregations.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: per statement and per session"
sql "SELECT /*+ MAX_EXECUTION_TIME(500) */ customer_id, status, SUM(amount) s FROM orders GROUP BY customer_id, status ORDER BY s DESC LIMIT 1"
sql "SET SESSION max_execution_time = 500; SELECT customer_id, status, SUM(amount) s FROM orders GROUP BY customer_id, status ORDER BY s DESC LIMIT 1"

step "MongoDB: per operation, and the cluster-wide default"
js 'db.orders.aggregate([{$unwind: "$items"}, {$group: {_id: {sku: "$items.sku", c: "$customer_id"}, q: {$sum: "$items.qty"}}}, {$count: "groups"}], {maxTimeMS: 500}).toArray()'
js 'db.adminCommand({getClusterParameter: "defaultMaxTimeMS"}).clusterParameters'
