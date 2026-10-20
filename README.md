# devbox-mcp, with delete compiled out

The [Microsoft Dev Box MCP server](https://github.com/microsoft/devbox-mcp-server)
(`@microsoft/devbox-mcp`), patched with a Nix overlay so that **an agent cannot delete
anything through it**. The delete code paths are removed from the binary, not hidden by
a prompt or a config flag.

This applies the pattern from Geoffrey Huntley's
[*you can literally just fix everything with a Nix overlay*](https://ghuntley.com/nix)
([ghuntley/nix-demo](https://github.com/ghuntley/nix-demo) removes `git push --force` the
same way) to an MCP server.

## Why not just configure it?

| Approach | Problem |
|---|---|
| Prompt: "never delete a Dev Box" | The model can ignore it. |
| Client-side tool approval | It's a habit. One "Allow always" click undoes it. |
| `--disallowed-tools devbox_resource` (upstream flag) | Applies to the whole tool, so you also lose list, get and create. It's also opt-in config, and an agent that can edit `mcp.json` can remove it. |
| Azure RBAC without delete permission | The right server-side control, if you own the role assignments. It doesn't help on machines where your identity *can* delete. |
| **Patch the server** | The tool schema has no `delete`, and the process can't send one. Nothing to bypass. |

Use RBAC too if you can. This patch is the client-side half.

## What upstream exposes (0.0.3-alpha.4)

| Path | Upstream | Patched |
|---|---|---|
| `devbox_resource` `operation: "delete"` → `DELETE /projects/{p}/users/{u}/devboxes/{name}` | yes | **gone** |
| `workplanner_delete_task` → `POST /api/taskprocessor/delete-task` | yes (corp + `DEVBOX_MCP_WORKPLANNER_ENABLED`) | **gone** |
| SDK `environments.deleteEnvironment` (no tool uses it yet) | reachable code | **refused** |

Everything else is unchanged: `devbox_resource` read/create, `devbox_action`
start/stop/restart/repair, schedules, customizations, pools and projects.

## How: three layers in one derivation

Upstream ships a single minified bundle (`dist/devbox-mcp-server.mjs`, 880 KB on one line),
so a unified `.patch` doesn't work well. Each patch site in
[`third_party/devbox-mcp/default.nix`](third_party/devbox-mcp/default.nix) is a
`substituteInPlace --replace-fail`. **If upstream changes the code around a patch site,
the build fails.** It never silently ships an unpatched server. After patching, the build
also checks that the removed shapes are gone.

| Layer | Where | Effect |
|---|---|---|
| **001 tool surface** | zod schema, operation dispatch, scope validation, `deleteDevBox` handler; tool registries + base-class `register()` (the one place every tool calls `server.tool()`) | `devbox_resource.operation` enum is `["read","create"]`, so a `delete` call fails MCP validation (`-32602`). No tool matching `/delete/i` can register. |
| **002 Azure SDK** | `ServiceClient.sendOperationRequest`, `NodeHttpClient.sendRequest` | Any operation spec with `httpMethod: "DELETE"` throws before it is sent. This covers future SDK delete operations too. |
| **003 process guard** | [`delete-guard.mjs`](third_party/devbox-mcp/delete-guard.mjs), injected as the bundle's **first** `import` | Wraps `fetch`, `http.request/get` and `https.request/get`. No `DELETE` request and no request to a `/delete…` path can leave the process. |

Layer 3 does the job of nix-demo's `set_ref_status_for_push` patch: it is a single choke
point that catches whatever the more specific patches miss.

```
third_party/devbox-mcp/        npm tarball (pinned by sha512) + lockfile + substitutions + guard
nix/overlay.nix                pkgs.devbox-mcp = patched build   ← single source of truth
nix/tests/probe.mjs            MCP-over-stdio + guard behavioural test (offline)
nix/tests/no-delete.nix        sandboxed check + negative control against stock upstream
nix/tests/no-delete-vm.nix     NixOS VM test (runNixOSTest)
nix/docker.nix                 OCI image of the patched server
flake.nix                      overlays / packages / apps / checks / devShells
```

## Tests

```console
nix build .#checks.x86_64-linux.no-delete -L      # seconds, runs in the build sandbox
nix build .#checks.x86_64-linux.no-delete-vm -L   # boots a NixOS VM (needs kvm + nixos-test features)
nix flake check
```

`probe.mjs` starts the real server binary and talks MCP to it:

- `tools/list` contains no tool matching `/delete/i`, and `devbox_resource.operation.enum`
  is exactly `["read","create"]`.
- Calling `devbox_resource` with `operation: "delete"` is refused, and so is calling
  `workplanner_delete_task`.
- It loads the guard and sends nine delete attempts (`fetch`, `Request`, `http`, `https`,
  `http.get`, lowercase `delete`, and `POST /delete-task`) at a local HTTP server. All
  nine are refused in-process, and the server records **zero** of them. GET and POST
  still get through.
- **Negative control:** the same probe runs against `pkgs.devbox-mcp-unpatched` and must
  *fail*. This shows the probe actually detects an exposed delete.

## Use it

As the MCP server for an agent running where Nix is available:

```jsonc
// .vscode/mcp.json, or any MCP client config
{
  "servers": {
    "DevBox": { "command": "nix", "args": ["run", "github:<you>/devbox-mcp"] }
  }
}
```

From another flake, add this repo as an input and apply `overlays.default`. Every
`pkgs.devbox-mcp` in your dev shells, NixOS sandboxes and images is then the patched build.

Authentication on Linux uses `DefaultAzureCredential`. WAM is Windows-only, so run
`az login` (Azure CLI) in the environment the server runs in.

## Limits

- This removes the **MCP server's** delete capabilities. It does not limit what your Azure
  identity can do through other tools. If the agent also has `az`, a shell or a browser,
  restrict those separately (or use RBAC).
- `task_resource` runs customization tasks *on* a Dev Box. Those commands run on the
  remote machine, not in this process, so this patch doesn't filter them.
- The guard covers `fetch`, `http` and `https`. The bundle doesn't use `http2`, and
  hand-writing raw HTTP over `net`/`tls` sockets isn't covered. (Layer 002 still blocks
  the SDK paths.)

## Bumping upstream

1. Change `version` and the `sha512` in `third_party/devbox-mcp/default.nix`
   (`npm view @microsoft/devbox-mcp@<v> dist.integrity --registry https://registry.npmjs.org`).
2. Regenerate `package-lock.json` from the edited `package.json` (see the comment in
   `default.nix`), then update `npmDepsHash`.
3. Build. If a `--replace-fail` breaks, find the new shape in the bundle and update that
   one substitution. Then run `nix flake check`.
