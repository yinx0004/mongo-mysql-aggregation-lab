// Loads the lab data set into MongoDB (database shop). The formulas are the
// same as in load-mysql.sql, so both databases hold the same orders.
//   N  number of orders (default 2,000,000)
//   DB target database (default shop)
//   KEEP=1 keeps existing (e.g. pre-sharded) collections instead of dropping them
const N = Number(process.env.N || 2000000);
const C = 50000;
const B = 10000;
const statuses = ["paid", "shipped", "delivered", "cancelled", "refunded"];
const regions = ["apac", "emea", "amer"];
const base = Date.UTC(2026, 0, 1);
const d = db.getSiblingDB(process.env.DB || "shop");

if (!process.env.KEEP) {
  d.orders.drop();
  d.customers.drop();
}

const customers = [];
for (let c = 1; c <= C; c++) {
  customers.push({_id: c, name: "customer-" + c,
    tier: ["gold", "silver", "bronze"][c % 3], country: ["SG", "CN", "US", "DE", "JP"][c % 5]});
}
d.customers.insertMany(customers);

const t0 = Date.now();
// Order document: the order header plus its items as an embedded array. Items
// are always created and read with their order and there are only a few per
// order, so they live inside it. Customers are referenced by customer_id.
//
// {
//   _id: 3002,                     // order id
//   customer_id: 22839,            // reference to customers; shard key in the sharded cluster
//   status: "delivered",           // paid, shipped, delivered, cancelled, refunded
//   amount: 110.74,
//   created_at: ISODate(...),
//   region: "amer",                // optional: missing, null or a value
//   customer_tier: "gold",         // snapshot: tier at the time of the order
//   items: [                       // embedded order items
//     {sku: "sku-62", sku_name: "Product 62", qty: 3, price: 10.14},   // name and price are snapshots
//     ...
//   ]
// }
for (let start = 1; start <= N; start += B) {
  const docs = [];
  for (let n = start; n < Math.min(start + B, N + 1); n++) {
    const customer_id = (n * 7919) % C + 1;
    const doc = {
      _id: n,
      customer_id,
      status: statuses[n % 5],
      amount: ((n * 37) % 100000) / 100,
      created_at: new Date(base + ((n * 13) % 31536000) * 1000),
    };
    // region: missing for n % 7 == 0, null for n % 7 == 1, a value otherwise
    if (n % 7 === 1) doc.region = null;
    else if (n % 7 !== 0) doc.region = regions[n % 3];
    doc.customer_tier = ["gold", "silver", "bronze"][customer_id % 3];
    const items = [];
    for (let j = 0; j <= n % 3; j++) {
      const sku = (n * 31 + j * 17) % 500;
      items.push({sku: "sku-" + sku, sku_name: "Product " + sku, qty: (n + j) % 4 + 1, price: ((n * 7 + j * 11) % 5000) / 100});
    }
    doc.items = items;
    docs.push(doc);
  }
  d.orders.insertMany(docs, {ordered: false, writeConcern: {w: 1}});
}
// Same base index as MySQL's idx_customer_created ("my orders" page).
d.orders.createIndex({customer_id: 1, created_at: 1});
print(`mongo: ${d.orders.estimatedDocumentCount()} orders, ${d.customers.estimatedDocumentCount()} customers in ${Math.round((Date.now() - t0) / 1000)}s`);
