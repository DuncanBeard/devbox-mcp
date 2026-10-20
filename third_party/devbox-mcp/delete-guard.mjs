// delete-guard.mjs: process-wide backstop, injected as the FIRST import of the
// devbox-mcp bundle by third_party/devbox-mcp/default.nix.
//
// ES module imports are evaluated in order before the importing module's body,
// so this runs before the MCP server, the Azure SDK, MSAL or App Insights load.
// Every outbound HTTP request in the server goes through one of:
//   - globalThis.fetch            (WorkPlanner tools)
//   - node:http / node:https       (Azure core-rest-pipeline, node-fetch, MSAL)
// We wrap all three so that no code path, current or future, can send a
// DELETE or hit a `/delete...` endpoint (e.g. POST /api/taskprocessor/delete-task).
//
// Wrappers stay writable on purpose: App Insights' diagnostic-channel monkey-patches
// http.request after us; it wraps our function, so the guard still runs underneath.

import http from "node:http";
import https from "node:https";

export const MESSAGE = "delete is disabled and not allowed";
const DELETE_PATH = /(^|\/)delete(?:[-_/?#.]|$)/i;

export class DeleteDisabledError extends Error {
  constructor(detail) {
    super(`devbox-mcp: ${MESSAGE} (${detail})`);
    this.name = "DeleteDisabledError";
    this.code = "EDELETEDISABLED";
  }
}

export function isForbidden(method, path) {
  return String(method || "GET").toUpperCase() === "DELETE" || DELETE_PATH.test(String(path || ""));
}

function pathOf(u) {
  try { return new URL(String(u)).pathname; } catch { return String(u || ""); }
}

function check(method, path) {
  if (isForbidden(method, path)) throw new DeleteDisabledError(`${String(method || "GET").toUpperCase()} ${path}`);
}

// http.request(url[, options][, cb]) | http.request(options[, cb])
function guardNodeRequest(mod, fnName) {
  const original = mod[fnName];
  mod[fnName] = function guarded(a, b, ...rest) {
    const urlFirst = typeof a === "string" || a instanceof URL;
    const opts = urlFirst ? (b && typeof b === "object" ? b : {}) : (a || {});
    const path = opts.path ?? (urlFirst ? pathOf(a) : "");
    check(opts.method, path);
    return original.call(this, a, b, ...rest);
  };
}

for (const mod of [http, https]) {
  guardNodeRequest(mod, "request");
  guardNodeRequest(mod, "get");
}

if (typeof globalThis.fetch === "function") {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = function guardedFetch(input, init) {
    const isRequest = typeof Request !== "undefined" && input instanceof Request;
    const method = init?.method ?? (isRequest ? input.method : "GET");
    const url = isRequest ? input.url : input;
    try {
      check(method, pathOf(url));
    } catch (err) {
      return Promise.reject(err);
    }
    return originalFetch.call(this, input, init);
  };
}

globalThis.__devboxMcpDeleteGuard = { MESSAGE, isForbidden };
