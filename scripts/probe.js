// Latency probe: point reads by _id on the primary, about every 5 ms, for
// SECS seconds. Prints count, p50, p99 and max latency in ms.
const secs = Number(process.env.SECS || 10);
const d = db.getSiblingDB("shop");
const lat = [];
const end = Date.now() + secs * 1000;
let i = 0;
while (Date.now() < end) {
  const id = ((i++ * 104729) % 2000000) + 1;
  const t = performance.now();
  d.orders.findOne({_id: id});
  lat.push(performance.now() - t);
  sleep(5);
}
lat.sort((a, b) => a - b);
const pct = p => lat[Math.min(lat.length - 1, Math.floor(lat.length * p))].toFixed(1);
print(JSON.stringify({reads: lat.length, p50: pct(0.5), p99: pct(0.99), max: lat[lat.length - 1].toFixed(1)}));
