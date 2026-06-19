# use_elu_mcp.lex — wire the elu depot MCP into a lex agent's tool list.
#
# Shows the one-call integration: connect to the elu depot MCP server over
# streamable HTTP and append its tools (negotiate_charging_window, etc.) to an
# agent's own tools. A lex truck/tms/depot agent's make_tools would call this.

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-llm/src/tool" as t

import "../src/client" as mcpc

# Append the elu depot MCP's tools to `base`. Falls back to `base` on any
# connection error so the agent still works if the MCP server is down.
fn with_elu_tools(base :: List[t.Tool]) -> [net, env] List[t.Tool] {
  let url := match env.get("ELU_MCP_URL") {
    Some(u) => u,
    None => "http://ext-elu-depot:8097/mcp",
  }
  let token := match env.get("ELU_MCP_TOKEN") {
    Some(tk) => tk,
    None => "",
  }
  match mcpc.connect_tools(url, mcpc.bearer(token)) {
    Ok(ts) => list.concat(base, ts),
    Err(_) => base,
  }
}

fn main() -> [net, env, io] Unit {
  let tools := with_elu_tools([])
  io.print(str.concat("elu MCP tools loaded: ", int.to_str(list.len(tools))))
}

