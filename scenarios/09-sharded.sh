#!/usr/bin/env bash
# 09 How a sharded cluster splits $group between shards and mongos.
# Needs ./lab.sh up-sharded (shop.orders hashed on customer_id, 400k orders).
. "$(dirname "$0")/../scripts/lib.sh"
MONGO_URI="mongodb://mongos:27017/shop"

step "\$group by status"
js 'const e = db.orders.explain("queryPlanner").aggregate([{$group: {_id: "$status", orders: {$sum: 1}, revenue: {$sum: "$amount"}}}, {$sort: {_id: 1}}]);
print("shards:", Object.keys(e.shards).join(", "), "| mergeType:", e.mergeType);
print("shardsPart:", JSON.stringify(e.splitPipeline.shardsPart));
print("mergerPart:", JSON.stringify(e.splitPipeline.mergerPart.filter(s => !s.$mergeCursors)));'

step "\$group by the shard key, then top 3"
js 'const e = db.orders.explain("queryPlanner").aggregate([{$group: {_id: "$customer_id", t: {$sum: "$amount"}}}, {$sort: {t: -1}}, {$limit: 3}]);
print("mergeType:", e.mergeType, "| shardsPart:", e.splitPipeline.shardsPart.map(s => Object.keys(s)[0]).join(","), "| mergerPart:", e.splitPipeline.mergerPart.map(s => Object.keys(s)[0]).join(","));'

step "With \$merge at the end"
js 'const e = db.orders.explain("queryPlanner").aggregate([{$group: {_id: "$status", t: {$sum: "$amount"}}}, {$merge: {into: "status_totals"}}]);
print("mergeType:", e.mergeType, e.mergeShardId || "");'
