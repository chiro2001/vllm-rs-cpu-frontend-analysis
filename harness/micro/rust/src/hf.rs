//! HF chat template 的最小高保真复刻。
//!
//! 本文件按 vLLM 0.26.0（commit 568afb3a）`rust/src/chat/src/renderer/hf/`
//! 逐个搬过来，保证 D2 测的是**与产品路径同一套语义**，而不是"随便找个
//! minijinja 环境"：
//!
//! * `build_environment`（`hf/template.rs`）：trim_blocks / lstrip_blocks /
//!   `minijinja_contrib::pycompat` 未知方法回调 / 覆盖 `tojson` 过滤器；
//! * `TemplateContext` / `TemplateMessage` / `TemplateTool`（`hf/mod.rs`）：
//!   模板上下文的数据形状；
//! * `to_template_value` + `TemplateMap`（`hf/value.rs`）：
//!   JSON → minijinja Value 的转换，以及"永远返回 UnknownMethod"的自定义
//!   map（HF 模板里 `dict.items()` 这类调用要靠 pycompat 兜）；
//! * `hf_tojson_filter`（`hf/tojson.rs`）：HF 的 `tojson` 语义
//!   （不 HTML 转义、支持 ensure_ascii / indent / separators / sort_keys）。
//!
//! 上游为 Apache-2.0，版权归 vLLM contributors。此处只做删减（去掉 tracing
//! 与 thiserror-ext 依赖），不改语义。

use std::collections::HashMap;
use std::sync::Arc;

use indexmap::IndexMap;
use minijinja::value::{Enumerator, Kwargs, Object, ObjectExt, ObjectRepr, ViaDeserialize};
use minijinja::{Environment, Error as MinijinjaError, ErrorKind, State, Value};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use serde_json_fmt::{JsonFormat, JsonSyntaxError};

// --------------------------------------------------------------- tojson 过滤器

pub(super) fn hf_tojson_filter(
    ViaDeserialize(value): ViaDeserialize<JsonValue>,
    kwargs: Kwargs,
) -> Result<Value, MinijinjaError> {
    let ensure_ascii = kwargs.get::<Option<bool>>("ensure_ascii")?.unwrap_or(false);
    let indent = parse_indent(
        kwargs.get::<Option<ViaDeserialize<IndentArg>>>("indent")?.map(|value| value.0),
    );
    let separators = parse_separators(
        kwargs
            .get::<Option<ViaDeserialize<SeparatorsArg>>>("separators")?
            .map(|value| value.0),
        indent.is_some(),
    );
    let sort_keys = kwargs.get::<Option<bool>>("sort_keys")?.unwrap_or(false);

    kwargs.assert_all_used()?;

    let json_str = {
        let value_to_serialize = if sort_keys {
            &sort_json_keys(&value)
        } else {
            &value
        };

        build_json_format(indent, separators.0, separators.1, ensure_ascii)?
            .format_to_string(value_to_serialize)
            .map_err(|error| {
                MinijinjaError::new(
                    ErrorKind::InvalidOperation,
                    format!("Failed to serialize JSON: {error}"),
                )
            })?
    };

    Ok(Value::from_safe_string(json_str))
}

#[derive(Deserialize)]
#[serde(untagged)]
enum IndentArg {
    Bool(bool),
    Integer(i64),
    String(String),
}

fn parse_indent(value: Option<IndentArg>) -> Option<String> {
    match value? {
        IndentArg::Bool(indent) => Some(if indent {
            " ".to_owned()
        } else {
            String::new()
        }),
        IndentArg::Integer(indent) => Some(if indent > 0 {
            " ".repeat(indent as usize)
        } else {
            String::new()
        }),
        IndentArg::String(indent) => Some(indent),
    }
}

#[derive(Deserialize)]
struct SeparatorsArg((String, String));

fn parse_separators(value: Option<SeparatorsArg>, pretty: bool) -> (String, String) {
    let Some(SeparatorsArg((item_separator, key_separator))) = value else {
        let default_item_separator = if pretty { "," } else { ", " };
        let default_key_separator = ": ";

        return (
            default_item_separator.to_owned(),
            default_key_separator.to_owned(),
        );
    };

    (item_separator, key_separator)
}

fn build_json_format(
    indent: Option<String>,
    item_separator: String,
    key_separator: String,
    ensure_ascii: bool,
) -> Result<JsonFormat, MinijinjaError> {
    JsonFormat::new()
        .indent(indent)
        .map_err(map_json_syntax_error("indent"))?
        .comma(item_separator)
        .map_err(map_json_syntax_error("separators (item)"))?
        .colon(key_separator)
        .map_err(map_json_syntax_error("separators (key)"))
        .map(|format| format.ascii(ensure_ascii))
}

fn map_json_syntax_error(
    field: &'static str,
) -> impl FnOnce(JsonSyntaxError) -> MinijinjaError + Copy {
    move |error| {
        MinijinjaError::new(
            ErrorKind::InvalidOperation,
            format!("invalid {field} value for tojson: {error}"),
        )
    }
}

fn sort_json_keys(value: &JsonValue) -> JsonValue {
    match value {
        JsonValue::Object(map) => {
            let mut sorted: serde_json::Map<String, JsonValue> = serde_json::Map::new();
            let mut keys: Vec<_> = map.keys().collect();
            keys.sort();
            for key in keys {
                sorted.insert(key.clone(), sort_json_keys(&map[key]));
            }
            JsonValue::Object(sorted)
        }
        JsonValue::Array(arr) => JsonValue::Array(arr.iter().map(sort_json_keys).collect()),
        _ => value.clone(),
    }
}

// ------------------------------------------------------- JSON → minijinja Value

#[derive(Debug, Serialize)]
#[serde(transparent)]
pub struct TemplateValue(pub Value);

pub fn to_template_value(value: JsonValue) -> TemplateValue {
    TemplateValue(match value {
        JsonValue::Array(values) => values
            .into_iter()
            .map(to_template_value)
            .map(|value| value.0)
            .collect::<Value>(),
        JsonValue::Object(values) => Value::from_object(TemplateMap(
            values
                .into_iter()
                .map(|(key, value)| (key, to_template_value(value).0))
                .collect(),
        )),
        value => Value::from_serialize(value),
    })
}

/// 与上游 `hf/value.rs` 的 `TemplateMap` 一致：方法调用一律返回 `UnknownMethod`，
/// 交给 pycompat 的 unknown-method 回调处理 `dict.items()` 之类。
#[derive(Debug)]
struct TemplateMap(IndexMap<String, Value>);

impl Object for TemplateMap {
    fn repr(self: &Arc<Self>) -> ObjectRepr {
        ObjectRepr::Map
    }

    fn get_value(self: &Arc<Self>, key: &Value) -> Option<Value> {
        self.0.get(key.as_str()?).cloned()
    }

    fn get_value_by_str(self: &Arc<Self>, key: &str) -> Option<Value> {
        self.0.get(key).cloned()
    }

    fn enumerate(self: &Arc<Self>) -> Enumerator {
        self.mapped_rev_enumerator(|this| {
            Box::new(this.0.keys().map(|key| Value::from(key.as_str())))
        })
    }

    fn enumerator_len(self: &Arc<Self>) -> Option<usize> {
        Some(self.0.len())
    }

    fn call_method(
        self: &Arc<Self>,
        _state: &State<'_, '_>,
        _method: &str,
        _args: &[Value],
    ) -> Result<Value, MinijinjaError> {
        Err(MinijinjaError::from(ErrorKind::UnknownMethod))
    }
}

// ------------------------------------------------------------- 模板上下文类型

#[derive(Debug, Serialize)]
pub struct TemplateMessage {
    pub role: String,
    pub content: TemplateContent,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<TemplateTool>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<TemplateToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum TemplateContent {
    String(String),
    OpenAi(Vec<TemplateContentPart>),
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TemplateContentPart {
    Text { text: String },
    Image,
    Video,
    Audio,
}

#[derive(Debug, Serialize)]
pub struct TemplateToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub tool_type: &'static str,
    pub function: TemplateToolFunction,
}

#[derive(Debug, Serialize)]
pub struct TemplateToolFunction {
    pub name: String,
    pub arguments: TemplateValue,
}

#[derive(Debug, Serialize)]
pub struct TemplateTool {
    #[serde(rename = "type")]
    pub tool_type: String,
    pub function: TemplateToolDefinition,
}

#[derive(Debug, Serialize)]
pub struct TemplateToolDefinition {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub parameters: TemplateValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub strict: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct TemplateContext<'a> {
    pub messages: &'a [TemplateMessage],
    pub add_generation_prompt: bool,
    pub continue_final_message: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<&'a [TemplateTool]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub documents: Option<&'a [JsonValue]>,
    #[serde(flatten)]
    pub template_kwargs: &'a HashMap<String, JsonValue>,
}

// ------------------------------------------------------------------ 环境构建

#[derive(Clone)]
pub struct CompiledChatTemplate {
    env: Environment<'static>,
}

impl CompiledChatTemplate {
    /// 与上游 `build_environment` 完全一致：编译一次，之后每请求只 render。
    pub fn new(template: String) -> Result<Self, MinijinjaError> {
        let mut env = Environment::new();
        env.set_trim_blocks(true);
        env.set_lstrip_blocks(true);
        env.add_template_owned("chat".to_owned(), template)?;
        env.set_unknown_method_callback(minijinja_contrib::pycompat::unknown_method_callback);
        env.add_filter("tojson", hf_tojson_filter);
        Ok(Self { env })
    }

    pub fn render(&self, ctx: &TemplateContext<'_>) -> Result<String, MinijinjaError> {
        let tmpl = self.env.get_template("chat")?;
        tmpl.render(ctx)
    }
}
