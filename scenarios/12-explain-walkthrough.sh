#!/usr/bin/env bash
# 12 The raw execution plans used in the article "how an aggregation runs":
# MySQL EXPLAIN ANALYZE, MongoDB explain in SBE (explainVersion 2) and in the
# classic engine (explainVersion 1, with a "stages" list), DISTINCT_SCAN, the
# statistics of a spilling sort, spill counters, and cache churn.
# Run after 03 (needs the customer_id/amount and created_at indexes).
. "$(dirname "$0")/../scripts/lib.sh"
TRIM='(k, v) => ["serverInfo","serverParameters","command","$clusterTime","operationTime","queryShapeHash","planCacheShapeHash","planCacheKey","signature","planNodeId","isCached","indexVersion","isUnique","isSparse","isPartial","multiKeyPaths","isMultiKey"].includes(k) ? undefined : (v && v.low !== undefined && v.high !== undefined ? Number(v) : v)'

step "MySQL: revenue by status"
cmd "mysql> EXPLAIN ANALYZE SELECT status, COUNT(*), SUM(amount) FROM orders GROUP BY status"
sql_quiet -e "EXPLAIN ANALYZE SELECT status, COUNT(*), SUM(amount) FROM orders GROUP BY status\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //'

step "MongoDB: revenue by status (whole pipeline in SBE)"
js "const e = db.orders.explain(\"executionStats\").aggregate([{\$group: {_id: \"\$status\", orders: {\$sum: 1}, revenue: {\$sum: \"\$amount\"}}}]);
print(JSON.stringify({explainVersion: e.explainVersion, winningPlan: e.queryPlanner.winningPlan, nReturned: e.executionStats.nReturned, totalDocsExamined: e.executionStats.totalDocsExamined}, $TRIM, 2))"

step "MongoDB: SKU report with \$unwind (classic engine after the query layer)"
js "const e = db.orders.explain(\"executionStats\").aggregate([
  {\$match: {created_at: {\$gte: ISODate(\"2026-03-01\"), \$lt: ISODate(\"2026-04-01\")}, status: {\$ne: \"cancelled\"}}},
  {\$unwind: \"\$items\"}, {\$group: {_id: \"\$items.sku\", units: {\$sum: \"\$items.qty\"}}}, {\$sort: {units: -1}}, {\$limit: 3}]);
print(JSON.stringify({explainVersion: e.explainVersion, stages: e.stages.map(s => { const k = Object.keys(s)[0];
  if (k === \"\$cursor\") return {\$cursor: {winningPlan: s.\$cursor.queryPlanner.winningPlan, totalKeysExamined: s.\$cursor.executionStats.totalKeysExamined, totalDocsExamined: s.\$cursor.executionStats.totalDocsExamined}, nReturned: s.nReturned, executionTimeMillisEstimate: s.executionTimeMillisEstimate};
  return {[k]: s[k], nReturned: s.nReturned, executionTimeMillisEstimate: s.executionTimeMillisEstimate}; })}, $TRIM, 2))"

step "MongoDB: per-customer max with DISTINCT_SCAN"
js "const e = db.orders.explain(\"executionStats\").aggregate([{\$sort: {customer_id: -1, amount: -1}}, {\$group: {_id: \"\$customer_id\", m: {\$first: \"\$amount\"}}}]);
const c = e.stages[0].\$cursor;
print(JSON.stringify({winningPlan: c.queryPlanner.winningPlan, totalKeysExamined: c.executionStats.totalKeysExamined, totalDocsExamined: c.executionStats.totalDocsExamined, laterStages: e.stages.slice(1).map(s => Object.keys(s)[0])}, $TRIM, 2))"

step "MongoDB: the same with the sort direction the index can't give (blocking sort, spills)"
js "const e = db.orders.explain(\"executionStats\").aggregate([{\$sort: {customer_id: 1, amount: -1}}, {\$group: {_id: \"\$customer_id\", m: {\$first: \"\$amount\"}}}]);
function walk(n, d = 0) { if (!n) return; const pick = {};
  for (const k of [\"nReturned\", \"usedDisk\", \"spills\", \"spilledDataStorageSize\", \"totalDataSizeSorted\", \"memLimit\"]) if (k in n) pick[k] = Number(n[k]);
  print(\" \".repeat(d * 2) + n.stage + \" \" + JSON.stringify(pick)); walk(n.inputStage, d + 1); }
walk(e.executionStats.executionStages)"

step "MongoDB: memory limits and spill counters"
js "const r = db.adminCommand({getParameter: 1, internalDocumentSourceGroupMaxMemoryBytes: 1, internalQueryMaxBlockingSortMemoryUsageBytes: 1, allowDiskUseByDefault: 1});
print(JSON.stringify({groupMaxMemoryBytes: Number(r.internalDocumentSourceGroupMaxMemoryBytes), sortMaxMemoryBytes: Number(r.internalQueryMaxBlockingSortMemoryUsageBytes), allowDiskUseByDefault: r.allowDiskUseByDefault}));
const m = db.serverStatus().metrics.query; print(JSON.stringify({group: m.group, sort: m.sort}, $TRIM))"

step "MongoDB: cache churn from a heavy aggregation on the primary"
MONGO_URI="mongodb://$(primary_node):27017/shop?directConnection=true" js 'const c = () => { const w = db.serverStatus().wiredTiger.cache; return {read: Number(w["pages read into cache"]), evicted: Number(w["unmodified pages evicted"]) + Number(w["modified pages evicted"]), bytes: Number(w["bytes currently in the cache"]), max: Number(w["maximum bytes configured"])}; };
const s = db.orders.stats({scale: 1048576}); print("orders data MB:", Math.round(s.size), "| on disk MB:", Math.round(s.storageSize), "| WiredTiger cache MB:", Math.round(c().max / 1048576));
const a = c(); const t = Date.now();
db.orders.aggregate([{$unwind: "$items"}, {$sort: {"items.price": -1, amount: 1}}, {$group: {_id: "$items.sku", top: {$push: "$_id"}}}, {$count: "n"}]).toArray();
const b = c(); print(JSON.stringify({aggSeconds: (Date.now() - t) / 1000, pagesReadIntoCache: b.read - a.read, pagesEvicted: b.evicted - a.evicted}))'

step "MySQL: temporary table settings"
sql "SELECT @@tmp_table_size, @@temptable_max_ram, @@temptable_max_mmap, @@internal_tmp_mem_storage_engine"
