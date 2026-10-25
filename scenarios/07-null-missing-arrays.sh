#!/usr/bin/env bash
# 07 NULL, missing fields, empty input and arrays.
. "$(dirname "$0")/../scripts/lib.sh"

step "Grouping on a nullable column / an optional field"
sql "SELECT region, COUNT(*) AS orders, COUNT(region) AS with_region FROM orders GROUP BY region ORDER BY region"
js 'db.orders.aggregate([{$group: {_id: "$region", orders: {$sum: 1}}}, {$sort: {_id: 1}}]).toArray()'
js 'db.orders.aggregate([{$group: {_id: {$type: "$region"}, orders: {$sum: 1}}}, {$sort: {_id: 1}}]).toArray()'

step "Aggregating nothing"
sql "SELECT SUM(amount) AS s, COUNT(*) AS n FROM orders WHERE id < 0"
js 'db.orders.aggregate([{$match: {_id: {$lt: 0}}}, {$group: {_id: null, s: {$sum: "$amount"}, n: {$sum: 1}}}]).toArray()'
sql "SELECT SUM(NULL) AS s"
js 'db.orders.aggregate([{$match: {_id: {$lte: 3}}}, {$group: {_id: null, s: {$sum: "$discount"}}}]).toArray()'

step "Arrays"
js 'db.orders.aggregate([{$match: {_id: {$lte: 6}}}, {$group: {_id: "$items.sku", n: {$sum: 1}}}, {$limit: 2}]).toArray()'
note "order 2 gets an empty items array"
js 'db.orders.aggregate([{$match: {_id: {$lte: 3}}}, {$set: {items: {$cond: [{$eq: ["$_id", 2]}, [], "$items"]}}},
  {$unwind: "$items"}, {$group: {_id: "$_id", lines: {$sum: 1}}}, {$sort: {_id: 1}}]).toArray()'
js 'db.orders.aggregate([{$match: {_id: {$lte: 3}}}, {$set: {items: {$cond: [{$eq: ["$_id", 2]}, [], "$items"]}}},
  {$unwind: {path: "$items", preserveNullAndEmptyArrays: true}}, {$group: {_id: "$_id", lines: {$sum: 1}}}, {$sort: {_id: 1}}]).toArray()'
