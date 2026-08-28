# lex-mcp-client

An **MCP client for lex** — the missing counterpart to `lex-mcp` (which is an MCP
*server*). It connects to an external MCP server over **streamable HTTP**,
performs the handshake, lists the server's tools, and **adapts each remote tool
into a native `lex-llm` `Tool`**, so a lex agent (truck / tms / depot) can call
an MCP server the same way the Python ADK agent does.

Built so a **lex** depot/truck agent can consume the **elu depot MCP**
(`ext-elu-depot`) — closing the loop where lex and Python agents share one MCP
integration surface.

## Modules (`src/`)

| Module | Responsibility |
|--------|----------------|
| `transport.lex` | streamable-HTTP JSON-RPC: POST a message, decode an `application/json` body *or* an SSE `data:` stream, surface `result`/`error` + the `mcp-session-id`. Effect: `[net]`. |
| `schema_bridge.lex` | MCP `inputSchema` (JSON Schema) → `lex-schema` `ModelSchema`. Scalars + arrays of scalars; nested objects fall back to string (v1). Pure. |
| `client.lex` | `connect` (initialize + initialized), `list_tools`, `call_tool`, and **`as_lex_tools`** — the bridge that wraps each remote tool as a `lex-llm` Tool whose `execute` calls it over MCP. Plus `connect_tools` (one-call) and `bearer`. |

## Use in an agent's `make_tools`

```lex
import "lex-mcp-client/src/client" as mcpc

# append the elu depot MCP's tools to the agent's own tools
match mcpc.connect_tools(elu_mcp_url, mcpc.bearer(token)) {
  Ok(remote) => list.concat(base_tools, remote),
  Err(_)     => base_tools,
}
```

See `examples/use_elu_mcp.lex` for a complete, compiling example.

## Transport notes

- Point the URL at the MCP endpoint, e.g. `http://ext-elu-depot:8097/mcp`
  (run `ext-elu-depot` with `MCP_TRANSPORT=http`).
- The client captures the server's `mcp-session-id` on `initialize` and echoes it
  on every subsequent request (streamable-HTTP session semantics).
- SSE responses are handled by extracting the last `data:` frame; plain JSON
  responses are parsed directly.

## Limitations (v1)

- **Schema bridge**: nested-object properties degrade to a string field (TODO:
  recurse into `KObject`); enums not yet mapped.
- **No server→client channel**: the GET SSE stream (server-initiated
  notifications/progress) is not opened; request/response tools work fully.
- **Transport**: streamable HTTP only (no stdio client yet — avoids long-lived
  bidirectional pipes under the `proc` effect).

## Build

```bash
lex pkg install
lex check src/client.lex
lex fmt src examples
```
Dependencies are git (workspace policy) — `lex-schema`, `lex-llm`, `lex-mcp`.

## License

Copyright (c) 2026 lex-mcp-client contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.
