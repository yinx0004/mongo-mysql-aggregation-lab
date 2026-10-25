#!/usr/bin/env bash
# 04 Memory limits and spilling to disk.
. "$(dirname "$0")/../scripts/lib.sh"

step "MongoDB: 100 MB per blocking stage, then spill (allowDiskUse is on by default since 6.0)"
js 'load("/lab/scripts/helpers.js");
print("allowDiskUseByDefault:", db.adminCommand({getParameter: 1, allowDiskUseByDefault: 1}).allowDiskUseByDefault);
const P = {
  "$group with $push": [{$group: {_id: "$customer_id", orders: {$push: {a: "$amount", c: "$created_at", s: "$status"}}}}, {$count: "n"}],
  "$sort 2M docs by amount": [{$sort: {amount: -1}}, {$skip: 1999990}, {$project: {amount: 1}}],
};
for (const [k, p] of Object.entries(P)) {
  try { db.orders.aggregate(p, {allowDiskUse: false}).toArray(); print(k + ", allowDiskUse: false -> ok"); }
  catch (e) { print(k + ", allowDiskUse: false -> " + e.codeName + ": " + e.message.replace(/^.*caused by :: /, "")); }
  const ms = timeit(() => db.orders.aggregate(p).toArray(), 1);
  const r = explainAgg("orders", p);
  show(k + ", default", {plan: r.plan, usedDisk: r.usedDisk, spills: r.spills, ms});
}'

step "MySQL: internal temporary tables move to disk above tmp_table_size"
Q="SELECT customer_id, status, COUNT(*) c, SUM(amount) s FROM orders GROUP BY customer_id, status ORDER BY s DESC LIMIT 3"
for size in 67108864 1048576; do
  cmd "mysql> SET SESSION tmp_table_size = $size; FLUSH STATUS; EXPLAIN ANALYZE $Q; SHOW SESSION STATUS LIKE 'Created_tmp%disk%';"
  sql_quiet -e "SET SESSION tmp_table_size = $size; FLUSH STATUS; EXPLAIN ANALYZE $Q\G SHOW SESSION STATUS LIKE 'Created_tmp_disk_tables';" \
    | grep -E "EXPLAIN:|Aggregate using|Created_tmp" | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//'
done
