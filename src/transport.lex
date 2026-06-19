# transport.lex — MCP streamable-HTTP JSON-RPC transport.
#
# Speaks the client side of MCP's streamable-HTTP transport: POST a JSON-RPC
# message, read back either an application/json body or an SSE stream
# ("data: {json}" frames), and surface the JSON-RPC `result`/`error` plus any
# `mcp-session-id` the server assigned. Pure HTTP — no MCP server code.
#
# Effects: [net] (http.send). Parsing is pure.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

# A decoded JSON-RPC reply. `result` is None when the call errored (then
# `error` is set). `session_id` carries the server's mcp-session-id header ("" if
# absent), so the caller can persist it for subsequent requests.
type Reply = { result :: Option[jv.Json], error :: Str, session_id :: Str }

fn mk_reply(result :: Option[jv.Json], error :: Str, session_id :: Str) -> Reply {
  { result: result, error: error, session_id: session_id }
}

# Strip an SSE "data:" prefix from a line; None for non-data lines.
fn strip_data(line :: Str) -> Option[Str] {
  match str.strip_prefix(str.trim(line), "data:") {
    Some(rest) => Some(str.trim(rest)),
    None => None,
  }
}

# Extract the JSON-RPC payload from a response body. If the body is an SSE
# stream, return the last non-empty "data:" frame; otherwise return it as-is.
fn extract_rpc_json(body :: Str) -> Str {
  if str.contains(body, "data:") {
    let lines := str.split(body, "\n")
    let last := list.fold(lines, "", fn (acc :: Str, line :: Str) -> Str {
      match strip_data(line) {
        Some(d) => if str.is_empty(d) {
          acc
        } else {
          d
        },
        None => acc,
      }
    })
    if str.is_empty(last) {
      body
    } else {
      last
    }
  } else {
    body
  }
}

fn rpc_error_msg(eobj :: jv.Json) -> Str {
  match jv.get_field(eobj, "message") {
    Some(JStr(m)) => m,
    _ => jv.stringify(eobj),
  }
}

# POST a JSON-RPC message and decode the reply.
fn post(url :: Str, headers :: Map[Str, Str], body :: Str) -> [net] Reply {
  let req := { method: "POST", url: url, headers: headers, body: Some(bytes.from_str(body)), timeout_ms: Some(60000) }
  match http.send(req) {
    Err(_) => mk_reply(None, "transport: MCP server unreachable", ""),
    Ok(resp) => {
      let sid := match map.get(resp.headers, "mcp-session-id") {
        Some(s) => s,
        None => "",
      }
      match bytes.to_str(resp.body) {
        Err(_) => mk_reply(None, "transport: response decode error", sid),
        Ok(text) => {
          let payload := extract_rpc_json(text)
          match jv.parse(payload) {
            Err(_) => mk_reply(None, str.concat("transport: non-JSON-RPC reply: ", payload), sid),
            Ok(j) => match jv.get_field(j, "error") {
              Some(eobj) => mk_reply(None, rpc_error_msg(eobj), sid),
              None => match jv.get_field(j, "result") {
                Some(r) => mk_reply(Some(r), "", sid),
                None => mk_reply(None, "transport: reply had neither result nor error", sid),
              },
            },
          }
        },
      }
    },
  }
}

