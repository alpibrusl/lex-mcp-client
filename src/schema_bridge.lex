# schema_bridge.lex — MCP inputSchema (JSON Schema) -> lex-schema ModelSchema.
#
# An MCP tool advertises its arguments as a JSON-Schema object:
#   { "type": "object",
#     "properties": { "vin": {"type":"string","description":"..."}, ... },
#     "required": ["vin", ...] }
# lex-llm Tools carry a `s.ModelSchema` instead. This module converts the former
# into the latter so a remote MCP tool can be exposed as a native lex-llm Tool.
#
# v1 scope: scalars (string/integer/number/boolean) + arrays of scalars. Nested
# objects fall back to a string field (TODO: recurse into KObject).
#
# Pure value module — no effects.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

fn json_type(prop :: jv.Json) -> Str {
  match jv.get_field(prop, "type") {
    Some(JStr(t)) => t,
    _ => "string",
  }
}

fn prop_desc(prop :: jv.Json) -> Str {
  match jv.get_field(prop, "description") {
    Some(JStr(d)) => d,
    _ => "",
  }
}

# Map a JSON-Schema property to a lex-schema FieldKind.
fn kind_for(prop :: jv.Json) -> s.FieldKind {
  match json_type(prop) {
    "integer" => KInt([]),
    "number" => KFloat([]),
    "boolean" => KBool,
    "array" => {
      let elem := match jv.get_field(prop, "items") {
        Some(it) => kind_for(it),
        None => KStr([]),
      }
      KArray(elem, [])
    },
    _ => KStr([]),
  }
}

# Is `name` listed in the JSON-Schema `required` array?
fn name_in(name :: Str, req :: List[jv.Json]) -> Bool {
  not list.is_empty(list.filter(req, fn (x :: jv.Json) -> Bool {
    match x {
      JStr(s2) => s2 == name,
      _ => false,
    }
  }))
}

# Convert an MCP inputSchema object into a lex-schema ModelSchema.
fn to_model_schema(title :: Str, description :: Str, input_schema :: jv.Json) -> s.ModelSchema {
  let req := match jv.get_field(input_schema, "required") {
    Some(JList(xs)) => xs,
    _ => [],
  }
  let props := match jv.get_field(input_schema, "properties") {
    Some(JObj(entries)) => entries,
    _ => [],
  }
  let fields := list.map(props, fn (entry :: (Str, jv.Json)) -> s.Field {
    match entry {
      (pname, pschema) => { name: pname, required: name_in(pname, req), description: prop_desc(pschema), kind: kind_for(pschema) },
    }
  })
  { title: title, description: description, fields: fields }
}

