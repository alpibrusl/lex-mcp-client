# client.lex — MCP client for lex agents.
#
# Connects to an MCP server over streamable HTTP, performs the initialize
# handshake, lists the server's tools, and ADAPTS each one into a native
# lex-llm `Tool` whose `execute` calls the remote tool over MCP. This is what
# lets a lex agent (truck / tms / depot) consume an external MCP server — e.g.
# the elu depot MCP — the same way the Python ADK agent does.
#
# Transport: streamable HTTP (see ./transport). The server URL should be the MCP
# endpoint, e.g. http://ext-elu-depot:8097/mcp.
#
# Effects: [net] for connect/list/call. `as_lex_tools` is pure (builds closures);
# each tool's execute is [net, io, proc] to satisfy the lex-llm Tool contract.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "lex-mcp/src/protocol" as proto

import "./transport" as tr

import "./schema_bridge" as bridge

# A live MCP session. `auth` are extra headers (e.g. bearer) merged into every
# request; `session_id` is the server-assigned mcp-session-id ("" if none).
type Session = { url :: Str, auth :: List[(Str, Str)], session_id :: Str }

type ConnectResult = Connected(Session) | ConnectFailed(Str)

fn rpc_request(id :: Int, method :: Str, params :: jv.Json) -> Str {
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", JInt(id)), ("method", JStr(method)), ("params", params)]))
}

fn rpc_notify(method :: Str, params :: jv.Json) -> Str {
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("method", JStr(method)), ("params", params)]))
}

fn base_headers(auth :: List[(Str, Str)], session_id :: Str) -> Map[Str, Str] {
  let common := [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")]
  let with_sid := if str.is_empty(session_id) {
    common
  } else {
    list.concat(common, [("mcp-session-id", session_id)])
  }
  map.from_list(list.concat(with_sid, auth))
}

fn init_params() -> jv.Json {
  JObj([("protocolVersion", JStr("2024-11-05")), ("capabilities", JObj([])), ("clientInfo", JObj([("name", JStr("lex-mcp-client")), ("version", JStr("0.1.0"))]))])
}

# ── connect ───────────────────────────────────────────────────────────────────
# Performs initialize + notifications/initialized; returns a Session carrying any
# assigned mcp-session-id.
fn connect(url :: Str, auth :: List[(Str, Str)]) -> [net] ConnectResult {
  let reply := tr.post(url, base_headers(auth, ""), rpc_request(0, proto.method_initialize(), init_params()))
  match reply.result {
    None => ConnectFailed(reply.error),
    Some(_) => {
      let sid := reply.session_id
      let _ack := tr.post(url, base_headers(auth, sid), rpc_notify(proto.method_notifications_initialized(), JObj([])))
      Connected({ url: url, auth: auth, session_id: sid })
    },
  }
}

# ── list tools ────────────────────────────────────────────────────────────────
fn parse_tool(j :: jv.Json) -> proto.McpTool {
  let name := match jv.get_field(j, "name") {
    Some(JStr(n)) => n,
    _ => "",
  }
  let desc := match jv.get_field(j, "description") {
    Some(JStr(d)) => d,
    _ => "",
  }
  let schema := match jv.get_field(j, "inputSchema") {
    Some(sc) => sc,
    None => JObj([]),
  }
  { name: name, description: desc, input_schema: schema }
}

fn list_tools(sess :: Session) -> [net] Result[List[proto.McpTool], Str] {
  let reply := tr.post(sess.url, base_headers(sess.auth, sess.session_id), rpc_request(1, proto.method_tools_list(), JObj([])))
  match reply.result {
    None => Err(reply.error),
    Some(r) => match jv.get_field(r, "tools") {
      Some(JList(items)) => Ok(list.map(items, parse_tool)),
      _ => Ok([]),
    },
  }
}

# ── call a remote tool ────────────────────────────────────────────────────────
# Returns the MCP result's `content` (or the whole result), or {"error": ...}.
fn call_tool(sess :: Session, name :: Str, args :: jv.Json) -> [net] jv.Json {
  let params := JObj([("name", JStr(name)), ("arguments", args)])
  let reply := tr.post(sess.url, base_headers(sess.auth, sess.session_id), rpc_request(2, proto.method_tools_call(), params))
  match reply.result {
    None => JObj([("error", JStr(reply.error))]),
    Some(r) => match jv.get_field(r, "content") {
      Some(c) => c,
      None => r,
    },
  }
}

# ── the bridge: remote MCP tools -> native lex-llm Tools ──────────────────────
fn as_lex_tools(sess :: Session, tools :: List[proto.McpTool]) -> List[t.Tool] {
  list.map(tools, fn (mt :: proto.McpTool) -> t.Tool {
    t.define(mt.name, mt.description, bridge.to_model_schema(mt.name, mt.description, mt.input_schema), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      Ok(call_tool(sess, mt.name, args))
    })
  })
}

# ── convenience: connect + list + adapt in one call ───────────────────────────
# Drop the result straight into an agent's make_tools:
#   match mcpc.connect_tools(url, auth) { Ok(ts) => list.concat(base, ts), _ => base }
fn connect_tools(url :: Str, auth :: List[(Str, Str)]) -> [net] Result[List[t.Tool], Str] {
  match connect(url, auth) {
    ConnectFailed(msg) => Err(msg),
    Connected(sess) => match list_tools(sess) {
      Err(msg) => Err(msg),
      Ok(tools) => Ok(as_lex_tools(sess, tools)),
    },
  }
}

# Bearer-auth header list helper.
fn bearer(token :: Str) -> List[(Str, Str)] {
  if str.is_empty(token) {
    []
  } else {
    [("Authorization", str.concat("Bearer ", token))]
  }
}

