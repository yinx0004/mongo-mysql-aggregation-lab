#!/usr/bin/env bash
# 10 Keeping an aggregate up to date: INSERT ... SELECT ... ON DUPLICATE KEY UPDATE vs $merge.
. "$(dirname "$0")/../scripts/lib.sh"

sql_quiet -e "DROP TABLE IF EXISTS daily_totals; CREATE TABLE daily_totals (day DATE PRIMARY KEY, orders INT, revenue DECIMAL(14,2))" >/dev/null
js_quiet 'db.daily_totals.drop()' >/dev/null

step "MySQL"
sql "INSERT INTO daily_totals SELECT * FROM (SELECT DATE(created_at) AS day, COUNT(*) AS orders, SUM(amount) AS revenue FROM orders WHERE created_at >= '2026-03-01' AND created_at < '2026-03-08' GROUP BY DATE(created_at)) AS n ON DUPLICATE KEY UPDATE orders = n.orders, revenue = n.revenue"
sql "SELECT * FROM daily_totals ORDER BY day LIMIT 3"

step "MongoDB"
js 'db.orders.aggregate([
  {$match: {created_at: {$gte: ISODate("2026-03-01"), $lt: ISODate("2026-03-08")}}},
  {$group: {_id: {$dateTrunc: {date: "$created_at", unit: "day"}}, orders: {$sum: 1}, revenue: {$sum: "$amount"}}},
  {$merge: {into: "daily_totals", whenMatched: "replace", whenNotMatched: "insert"}}
]);
db.daily_totals.find().sort({_id: 1}).limit(3).toArray()'
