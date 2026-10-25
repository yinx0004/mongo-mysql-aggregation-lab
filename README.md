# MySQL vs MongoDB aggregation lab

本地实验环境，用同一份数据对比 MySQL 的 GROUP BY / JOIN 和 MongoDB 的聚合管道：优化器做了什么、索引能帮到哪里、内存和落盘、对线上读写的影响、$lookup 和 JOIN、NULL 和数组的语义、超时控制、分片集群上的执行方式，以及物化结果。

## 环境

| 组件 | 版本 | 说明 |
|---|---|---|
| MySQL | 8.4（`mysql:8.4`） | 2 CPU，innodb_buffer_pool_size 512M |
| MongoDB 副本集 rs0 | 8.0.4（`mongo:8.0.4`），mongo1-3 | 每个成员 1 CPU、wiredTigerCacheSizeGB 0.5，mongo1 优先当主节点 |
| client | mongosh + mysql 客户端 | 所有命令都在这里执行 |
| 分片集群（可选） | cfg、shard1、shard2、mongos | compose profile `sharded`，`shop.orders` 按 `customer_id` 哈希分片，40 万订单 |

MongoDB 固定在 8.0.4：后来的 8.0 镜像（比如 8.0.32）在 Linux 内核 ≥ 6.19 上会拒绝启动（[SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)），OrbStack 当前的内核就是这种。

没有开启认证，也没有映射端口到宿主机，只用于本地实验。

## 数据

数据模拟一个电商订单系统，表结构参照大型电商常见的做法：订单主表加订单明细表，明细冗余订单上的字段并保存快照，不用外键。`./lab.sh load` 用同一组公式往两边写入同样的数据（`scripts/load-mysql.sql`、`scripts/load-mongo.js`）：

- 200 万订单：customer_id（分片键）、status（paid、shipped、delivered、cancelled、refunded）、amount、created_at（2026 年内）、region、customer_tier（下单时会员等级的快照）
- 5 万客户
- 订单明细（500 个 SKU）：MySQL 是单独的 `order_items` 表（400 万行），冗余了订单的 customer_id、status、created_at，并保存商品名和单价的快照，不建外键；MongoDB 是订单里的 `items` 数组
- 基础索引：订单上的 `(customer_id, created_at)`，MySQL 的 order_items 上另有 `(created_at)`
- region 字段：每 7 个订单里，MongoDB 有 1 个没有这个字段、1 个是 null，MySQL 两种都是 NULL

## 用法

```bash
./lab.sh up            # 启动 MySQL、副本集和 client
./lab.sh load          # 写入数据（默认 200 万订单，约 1 分钟）
./lab.sh up-sharded    # 可选：启动分片集群并写入 40 万订单
./lab.sh run 01        # 运行场景
./lab.sh status
./lab.sh down          # 停止，保留数据
./lab.sh destroy       # 停止并删除所有数据
```

## 场景

对应的文章分两篇：第一篇讲执行（01–05、11、12），第二篇讲 JOIN、语义差异、分片和物化（06–10）。

| 脚本 | 内容 |
|---|---|
| `01-same-data.sh` | 同样的数据、同样的结果：GROUP BY 和对应的管道 |
| `02-optimizer.sh` | 优化器会自动下推哪些过滤条件：分组键上的 `$match`、`$unwind` 后的 `$match`、改名后的字段、表达式字段；MySQL 派生表条件下推 |
| `03-indexes.sh` | 用索引做聚合：覆盖索引扫描、每组最大值（MySQL 跳跃扫描 vs MongoDB DISTINCT_SCAN）、范围条件 vs 函数条件 |
| `04-memory.sh` | 内存上限和落盘：MongoDB 每个阻塞阶段 100MB；MySQL tmp_table_size 和磁盘临时表 |
| `05-primary-impact.sh` | 重聚合跑在主节点和从节点时，主节点点查延迟的变化 |
| `06-lookup-join.sh` | `$lookup` 的三种策略（IndexedLoopJoin、HashJoin、NestedLoopJoin）和 MySQL 的 JOIN |
| `07-null-missing-arrays.sh` | NULL 和缺失字段、空输入、数组分组、`$unwind` 丢弃空数组 |
| `08-timeouts.sh` | MAX_EXECUTION_TIME / max_execution_time 和 maxTimeMS / defaultMaxTimeMS |
| `09-sharded.sh` | 分片集群上 `$group` 怎样拆成分片部分和合并部分（需要先 `./lab.sh up-sharded`） |
| `10-materialize.sh` | 物化聚合结果：INSERT ... SELECT ... ON DUPLICATE KEY UPDATE 和 `$merge` |
| `11-sku-sales.sh` | 按 SKU 统计某月销量：MySQL 在冗余了 created_at、status 的 order_items 上直接聚合，对比 JOIN orders 的写法；MongoDB 过滤订单后 `$unwind` |
| `12-explain-walkthrough.sh` | 第一篇里逐行解读的原始执行计划：MySQL EXPLAIN ANALYZE，MongoDB 的 SBE 计划（explainVersion 2）和经典引擎计划（explainVersion 1），DISTINCT_SCAN，落盘排序的统计，落盘计数器，缓存换入换出（需要先运行 03） |

`02-optimizer.sh` 会删除 orders 上的二级索引，以便看不借助索引时的计划；`03-indexes.sh` 再把它们建回来。
