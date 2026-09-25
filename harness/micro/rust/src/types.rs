//! 两侧共用的数据结构（Rust 侧）。
//!
//! `EngineCoreRequest` / `EngineCoreSamplingParams` 按 vLLM 0.26.0
//! `rust/src/engine-core-client/src/protocol/{request,sampling}.rs` 抄写，
//! 保留字段名、类型与 `serde_tuple`（20 元素数组）/ `skip_serializing_if`
//! 语义。差异只有两处，均不影响字节量级：
//!   * 略去 `_eos_token_id` / `_all_stop_token_ids` 两个内部名下划线；
//!   * `OpaqueValue` 直接用 `rmpv::Value`（上游是同名 type alias）。
//!
//! OpenAI 请求/响应类型按本仓库 fixture 的实际形状定义（上游用
//! `openai-protocol` crate）。两者都是"serde 派生 + 逐字段反序列化"，
//! 工作量性质一致；字段集合见 docs/05-segment-costs.md 的口径说明。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rmpv::Value as RmpValue;
use serde::{Deserialize, Serialize};
use serde_tuple::{Deserialize_tuple, Serialize_tuple};

use crate::hf::TemplateValue;

pub type OpaqueValue = RmpValue;

// ------------------------------------------------------------------ D1：请求体

#[derive(Debug, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct FunctionDefinition {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub parameters: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct ToolSpec {
    #[serde(rename = "type")]
    pub tool_type: String,
    pub function: FunctionDefinition,
}

#[derive(Debug, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub tools: Option<Vec<ToolSpec>>,
    #[serde(default)]
    pub tool_choice: Option<serde_json::Value>,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    #[serde(default)]
    pub temperature: Option<f64>,
    #[serde(default)]
    pub top_p: Option<f64>,
    #[serde(default)]
    pub stream: Option<bool>,
    #[serde(default)]
    pub chat_template_kwargs: Option<HashMap<String, serde_json::Value>>,
}

// -------------------------------------------------- D3：EngineCoreRequest

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RepetitionDetectionParams {
    pub max_pattern_size: u32,
    #[serde(default)]
    pub min_pattern_size: u32,
    pub min_count: u32,
}

/// 上游：`rust/src/engine-core-client/src/protocol/sampling.rs`。
///
/// 注意：上游给该结构体加了 `skip_serializing_none`，但**不做 omit_defaults**
/// —— 取默认值的非 Option 字段仍会被编码进去；Python 侧 `SamplingParams`
/// 是 `omit_defaults=True`。这个差异就是 D3 想量出来的字节膨胀。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct EngineCoreSamplingParams {
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed: Option<i64>,
    pub max_tokens: u32,
    pub min_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_token_budget: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logprobs: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_logprobs: Option<i32>,
    pub min_p: f32,
    pub frequency_penalty: f32,
    pub presence_penalty: f32,
    pub repetition_penalty: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repetition_detection: Option<RepetitionDetectionParams>,
    pub stop_token_ids: Vec<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eos_token_id: Option<u32>,
    pub all_stop_token_ids: BTreeSet<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logit_bias: Option<HashMap<u32, f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allowed_token_ids: Option<Vec<u32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bad_words_token_ids: Option<Vec<Vec<u32>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub structured_outputs: Option<OpaqueValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logprob_token_ids: Option<Vec<u32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_reading_prefix_cache: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extra_args: Option<HashMap<String, serde_json::Value>>,
}

impl Default for EngineCoreSamplingParams {
    /// 与上游 `for_test()` 的零值/非零值默认一致（上游用 `DefaultFromSerde`）。
    fn default() -> Self {
        Self {
            temperature: 1.0,
            top_p: 1.0,
            top_k: 0,
            seed: None,
            max_tokens: 16,
            min_tokens: 0,
            thinking_token_budget: None,
            logprobs: None,
            prompt_logprobs: None,
            min_p: 0.0,
            frequency_penalty: 0.0,
            presence_penalty: 0.0,
            repetition_penalty: 1.0,
            repetition_detection: None,
            stop_token_ids: Vec::new(),
            eos_token_id: None,
            all_stop_token_ids: BTreeSet::new(),
            logit_bias: None,
            allowed_token_ids: None,
            bad_words_token_ids: None,
            structured_outputs: None,
            logprob_token_ids: None,
            skip_reading_prefix_cache: None,
            extra_args: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReasoningParserKwargs {
    pub chat_template_kwargs: HashMap<String, serde_json::Value>,
}

/// 上游：`rust/src/engine-core-client/src/protocol/request.rs`
/// （Python 对应 `vllm/v1/engine/__init__.py` 的 `EngineCoreRequest`）。
#[derive(Debug, Clone, PartialEq, Serialize_tuple, Deserialize_tuple)]
pub struct EngineCoreRequest {
    pub request_id: String,
    pub prompt_token_ids: Option<Vec<u32>>,
    pub mm_features: Option<OpaqueValue>,
    pub sampling_params: Option<EngineCoreSamplingParams>,
    pub pooling_params: Option<OpaqueValue>,
    pub arrival_time: f64,
    #[serde(default)]
    pub lora_request: Option<OpaqueValue>,
    #[serde(default)]
    pub cache_salt: Option<String>,
    #[serde(default)]
    pub data_parallel_rank: Option<u32>,
    #[serde(default)]
    pub prompt_embeds: Option<OpaqueValue>,
    #[serde(default)]
    pub prompt_is_token_ids: Option<Vec<bool>>,
    #[serde(default)]
    pub client_index: u32,
    #[serde(default)]
    pub current_wave: u32,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub trace_headers: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub resumable: bool,
    #[serde(default)]
    pub external_req_id: Option<String>,
    #[serde(default)]
    pub reasoning_ended: Option<bool>,
    #[serde(default)]
    pub reasoning_parser_kwargs: Option<ReasoningParserKwargs>,
    #[serde(default)]
    pub abort_immediately: bool,
}

impl Default for EngineCoreRequest {
    fn default() -> Self {
        Self {
            request_id: String::new(),
            prompt_token_ids: None,
            mm_features: None,
            sampling_params: None,
            pooling_params: None,
            arrival_time: 0.0,
            lora_request: None,
            cache_salt: None,
            data_parallel_rank: None,
            prompt_embeds: None,
            prompt_is_token_ids: None,
            client_index: 0,
            current_wave: 0,
            priority: 0,
            trace_headers: None,
            resumable: false,
            external_req_id: None,
            reasoning_ended: None,
            reasoning_parser_kwargs: None,
            abort_immediately: false,
        }
    }
}

// ------------------------------------------------ D4：响应体与流式分块

#[derive(Debug, Serialize, Deserialize)]
pub struct ResponseMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ResponseChoice {
    pub index: u32,
    pub message: ResponseMessage,
    pub finish_reason: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ResponseUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ChatCompletionResponse {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub model: String,
    pub choices: Vec<ResponseChoice>,
    pub usage: ResponseUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ChunkDelta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkChoice {
    pub index: u32,
    pub delta: ChunkDelta,
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatCompletionChunk {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub model: String,
    pub choices: Vec<ChunkChoice>,
}

// ------------------------------------------------------------------ 模板转换

/// 与上游 `to_template_message` 同形状：content 是字符串时走 `String` 分支。
pub fn message_to_template(role: &str, content: &str) -> crate::hf::TemplateMessage {
    crate::hf::TemplateMessage {
        role: role.to_string(),
        content: crate::hf::TemplateContent::String(content.to_string()),
        tools: None,
        reasoning: None,
        reasoning_content: None,
        tool_calls: None,
        tool_call_id: None,
    }
}

/// 与上游 `to_template_tools` 同形状：`parameters` 走 `to_template_value`。
pub fn tool_to_template(tool: &ToolSpec) -> crate::hf::TemplateTool {
    crate::hf::TemplateTool {
        tool_type: tool.tool_type.clone(),
        function: crate::hf::TemplateToolDefinition {
            name: tool.function.name.clone(),
            description: tool.function.description.clone(),
            parameters: crate::hf::to_template_value(
                tool.function
                    .parameters
                    .clone()
                    .unwrap_or(serde_json::Value::Null),
            ),
            strict: None,
        },
    }
}

/// `TemplateValue` 在 D2 里只是被搬进上下文；这里保留引用以便文档说明。
#[allow(dead_code)]
pub fn template_value_is_opaque(value: &TemplateValue) -> bool {
    let _ = value;
    true
}
