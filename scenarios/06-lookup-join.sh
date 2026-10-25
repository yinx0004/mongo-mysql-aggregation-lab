#!/usr/bin/env bash
# 06 $lookup strategies vs MySQL joins.
. "$(dirname "$0")/../scripts/lib.sh"

sql_quiet -e "DROP TABLE IF EXISTS tiers, vip;
  CREATE TABLE tiers (name VARCHAR(8), discount DECIMAL(3,2));
  INSERT INTO tiers VALUES ('gold', 0.10), ('silver', 0.05), ('bronze', 0.00);
  CREATE TABLE vip (name VARCHAR(32));
  INSERT INTO vip SELECT CONCAT('customer-', n * 250) FROM nums WHERE n BETWEEN 1 AND 200;" >/dev/null
js_quiet 'db.tiers.drop(); db.tiers.insertMany([{name: "gold", discount: 0.10}, {name: "silver", discount: 0.05}, {name: "bronze", discount: 0}]);
  db.vip.drop(); db.vip.insertMany(Array.from({length: 200}, (_, i) => ({name: "customer-" + (i + 1) * 250})));
  try { db.customers.dropIndex("name_1") } catch (e) {}' >/dev/null

step "MySQL"
for q in "SELECT COUNT(*) FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.created_at >= '2026-03-01' AND o.created_at < '2026-03-02'" \
         "SELECT c.tier, COUNT(*) FROM customers c JOIN tiers t ON t.name = c.tier GROUP BY c.tier" \
         "SELECT COUNT(*) FROM vip v JOIN customers c ON c.name = v.name"; do
  cmd "mysql> EXPLAIN ANALYZE $q"
  sql_quiet -e "EXPLAIN ANALYZE $q\G" | grep -v '^\*' | sed -E 's/^EXPLAIN: //; s/  \(cost[^)]*\)//' | head -5
done

step "MongoDB"
js 'load("/lab/scripts/helpers.js");
function lk(coll, p) { const e = db.getCollection(coll).explain("executionStats").aggregate(p);
  return {strategy: findAll(e, "strategy").join(","), ms: timeit(() => db.getCollection(coll).aggregate(p).toArray())}; }
const day = {$match: {created_at: {$gte: ISODate("2026-03-01"), $lt: ISODate("2026-03-02")}}};
const vip = [{$lookup: {from: "customers", localField: "name", foreignField: "name", as: "c"}}, {$count: "n"}];
show("orders -> customers._id", lk("orders", [day, {$lookup: {from: "customers", localField: "customer_id", foreignField: "_id", as: "c"}}, {$count: "n"}]));
show("customers -> tiers (3 docs)", lk("customers", [{$lookup: {from: "tiers", localField: "tier", foreignField: "name", as: "t"}}, {$group: {_id: "$tier", n: {$sum: 1}}}]));
show("vip -> customers.name, no index", lk("vip", vip));
db.customers.createIndex({name: 1});
show("vip -> customers.name, index", lk("vip", vip));
db.customers.dropIndex("name_1");
const p = db.adminCommand({getParameter: 1, internalQueryCollectionMaxNoOfDocumentsToChooseHashJoin: 1, internalQueryCollectionMaxDataSizeBytesToChooseHashJoin: 1});
show("hash join limits", {maxDocs: Number(p.internalQueryCollectionMaxNoOfDocumentsToChooseHashJoin), maxBytes: Number(p.internalQueryCollectionMaxDataSizeBytesToChooseHashJoin)});'
