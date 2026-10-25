#!/usr/bin/env bash
# 01 Same data, same answer: a GROUP BY and the equivalent pipeline.
. "$(dirname "$0")/../scripts/lib.sh"

step "Revenue by status"
sql "SELECT status, COUNT(*) AS orders, SUM(amount) AS revenue FROM orders GROUP BY status ORDER BY status"
js 'db.orders.aggregate([
  {$group: {_id: "$status", orders: {$sum: 1}, revenue: {$sum: "$amount"}}},
  {$sort: {_id: 1}},
  {$project: {orders: 1, revenue: {$round: ["$revenue", 2]}}}
]).toArray()'

step "Items per order: a separate table in MySQL, an array in MongoDB"
sql "SELECT COUNT(*) AS item_rows, SUM(qty) AS units FROM order_items"
js 'db.orders.aggregate([
  {$unwind: "$items"},
  {$group: {_id: null, item_rows: {$sum: 1}, units: {$sum: "$items.qty"}}}
]).toArray()'
