#!/usr/bin/env bash
# 02 What the optimizer moves for you, and what it doesn't. Run before 03
# (no secondary indexes) to see the plans without index help.
. "$(dirname "$0")/../scripts/lib.sh"

step "MySQL: a filter on the group key is pushed into the derived table"
sql_quiet -e "DROP INDEX idx_cust_amount ON orders" >/dev/null 2>&1
sql_quiet -e "DROP INDEX idx_created ON orders" >/dev/null 2>&1
sql "EXPLAIN FORMAT=TREE SELECT * FROM (SELECT customer_id, SUM(amount) AS t FROM orders GROUP BY customer_id) d WHERE customer_id < 100"
sql "EXPLAIN FORMAT=TREE SELECT * FROM (SELECT customer_id, SUM(amount) AS t FROM orders GROUP BY customer_id) d WHERE t > 21000"

step "MongoDB: which \$match stages the pipeline optimizer moves"
js_quiet 'try { db.orders.dropIndex("customer_id_1_amount_1") } catch (e) {}; try { db.orders.dropIndex("created_at_1") } catch (e) {}' >/dev/null
js 'load("/lab/scripts/helpers.js");
const P = {
  "$match on group key after $group":  [{$group: {_id: "$customer_id", t: {$sum: "$amount"}}}, {$match: {_id: {$lt: 100}}}],
  "$match on computed total":          [{$group: {_id: "$customer_id", t: {$sum: "$amount"}}}, {$match: {t: {$gt: 21000}}}],
  "$match on top-level field after $unwind": [{$unwind: "$items"}, {$match: {status: "paid"}}, {$count: "n"}],
  "$match on array field after $unwind":     [{$unwind: "$items"}, {$match: {"items.sku": "sku-1"}}, {$count: "n"}],
  "$match on renamed field":           [{$project: {cust: "$customer_id", amount: 1}}, {$match: {cust: 5}}, {$count: "n"}],
  "$match on $addFields expression":   [{$addFields: {m: {$month: "$created_at"}}}, {$match: {m: 3}}, {$count: "n"}],
};
for (const [k, p] of Object.entries(P)) { const r = explainAgg("orders", p); show(k, {filter: r.filter, plan: r.plan, laterStages: r.laterStages}); }'

step "MongoDB: adding the array pre-filter by hand"
js 'load("/lab/scripts/helpers.js");
const late  = [{$unwind: "$items"}, {$match: {"items.sku": "sku-1"}}, {$count: "n"}];
const early = [{$match: {"items.sku": "sku-1"}}, {$unwind: "$items"}, {$match: {"items.sku": "sku-1"}}, {$count: "n"}];
show("$match only after $unwind", {result: db.orders.aggregate(late).toArray()[0].n, ms: timeit(() => db.orders.aggregate(late).toArray())});
show("$match before and after", {result: db.orders.aggregate(early).toArray()[0].n, ms: timeit(() => db.orders.aggregate(early).toArray())});'
