// Helpers loaded into mongosh by the scenarios: load("/lab/scripts/helpers.js")

// "GROUP <- IXSCAN(customer_id_1)" style summary of a plan tree.
function planStages(node) {
  const out = [];
  (function walk(n) {
    if (!n) return;
    out.push(n.stage + (n.indexName ? `(${n.indexName})` : "") + (n.strategy ? `[${n.strategy}]` : ""));
    if (n.inputStage) walk(n.inputStage);
    (n.inputStages || []).forEach(walk);
    if (n.outerStage) walk(n.outerStage);
    if (n.innerStage) walk(n.innerStage);
  })(node);
  return out.join(" <- ");
}

// Find every value of a key anywhere in an object (e.g. usedDisk, spills).
function findAll(obj, key, acc = []) {
  if (obj && typeof obj === "object") {
    for (const [k, v] of Object.entries(obj)) {
      if (k === key) acc.push(v);
      findAll(v, key, acc);
    }
  }
  return acc;
}

// Compact explain("executionStats") summary for an aggregation.
function explainAgg(coll, pipeline, opts = {}) {
  const e = db.getCollection(coll).explain("executionStats").aggregate(pipeline, opts);
  const r = {};
  let qp, es;
  if (e.stages) {             // part of the pipeline runs after the query layer
    qp = e.stages[0].$cursor.queryPlanner;
    es = e.stages[0].$cursor.executionStats;
    r.laterStages = e.stages.slice(1).map(s => Object.keys(s)[0]);
  } else {                    // whole pipeline pushed into the query engine
    qp = e.queryPlanner;
    es = e.executionStats;
  }
  r.filter = JSON.stringify(qp.parsedQuery);
  r.plan = planStages(qp.winningPlan.queryPlan || qp.winningPlan);
  r.docsExamined = es.totalDocsExamined;
  r.keysExamined = es.totalKeysExamined;
  const disk = findAll(e, "usedDisk");
  if (disk.length) r.usedDisk = disk.some(Boolean);
  const spills = findAll(e, "spills").filter(x => typeof x === "number");
  if (spills.length) r.spills = spills.reduce((a, b) => a + b, 0);
  return r;
}

// Median wall time of fn() over n runs, in ms.
function timeit(fn, n = 3) {
  const t = [];
  for (let i = 0; i < n; i++) { const s = Date.now(); fn(); t.push(Date.now() - s); }
  t.sort((a, b) => a - b);
  return t[Math.floor(n / 2)];
}

function show(label, obj) { print(label.padEnd(28) + " " + JSON.stringify(obj)); }
