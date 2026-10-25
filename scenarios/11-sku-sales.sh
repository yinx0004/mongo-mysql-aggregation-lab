#!/usr/bin/env bash
# 11 Per-SKU sales for one month: copied columns on order_items vs a JOIN to
# orders, and the MongoDB pipeline over the embedded items array.
. "$(dirname "$0")/../scripts/lib.sh"

js_quiet 'db.orders.createIndex({created_at: 1})' >/dev/null
sql_quiet -e "CREATE INDEX idx_created ON orders (created_at)" >/dev/null 2>&1

step "MySQL: filter on the copied created_at and status, no JOIN"
Q1="SELECT sku, SUM(qty) AS units, SUM(qty * price) AS revenue FROM order_items WHERE created_at >= '2026-03-01' AND created_at < '2026-04-01' AND status <> 'cancelled' GROUP BY sku ORDER BY units DESC, sku LIMIT 3"
sql "$Q1"
cmd "mysql> EXPLAIN ANALYZE ..."
sql_quiet -e "EXPLAIN ANALYZE $Q1\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//'

step "MySQL: a covering index for the report, only possible because the columns were copied"
cmd "mysql> CREATE INDEX idx_report ON order_items (created_at, status, sku, qty, price)"
sql_quiet -e "CREATE INDEX idx_report ON order_items (created_at, status, sku, qty, price)" >/dev/null 2>&1
sql_quiet -e "EXPLAIN ANALYZE $Q1\G" >/dev/null   # warm up
cmd "mysql> EXPLAIN ANALYZE ..."
sql_quiet -e "EXPLAIN ANALYZE $Q1\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//'
sql_quiet -e "DROP INDEX idx_report ON order_items" >/dev/null 2>&1

step "MySQL: the same report if order_items had no copied columns"
Q2="SELECT i.sku, SUM(i.qty) AS units, SUM(i.qty * i.price) AS revenue FROM orders o JOIN order_items i ON i.order_id = o.id WHERE o.created_at >= '2026-03-01' AND o.created_at < '2026-04-01' AND o.status <> 'cancelled' GROUP BY i.sku ORDER BY units DESC, i.sku LIMIT 3"
sql "$Q2"
cmd "mysql> EXPLAIN ANALYZE ..."
sql_quiet -e "EXPLAIN ANALYZE $Q2\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//'

step "MongoDB: filter orders, then \$unwind the items"
js 'db.orders.aggregate([
  {$match: {created_at: {$gte: ISODate("2026-03-01"), $lt: ISODate("2026-04-01")}, status: {$ne: "cancelled"}}},
  {$unwind: "$items"},
  {$group: {_id: "$items.sku", units: {$sum: "$items.qty"}, revenue: {$sum: {$multiply: ["$items.qty", "$items.price"]}}}},
  {$sort: {units: -1, _id: 1}},
  {$limit: 3},
  {$project: {units: 1, revenue: {$round: ["$revenue", 2]}}}
]).toArray()'
js 'load("/lab/scripts/helpers.js");
const p = [
  {$match: {created_at: {$gte: ISODate("2026-03-01"), $lt: ISODate("2026-04-01")}, status: {$ne: "cancelled"}}},
  {$unwind: "$items"},
  {$group: {_id: "$items.sku", units: {$sum: "$items.qty"}, revenue: {$sum: {$multiply: ["$items.qty", "$items.price"]}}}},
  {$sort: {units: -1, _id: 1}}, {$limit: 3}];
const r = explainAgg("orders", p);
show("explain", {plan: r.plan, laterStages: r.laterStages, keysExamined: r.keysExamined, docsExamined: r.docsExamined, ms: timeit(() => db.orders.aggregate(p).toArray())});'
