// Behavioural test for the patched devbox-mcp. Runs offline.
//
//   node probe.mjs <path-to-devbox-mcp-server-binary> <path-to-delete-guard.mjs | ->
//
// 1. Talks MCP (JSON-RPC over stdio) to the real server binary:
//    - tools/list contains no tool matching /delete/i
//    - devbox_resource.operation enum is exactly ["read", "create"]
//    - tools/call devbox_resource {operation:"delete"} is refused
//    - tools/call workplanner_delete_task is refused (tool does not exist)
// 2. Loads the injected guard and proves, against a local HTTP server that
//    records every request, that DELETE / `/delete...` traffic never leaves the
//    process via fetch, http.request or https.request, while normal traffic works.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import assert from "node:assert/strict";

const [serverBin, guardPath] = process.argv.slice(2);
assert.ok(serverBin && guardPath, "usage: probe.mjs <server-bin> <delete-guard.mjs>");

const ok = (m) => console.log(`ok: ${m}`);

// "-" as the guard path runs only section 1 (used for the negative control).
const skipGuard = guardPath === "-";

// ---------- 1. MCP surface ----------
async function mcpSession() {
  const child = spawn(serverBin, [], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, DEVBOX_MCP_WORKPLANNER_ENABLED: "true", DEVBOX_MCP_PREVIEW_MODE: "true" },
  });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  let buf = "";
  const pending = new Map();
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id != null && pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      }
    }
  });
  let nextId = 1;
  const rpc = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      const t = setTimeout(() => reject(new Error(`timeout on ${method}\nstderr:\n${stderr}`)), 60_000);
      pending.set(id, (m) => { clearTimeout(t); resolve(m); });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  const notify = (method, params = {}) =>
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  return { child, rpc, notify, stderr: () => stderr };
}

const s = await mcpSession();
const init = await s.rpc("initialize", {
  protocolVersion: "2025-03-26",
  capabilities: {},
  clientInfo: { name: "no-delete-probe", version: "1" },
});
assert.ok(init.result, `initialize failed: ${JSON.stringify(init)}`);
s.notify("notifications/initialized");

const list = await s.rpc("tools/list");
const tools = list.result.tools;
const names = tools.map((t) => t.name);
console.log(`tools: ${names.join(", ")}`);
assert.ok(names.includes("devbox_resource"), "devbox_resource should still be registered");
assert.deepEqual(names.filter((n) => /delete/i.test(n)), [], "a delete tool is exposed");
ok("no tool name matches /delete/i");

const devboxResource = tools.find((t) => t.name === "devbox_resource");
assert.deepEqual(devboxResource.inputSchema.properties.operation.enum, ["read", "create"]);
ok('devbox_resource.operation enum is ["read","create"]');

const isRefused = (r) => r.error || r.result?.isError;
const del = await s.rpc("tools/call", {
  name: "devbox_resource",
  arguments: {
    scope: "/projects/Proj/users/me/devboxes/Box",
    operation: "delete",
    devCenterName: "dc",
    locationInUri: "westus3",
  },
});
assert.ok(isRefused(del), `delete call was not refused: ${JSON.stringify(del)}`);
ok(`devbox_resource operation=delete refused: ${JSON.stringify(del.error ?? del.result.content?.[0]?.text).slice(0, 160)}`);

const wp = await s.rpc("tools/call", {
  name: "workplanner_delete_task",
  arguments: { sessionId: "s", taskId: "t" },
});
assert.ok(isRefused(wp), `workplanner_delete_task was not refused: ${JSON.stringify(wp)}`);
ok("workplanner_delete_task refused (not registered)");
s.child.kill();
if (skipGuard) { console.log("PASS"); process.exit(0); }

// ---------- 2. process-wide guard ----------
const seen = [];
const httpServer = createServer((req, res) => {
  seen.push(`${req.method} ${req.url}`);
  res.end("ok");
});
await new Promise((r) => httpServer.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${httpServer.address().port}`;

const guard = await import(guardPath);
const http = (await import("node:http")).default;
const https = (await import("node:https")).default;

const nodeReq = (mod, ...args) =>
  new Promise((resolve, reject) => {
    const req = mod.request(...args, (res) => { res.resume(); res.on("end", resolve); });
    req.on("error", reject);
    req.end();
  });

// Allowed traffic still flows.
assert.equal((await fetch(`${base}/projects`)).status, 200);
assert.equal((await fetch(`${base}/projects`, { method: "POST", body: "{}" })).status, 200);
await nodeReq(http, `${base}/projects/p/devboxes/b:start`, { method: "POST" });
ok("GET/POST still allowed through fetch and http.request");

// Forbidden traffic never leaves the process.
const forbidden = [
  () => fetch(`${base}/projects/p/users/me/devboxes/b`, { method: "DELETE" }),
  () => fetch(`${base}/projects/p/users/me/devboxes/b`, { method: "delete" }),
  () => fetch(new Request(`${base}/x`, { method: "DELETE" })),
  () => fetch(`${base}/api/taskprocessor/delete-task`, { method: "POST", body: "{}" }),
  () => nodeReq(http, `${base}/projects/p/users/me/devboxes/b`, { method: "DELETE" }),
  () => nodeReq(http, { host: "127.0.0.1", port: httpServer.address().port, path: "/x", method: "DELETE" }),
  () => nodeReq(http, `${base}/api/taskprocessor/delete-task`, { method: "POST" }),
  () => nodeReq(https, { host: "127.0.0.1", port: 1, path: "/x", method: "DELETE" }),
  () => new Promise((resolve, reject) => { try { http.get(`${base}/delete`).on("error", reject); } catch (e) { reject(e); } }),
];
for (const [i, attempt] of forbidden.entries()) {
  await assert.rejects(
    async () => attempt(),
    (e) => e.code === "EDELETEDISABLED" && e.message.includes(guard.MESSAGE),
    `forbidden attempt #${i} was not blocked`,
  );
}
ok(`${forbidden.length} DELETE / delete-endpoint attempts refused in-process`);

assert.deepEqual(seen.filter((r) => /^DELETE |\/delete/i.test(r)), [], `server saw: ${seen}`);
ok(`local server never received a delete request (saw: ${seen.join(" | ")})`);
httpServer.close();
console.log("PASS");
process.exit(0);
