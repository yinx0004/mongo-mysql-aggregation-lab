#!/usr/bin/env bash
# 03 Using indexes for aggregation: covering scans, per-group max, ranges.
. "$(dirname "$0")/../scripts/lib.sh"

note "indexes: orders(customer_id, amount) and orders(created_at) on both sides"
sql_quiet -e "CREATE INDEX idx_cust_amount ON orders (customer_id, amount)" >/dev/null 2>&1
sql_quiet -e "CREATE INDEX idx_created ON orders (created_at)" >/dev/null 2>&1
js_quiet 'db.orders.createIndex({customer_id: 1, amount: 1}); db.orders.createIndex({created_at: 1})' >/dev/null

step "MySQL"
for q in "SELECT customer_id, SUM(amount) FROM orders GROUP BY customer_id" \
         "SELECT customer_id, MAX(amount) FROM orders GROUP BY customer_id" \
         "SELECT COUNT(*) FROM orders WHERE created_at >= '2026-03-01' AND created_at < '2026-04-01'" \
         "SELECT COUNT(*) FROM orders WHERE MONTH(created_at) = 3"; do
  cmd "mysql> EXPLAIN ANALYZE $q"
  sql_quiet -e "EXPLAIN ANALYZE $q\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//'
done

step "MongoDB"
js 'load("/lab/scripts/helpers.js");
const P = {
  "sum per customer":                  [{$group: {_id: "$customer_id", t: {$sum: "$amount"}}}],
  "sum per customer, $sort first":     [{$sort: {customer_id: 1}}, {$group: {_id: "$customer_id", t: {$sum: "$amount"}}}],
  "max: $group with $max":             [{$group: {_id: "$customer_id", m: {$max: "$amount"}}}],
  "max: $sort c:1,a:-1 + $first":      [{$sort: {customer_id: 1, amount: -1}}, {$group: {_id: "$customer_id", m: {$first: "$amount"}}}],
  "max: $sort c:-1,a:-1 + $first":     [{$sort: {customer_id: -1, amount: -1}}, {$group: {_id: "$customer_id", m: {$first: "$amount"}}}],
  "march: range on created_at":        [{$match: {created_at: {$gte: ISODate("2026-03-01"), $lt: ISODate("2026-04-01")}}}, {$count: "n"}],
  "march: $month expression":          [{$match: {$expr: {$eq: [{$month: "$created_at"}, 3]}}}, {$count: "n"}],
};
for (const [k, p] of Object.entries(P)) {
  const ms = timeit(() => db.orders.aggregate(p).toArray());
  const r = explainAgg("orders", p);
  show(k, {plan: r.plan, laterStages: r.laterStages, keysExamined: r.keysExamined, docsExamined: r.docsExamined, usedDisk: r.usedDisk, ms});
}'
