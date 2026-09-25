//! D 线微基准（Rust 侧）—— 逐段量 P2 / P3 / P6+P7 / P10 的成本。
//!
//! 与 `harness/micro/python/micro_py.py` 同输入同口径：同一份 fixture 字节、
//! 同样的预热/采样时长、同样的最近秩百分位、同一套 CSV 列。
//!
//! 用法见 `micro-bench --help`。

mod bench;
mod alloc;
mod hf;
mod types;

#[global_allocator]
static GLOBAL: alloc::CountingAllocator = alloc::CountingAllocator;

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::mpsc;

use bench::{measure, measure_group, BenchConfig, CsvWriter, Row};

const ALLOC_META: &str = "计数分配器：每次操作的堆分配（realloc 增长按增量记）";

const HELP: &str = "\
micro-bench —— D 线逐段微基准（Rust 侧）

用法:
  micro-bench d1 --fixture <chat_request.json> --point <tag> --out <csv> [选项]
  micro-bench d2 --template <chat_template.jinja> --fixture <chat_request.json> \\
                 --point <tag> --out <csv> [选项]
  micro-bench d3 --fixture <engine_core_request.json> --point <tag> --out <csv> [选项]
  micro-bench d4 --response <response.json> --chunks <chunks.json> --point <tag> \\
                 --out <csv> [选项]

通用选项:
  --warmup <秒>        预热时长（默认 10，要求 ≥10）
  --sample <秒>        正式采样时长（默认 30，要求 ≥30）
  --max-samples <n>    单次统计的样本上限（默认 400000）
  -h, --help           显示本帮助

分段与对照（对应 plan/experiment-matrix.md §4）:
  d1  P2   JSON 反序列化    serde_json::Value / 强类型结构体   ↔ Python json.loads / orjson
  d2  P3   chat 模板渲染    minijinja（含 HF tojson/pycompat）  ↔ Python Jinja2
  d3  P6/P7 msgpack 编解码  rmp-serde（serde_tuple 20 元素）    ↔ Python msgspec / msgpack
  d4  P10  JSON 序列化+SSE  serde_json + 同步 socket 写         ↔ Python json.dumps + asyncio 写
  d6  P4*  fastokens 预分词正则（B 线发现的 PCRE2 JIT 帧）—— D5 的补充，不替代
          tokenizer 项目的 BPE 结论；多线程口径，见 docs/05

d1 额外输出一份结构化摘要（`--check <json>`），d2/d4 可 dump 原始字节
（`--dump <path>`）供 runner 做两侧一致性校验。
";

#[derive(Debug, Clone)]
struct Args {
    flags: HashMap<String, String>,
}

impl Args {
    fn parse(argv: &[String]) -> Result<Self, String> {
        let mut flags = HashMap::new();
        let mut index = 0;
        while index < argv.len() {
            let key = argv[index].clone();
            if !key.starts_with("--") {
                return Err(format!("无法识别的参数: {key}"));
            }
            let name = key.trim_start_matches("--").to_string();
            match argv.get(index + 1) {
                Some(value) if !value.starts_with("--") => {
                    flags.insert(name, value.clone());
                    index += 2;
                }
                _ => {
                    flags.insert(name, "true".to_string());
                    index += 1;
                }
            }
        }
        Ok(Self { flags })
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.flags.get(name).map(String::as_str)
    }

    fn require(&self, name: &str) -> Result<&str, String> {
        self.get(name)
            .ok_or_else(|| format!("缺少必需参数 --{name}（试 --help）"))
    }

    fn f64_or(&self, name: &str, default: f64) -> f64 {
        self.get(name)
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    fn usize_or(&self, name: &str, default: usize) -> usize {
        self.get(name)
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    fn bench_config(&self) -> BenchConfig {
        BenchmarkGuard::check(self.f64_or("warmup", 10.0), self.f64_or("sample", 30.0));
        BenchConfig {
            warmup_s: self.f64_or("warmup", 10.0),
            sample_s: self.f64_or("sample", 30.0),
            max_samples: self.usize_or("max-samples", 400_000),
        }
    }
}

/// 资源纪律：预热 ≥10 s、采样 ≥30 s（plan/experiment-matrix.md §6）。
struct BenchmarkGuard;

impl BenchmarkGuard {
    fn check(warmup_s: f64, sample_s: f64) {
        let probe = warmup_s < 10.0 || sample_s < 30.0;
        if probe && std::env::var("DMICRO_ALLOW_SHORT").as_deref() != Ok("1") {
            eprintln!(
                "[micro-bench] 拒绝运行：warmup={warmup_s}s sample={sample_s}s 低于纪律下限（10s/30s）。\
                 只做冒烟时设 DMICRO_ALLOW_SHORT=1。"
            );
            std::process::exit(2);
        }
    }
}

fn read_bytes(path: &str) -> Result<Vec<u8>, String> {
    let path_ref = Path::new(path);
    std::fs::read(path_ref).map_err(|error| format!("读取 {path} 失败: {error}"))
}

fn label_of(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

fn short_label(path: &str) -> String {
    label_of(path)
        .trim_start_matches("chat_request_")
        .trim_start_matches("engine_core_request_")
        .trim_end_matches(".json")
        .to_string()
}

fn finalize(
    mut row: Row,
    seg: &str,
    point: &str,
    op: &str,
    label: &str,
    input_bytes: u64,
    tokens: u64,
    notes: &str,
) -> Row {
    row.seg = seg.to_string();
    row.point = point.to_string();
    row.op = op.to_string();
    row.input_label = label.to_string();
    row.input_bytes = input_bytes;
    row.tokens = tokens;
    row.notes = notes.to_string();
    row
}

/// 每条命令都量一条计时器自身开销（seg=meta），供引用小数字时参考。
fn clock_row(writer: &mut CsvWriter, point: &str) -> Result<(), String> {
    let cfg = BenchConfig {
        warmup_s: 2.0,
        sample_s: 3.0,
        max_samples: 200_000,
    };
    let mut sink = 0u64;
    let row = measure(&cfg, || {
        sink = sink.wrapping_add(1);
        std::hint::black_box(sink);
        0.0
    });
    let row = finalize(
        row,
        "meta",
        point,
        "clock_overhead",
        "empty-loop",
        0,
        0,
        "Instant::now()+elapsed 的单次开销（比较 <1µs 的操作前先看这行）",
    );
    writer.push(&row).map_err(|error| error.to_string())
}

/// 用计数分配器量一条"每次操作分配了多少次 / 多少字节"。
///
/// 为什么要它：B 线的 perf 显示线上热点是 memcpy/memmove 与 mimalloc，
/// 而不是 `serde_json` 本身 ⇒ 需要一条结构性证据说明"解析一次要分配/搬运
/// 几倍于输入的数据"。分配次数落在 `allocs_per_op`，总字节落在
/// `alloc_bytes_per_op`（除以迭代次数）。
fn attach_allocs(
    mut row: Row,
    iterations: u64,
    allocs: alloc::AllocDelta,
    alloc_meta: &str,
) -> Row {
    if iterations > 0 {
        row.allocs_per_op = Some(allocs.allocs as f64 / iterations as f64);
        row.alloc_bytes_per_op = Some(allocs.bytes as f64 / iterations as f64);
    }
    if !row.notes.is_empty() {
        row.notes.push_str("; ");
    }
    row.notes.push_str(&allocs.as_note());
    row.notes.push_str("; ");
    row.notes.push_str(alloc_meta);
    row
}

// --------------------------------------------------------------------- D1

fn run_d1(args: &Args) -> Result<(), String> {
    let fixture = args.require("fixture")?;
    let out = args.require("out")?;
    let point = args.get("point").unwrap_or("unnamed").to_string();
    let cfg = args.bench_config();
    let bytes = read_bytes(fixture)?;
    let label = short_label(fixture);

    let value = serde_json::from_slice::<serde_json::Value>(&bytes)
        .map_err(|error| format!("fixture 不是合法 JSON: {error}"))?;
    let typed = serde_json::from_slice::<types::ChatRequest>(&bytes)
        .map_err(|error| format!("fixture 不匹配 ChatRequest: {error}"))?;

    let summary = serde_json::json!({
        "messages": typed.messages.len(),
        "first_role": typed.messages.first().map(|m| m.role.clone()),
        "content_bytes": typed.messages.first().map(|m| m.content.len()),
        "tools": typed.tools.as_ref().map(|tools| tools.len()),
        "first_tool": typed.tools.as_ref()
            .and_then(|tools| tools.first())
            .map(|tool| tool.function.name.clone()),
        "max_tokens": typed.max_tokens,
        "stream": typed.stream,
        "value_bytes": serde_json::to_vec(&value).map(|v| v.len()).unwrap_or(0),
    });
    if let Some(path) = args.get("check") {
        std::fs::write(path, format!("{summary}\n")).map_err(|error| error.to_string())?;
    }
    eprintln!("[d1] {label} check={summary}");

    let mut writer = CsvWriter::create(out).map_err(|error| error.to_string())?;
    let size = bytes.len() as u64;

    // 同点两个 op 在同一个 ≥10s 预热 + ≥30s 采样窗口里轮转
    let mut parsed_len = 0usize;
    let mut typed_len = 0usize;
    let mut parse_value = || {
        let value = serde_json::from_slice::<serde_json::Value>(&bytes).expect("value parse");
        parsed_len = std::hint::black_box(value.as_object().map(|o| o.len()).unwrap_or(0));
        bytes.len() as f64
    };
    let mut parse_typed = || {
        let request = serde_json::from_slice::<types::ChatRequest>(&bytes).expect("typed parse");
        typed_len = std::hint::black_box(request.messages.len());
        bytes.len() as f64
    };
    let rows = measure_group(
        &cfg,
        &mut [
            ("serde_json::Value", &mut parse_value),
            ("serde_json::from_slice::<ChatRequest>", &mut parse_typed),
        ],
    );
    let allocs = [
        alloc::measure_allocs(500, &mut parse_value),
        alloc::measure_allocs(500, &mut parse_typed),
    ];
    for (index, row) in rows.into_iter().enumerate() {
        let op = row.op.clone();
        let notes = if op == "serde_json::Value" {
            "无类型解析，对应 Python json.loads 的口径"
        } else {
            "强类型解析（产品路径），含字段类型转换"
        };
        let _ = (parsed_len, typed_len);
        let row = finalize(row, "p2_json", &point, &op, &label, size, 0, notes);
        let row = attach_allocs(row, 500, allocs[index], ALLOC_META);
        writer
            .push(&row)
            .map_err(|error| error.to_string())?;
    }

    clock_row(&mut writer, &point)?;
    Ok(())
}

// --------------------------------------------------------------------- D2

fn run_d2(args: &Args) -> Result<(), String> {
    let template_path = args.require("template")?;
    let fixture = args.require("fixture")?;
    let out = args.require("out")?;
    let point = args.get("point").unwrap_or("unnamed").to_string();
    let cfg = args.bench_config();
    let label = short_label(fixture);

    let template = String::from_utf8(read_bytes(template_path)?)
        .map_err(|error| format!("模板不是 UTF-8: {error}"))?;
    let bytes = read_bytes(fixture)?;
    let request = serde_json::from_slice::<types::ChatRequest>(&bytes)
        .map_err(|error| format!("fixture 不匹配 ChatRequest: {error}"))?;

    let raw_kwargs = request
        .chat_template_kwargs
        .clone()
        .unwrap_or_default();
    let template_kwargs: HashMap<String, serde_json::Value> = raw_kwargs
        .into_iter()
        .filter(|(key, _)| key != "tools")
        .collect();

    let compiled = hf::CompiledChatTemplate::new(template).map_err(|error| error.to_string())?;

    // 转换段：ChatRequest → 模板上下文（上游 `to_template_messages` /
    // `to_template_tools` 每请求跑一次，含 JSON → minijinja Value 的搬运）。
    // 两套存储：`scratch_*` 给转换 op 写，`static_*` 给渲染 op 读，两个 op
    // 才能在同一窗口里轮转而不打架。
    let mut scratch_messages: Vec<hf::TemplateMessage> = Vec::new();
    let mut scratch_tools: Vec<hf::TemplateTool> = Vec::new();
    let mut static_messages: Vec<hf::TemplateMessage> = Vec::new();
    let mut static_tools: Vec<hf::TemplateTool> = Vec::new();
    for message in &request.messages {
        static_messages.push(types::message_to_template(&message.role, &message.content));
    }
    if let Some(specs) = &request.tools {
        for spec in specs {
            static_tools.push(types::tool_to_template(spec));
        }
    }
    let build_context = |messages: &mut Vec<hf::TemplateMessage>,
                         tools: &mut Vec<hf::TemplateTool>| {
        messages.clear();
        tools.clear();
        for message in &request.messages {
            messages.push(types::message_to_template(&message.role, &message.content));
        }
        if let Some(specs) = &request.tools {
            for spec in specs {
                tools.push(types::tool_to_template(spec));
            }
        }
    };

    let mut writer = CsvWriter::create(out).map_err(|error| error.to_string())?;
    let size = bytes.len() as u64;
    let tokens = request.messages.first().map(|m| m.content.len()).unwrap_or(0) as u64;

    build_context(&mut scratch_messages, &mut scratch_tools);
    let mut build_op = || {
        build_context(&mut scratch_messages, &mut scratch_tools);
        (scratch_messages.len() + scratch_tools.len()) as f64
    };
    let mut rendered_bytes = 0u64;
    let mut render_op = || {
        let ctx = hf::TemplateContext {
            messages: &static_messages,
            add_generation_prompt: true,
            continue_final_message: false,
            tools: Some(&static_tools),
            documents: None,
            template_kwargs: &template_kwargs,
        };
        let rendered = compiled.render(&ctx).expect("render");
        rendered_bytes = std::hint::black_box(rendered.len()) as u64;
        rendered.len() as f64
    };
    let rows = measure_group(
        &cfg,
        &mut [
            ("context_build", &mut build_op),
            ("minijinja_render", &mut render_op),
        ],
    );
    let allocs = [
        alloc::measure_allocs(500, &mut build_op),
        alloc::measure_allocs(200, &mut render_op),
    ];
    for (index, row) in rows.into_iter().enumerate() {
        let op = row.op.clone();
        let notes = if op == "context_build" {
            "ChatRequest → 模板上下文（messages/tools → minijinja Value），上游每请求一次"
        } else {
            "编译一次后每请求 render（HF tojson + pycompat）"
        };
        let hint_tokens = if op == "context_build" { tokens } else { rendered_bytes };
        let row = finalize(row, "p3_template", &point, &op, &label, size, hint_tokens, notes);
        let row = attach_allocs(row, if op == "context_build" { 500 } else { 200 }, allocs[index], ALLOC_META);
        writer.push(&row).map_err(|error| error.to_string())?;
    }

    let ctx = hf::TemplateContext {
        messages: &static_messages,
        add_generation_prompt: true,
        continue_final_message: false,
        tools: Some(&static_tools),
        documents: None,
        template_kwargs: &template_kwargs,
    };
    let rendered = compiled.render(&ctx).map_err(|error| error.to_string())?;
    if let Some(path) = args.get("dump") {
        std::fs::write(path, rendered.as_bytes()).map_err(|error| error.to_string())?;
    }
    eprintln!(
        "[d2] {label} rendered_bytes={} rendered_sha256={}",
        rendered.len(),
        sha256_hex(rendered.as_bytes())
    );

    clock_row(&mut writer, &point)?;
    Ok(())
}

// --------------------------------------------------------------------- D3

fn run_d3(args: &Args) -> Result<(), String> {
    let fixture = args.require("fixture")?;
    let out = args.require("out")?;
    let point = args.get("point").unwrap_or("unnamed").to_string();
    let cfg = args.bench_config();
    let bytes = read_bytes(fixture)?;
    let label = short_label(fixture);
    let request = serde_json::from_slice::<types::EngineCoreRequest>(&bytes)
        .map_err(|error| format!("fixture 不匹配 EngineCoreRequest: {error}"))?;
    let token_count = request
        .prompt_token_ids
        .as_ref()
        .map(|ids| ids.len())
        .unwrap_or(0) as u64;

    let encoded = rmp_serde::to_vec_named(&request).map_err(|error| error.to_string())?;
    if let Some(path) = args.get("payload-out") {
        std::fs::write(path, &encoded).map_err(|error| error.to_string())?;
    }
    let foreign = match args.get("decode-file") {
        Some(path) => Some(read_bytes(path)?),
        None => None,
    };

    let mut writer = CsvWriter::create(out).map_err(|error| error.to_string())?;
    let size = encoded.len() as u64;

    let mut out_len = 0usize;
    let mut encode_op = || {
        let payload = rmp_serde::to_vec_named(&request).expect("encode");
        out_len = std::hint::black_box(payload.len());
        payload.len() as f64
    };
    let mut decode_own_len = 0usize;
    let mut decode_own_op = || {
        let decoded = rmp_serde::from_slice::<types::EngineCoreRequest>(&encoded).expect("decode");
        decode_own_len = std::hint::black_box(
            decoded.prompt_token_ids.as_ref().map(|ids| ids.len()).unwrap_or(0),
        );
        encoded.len() as f64
    };

    match foreign {
        Some(foreign_bytes) => {
            let foreign_size = foreign_bytes.len() as u64;
            let mut decode_foreign_len = 0usize;
            let mut decode_foreign_op = || {
                let decoded = rmp_serde::from_slice::<types::EngineCoreRequest>(&foreign_bytes)
                    .expect("decode foreign");
                decode_foreign_len = std::hint::black_box(
                    decoded
                        .sampling_params
                        .as_ref()
                        .map(|params| params.stop_token_ids.len())
                        .unwrap_or(0),
                );
                foreign_bytes.len() as f64
            };
            let rows = measure_group(
                &cfg,
                &mut [
                    ("rmp_serde_encode", &mut encode_op),
                    ("rmp_serde_decode_rust_payload", &mut decode_own_op),
                    ("rmp_serde_decode_python_payload", &mut decode_foreign_op),
                ],
            );
            let alloc_deltas = [
                alloc::measure_allocs(300, &mut encode_op),
                alloc::measure_allocs(300, &mut decode_own_op),
                alloc::measure_allocs(300, &mut decode_foreign_op),
            ];
            for (op_index, row) in rows.into_iter().enumerate() {
                let op = row.op.clone();
                let (bytes, tokens, notes) = match op.as_str() {
                    "rmp_serde_encode" => (
                        size,
                        token_count,
                        "serde_tuple 20 元素数组 + 非 omit_defaults（Rust 侧真实线上字节）",
                    ),
                    "rmp_serde_decode_rust_payload" => (
                        size,
                        decode_own_len as u64,
                        "解码 Rust 自己编码的全量 map 字节",
                    ),
                    _ => (
                        foreign_size,
                        decode_foreign_len as u64,
                        "解码 Python msgspec omit_defaults 的稀疏字节（Rust 真实收包路径）",
                    ),
                };
                let seg = if op == "rmp_serde_encode" { "p6_msgpack" } else { "p7_msgpack" };
                let row = finalize(row, seg, &point, &op, &label, bytes, tokens, notes);
                let row = attach_allocs(row, 300, alloc_deltas[op_index], ALLOC_META);
                writer.push(&row).map_err(|error| error.to_string())?;
            }
        }
        None => {
            let rows = measure_group(
                &cfg,
                &mut [
                    ("rmp_serde_encode", &mut encode_op),
                    ("rmp_serde_decode_rust_payload", &mut decode_own_op),
                ],
            );
            let alloc_deltas = [
                alloc::measure_allocs(300, &mut encode_op),
                alloc::measure_allocs(300, &mut decode_own_op),
            ];
            for (op_index, row) in rows.into_iter().enumerate() {
                let op = row.op.clone();
                let (seg, bytes, tokens, notes) = if op == "rmp_serde_encode" {
                    (
                        "p6_msgpack",
                        size,
                        token_count,
                        "serde_tuple 20 元素数组 + 非 omit_defaults（Rust 侧真实线上字节）",
                    )
                } else {
                    (
                        "p7_msgpack",
                        size,
                        decode_own_len as u64,
                        "解码 Rust 自己编码的全量 map 字节",
                    )
                };
                let row = finalize(row, seg, &point, &op, &label, bytes, tokens, notes);
                let row = attach_allocs(row, 300, alloc_deltas[op_index], ALLOC_META);
                writer.push(&row).map_err(|error| error.to_string())?;
            }
        }
    }
    eprintln!("[d3] {label} rust_payload_bytes={out_len}");

    clock_row(&mut writer, &point)?;
    Ok(())
}

// --------------------------------------------------------------------- D4

fn spawn_sink() -> Result<(std::net::SocketAddr, mpsc::Receiver<u64>), String> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| error.to_string())?;
    let addr = listener.local_addr().map_err(|error| error.to_string())?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut total = 0u64;
        if let Ok((mut sock, _)) = listener.accept() {
            sock.set_nodelay(true).ok();
            let mut buf = vec![0u8; 1 << 16];
            loop {
                match sock.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => total += n as u64,
                }
            }
        }
        let _ = tx.send(total);
    });
    Ok((addr, rx))
}

fn sse_frame(json: &[u8]) -> Vec<u8> {
    // axum `Event::default().data(payload)` 的线格式：`data: <payload>\n\n`
    let mut frame = Vec::with_capacity(json.len() + 8);
    frame.extend_from_slice(b"data: ");
    frame.extend_from_slice(json);
    frame.extend_from_slice(b"\n\n");
    frame
}

fn run_d4(args: &Args) -> Result<(), String> {
    let response_path = args.require("response")?;
    let chunks_path = args.require("chunks")?;
    let out = args.require("out")?;
    let point = args.get("point").unwrap_or("unnamed").to_string();
    let cfg = args.bench_config();

    let response: types::ChatCompletionResponse =
        serde_json::from_slice(&read_bytes(response_path)?)
            .map_err(|error| format!("response fixture 解析失败: {error}"))?;
    let chunks: Vec<types::ChatCompletionChunk> = serde_json::from_slice(&read_bytes(chunks_path)?)
        .map_err(|error| format!("chunks fixture 解析失败: {error}"))?;
    let last_chunk = chunks.last().expect("chunks 非空").clone();

    let response_json = serde_json::to_vec(&response).map_err(|error| error.to_string())?;
    let chunk_json = serde_json::to_vec(&last_chunk).map_err(|error| error.to_string())?;
    let _response_frame = sse_frame(&response_json);
    let chunk_frame = sse_frame(&chunk_json);
    if let Some(path) = args.get("dump") {
        std::fs::write(path, &response_json).map_err(|error| error.to_string())?;
    }
    eprintln!(
        "[d4] response_bytes={} response_sha256={} chunk_bytes={} chunk_sha256={} chunks={}",
        response_json.len(),
        sha256_hex(&response_json),
        chunk_json.len(),
        sha256_hex(&chunk_json),
        chunks.len()
    );

    let (addr, rx) = spawn_sink()?;
    let stream = TcpStream::connect(addr).map_err(|error| error.to_string())?;
    stream.set_nodelay(true).ok();
    let mut sink = stream;

    let mut writer = CsvWriter::create(out).map_err(|error| error.to_string())?;
    let resp_bytes = response_json.len() as u64;
    let chunk_bytes = chunk_json.len() as u64;

    // 窗口 A：纯 CPU 的三个 op 轮转（序列化响应体 / 单帧组帧 / 整流组帧）
    let mut json_len = 0usize;
    let mut serialize_response = || {
        let json = serde_json::to_vec(&response).expect("serialize response");
        json_len = std::hint::black_box(json.len());
        json.len() as f64
    };
    let mut serialize_frame = || {
        let json = serde_json::to_vec(&last_chunk).expect("serialize chunk");
        sse_frame(&json).len() as f64
    };
    // 整请求：129 帧的“序列化 + 组帧”写进内存缓冲（不碰 socket）。
    // 写 socket 的单价由上面的 `write_frame_tcp` 单独给，避免每次迭代往
    // loopback 灌 ~23 KB 把采样带宽变成瓶颈。
    let mut stream_buf: Vec<u8> = Vec::with_capacity(32 * 1024);
    let mut build_stream = || {
        stream_buf.clear();
        for chunk in &chunks {
            let json = serde_json::to_vec(chunk).expect("serialize stream chunk");
            stream_buf.extend_from_slice(b"data: ");
            stream_buf.extend_from_slice(&json);
            stream_buf.extend_from_slice(b"\n\n");
        }
        stream_buf.extend_from_slice(b"data: [DONE]\n\n");
        std::hint::black_box(stream_buf.len()) as f64
    };
    let rows = measure_group(
        &cfg,
        &mut [
            ("serde_json_response", &mut serialize_response),
            ("serde_json_sse_frame", &mut serialize_frame),
            ("stream_request_local", &mut build_stream),
        ],
    );
    let alloc_deltas = [
        alloc::measure_allocs(500, &mut serialize_response),
        alloc::measure_allocs(500, &mut serialize_frame),
        alloc::measure_allocs(50, &mut build_stream),
    ];
    let stream_bytes = stream_buf.len() as u64;
    let _ = json_len;
    for (op_index, row) in rows.into_iter().enumerate() {
        let op = row.op.clone();
        let (seg, label_, bytes, tokens, notes) = match op.as_str() {
            "serde_json_response" => (
                "p10_serialize",
                "nonstream_body",
                resp_bytes,
                0u64,
                "非流式响应体整体序列化（强类型结构体）",
            ),
            "serde_json_sse_frame" => (
                "p10_serialize",
                "finish_chunk",
                chunk_bytes,
                0,
                "单个 SSE 帧（序列化 + `data: ...\\n\\n` 组帧，不写 socket）",
            ),
            _ => (
                "p10_sse",
                "osl_129_chunks",
                stream_bytes,
                chunks.len() as u64,
                "一次完整流式请求的 129 帧序列化+组帧（内存缓冲，不含 socket 写）",
            ),
        };
        let iters = if op == "stream_request_local" { 50 } else { 500 };
        let row = finalize(row, seg, &point, &op, label_, bytes, tokens, notes);
        let row = attach_allocs(row, iters, alloc_deltas[op_index], ALLOC_META);
        writer.push(&row).map_err(|error| error.to_string())?;
    }

    // 窗口 B：写 socket 单独一个窗口（syscall 与纯 CPU op 混在一起会互相污染）
    let row = measure(&cfg, || {
        sink.write_all(&chunk_frame).expect("write frame");
        chunk_frame.len() as f64
    });
    writer
        .push(&finalize(
            row,
            "p10_sse",
            &point,
            "write_frame_tcp",
            "finish_chunk",
            chunk_bytes,
            0,
            "一个 SSE 帧写 loopback TCP（阻塞 write_all；hyper/tokio 会另加一层）",
        ))
        .map_err(|error| error.to_string())?;

    drop(sink);
    let total = rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap_or(0);
    eprintln!("[d4] sink_received_bytes={total}");

    clock_row(&mut writer, &point)?;
    Ok(())
}

// --------------------------------------------------------------------- D6
//
// D6 是对 D5（"P4 分词不重测，引用 tokenizer 项目结论"）的**补充**，不是替代：
// tokenizer 项目测的是 fastokens 后端的 BPE/编码路径，没有单独测过 fastokens
// 的**预分词正则**。B 线的 perf 实测在 vllm-rs 进程里看到 PCRE2 JIT 帧
// （`[perf-<pid>.map]_[j]` 3.6% + `pcre2_match_8` 0.65% + `pcre2_jit_match_8`
// 0.51%），而 Cargo.lock 反查只有 `fastokens` 依赖 `pcre2` ⇒ 那些帧就是
// fastokens 的预分词正则。这里把预分词与 BPE 拆开量，补上缺的那一段。
//
// 口径注意事项（必须写进文档）：
//   * `fastokens` 的 Split 在有 ≥16 个 split 时会走 **rayon 线程池**
//     （`pre_tokenized.rs::PARALLEL_THRESHOLD`），线程数上限 8；
//     `limit.sh` 的 taskset 会把它压到绑定的核数（默认 4）。
//     所以 D6 的数字是**多线程**口径，与 D1–D4 的单线程口径不同。
//   * 用 `RAYON_NUM_THREADS=1` 复跑可拿到单线程对照（本命令会打印提示）。

fn run_d6(args: &Args) -> Result<(), String> {
    let text_path = args.require("text")?;
    let tokenizer_path = args.require("tokenizer")?;
    let out = args.require("out")?;
    let point = args.get("point").unwrap_or("unnamed").to_string();
    let cfg = args.bench_config();

    let text = String::from_utf8(read_bytes(text_path)?)
        .map_err(|error| format!("文本不是 UTF-8: {error}"))?;
    let tokenizer = fastokens::Tokenizer::from_file(Path::new(tokenizer_path))
        .map_err(|error| format!("加载 tokenizer 失败: {error}"))?;
    let label = short_label(text_path);
    let size = text.len() as u64;

    // 预分词：build_pre_tokenized（normalizer + added-token 切分）
    //         + pre_tokenizer().pre_tokenize（PCRE2 JIT 正则切分）
    let mut split_count = 0usize;
    let mut pretokenize_op = || {
        let mut pts = tokenizer.build_pre_tokenized(&text);
        if let Some(pre) = tokenizer.pre_tokenizer() {
            pre.pre_tokenize(&mut pts).expect("pre_tokenize");
        }
        split_count = std::hint::black_box(pts.splits().len());
        size as f64
    };
    let mut normalize_only_op = || {
        let pts = tokenizer.build_pre_tokenized(&text);
        std::hint::black_box(pts.splits().len()) as f64
    };
    let mut ids_len = 0usize;
    let mut encode_op = || {
        let ids = tokenizer.encode(&text).expect("encode");
        ids_len = std::hint::black_box(ids.len());
        size as f64
    };

    let rows = measure_group(
        &cfg,
        &mut [
            ("fastokens_pretokenize", &mut pretokenize_op),
            ("fastokens_build_pre_tokenized", &mut normalize_only_op),
            ("fastokens_encode_full", &mut encode_op),
        ],
    );
    let alloc_deltas = [
        alloc::measure_allocs(200, &mut pretokenize_op),
        alloc::measure_allocs(200, &mut normalize_only_op),
        alloc::measure_allocs(50, &mut encode_op),
    ];

    eprintln!(
        "[d6] {label} text_bytes={size} splits={split_count} token_ids={ids_len} \
         rayon_threads={}",
        std::env::var("RAYON_NUM_THREADS").unwrap_or_else(|_| "unset(默认=绑定核数,≤8)".into())
    );

    let mut writer = CsvWriter::create(out).map_err(|error| error.to_string())?;
    for (index, row) in rows.into_iter().enumerate() {
        let op = row.op.clone();
        let (seg, tokens, notes) = match op.as_str() {
            "fastokens_pretokenize" => (
                "p4_tokenize",
                split_count as u64,
                "fastokens 预分词（normalizer + added token + PCRE2 JIT 正则切分）；多线程口径",
            ),
            "fastokens_build_pre_tokenized" => (
                "p4_tokenize",
                split_count as u64,
                "只做 build_pre_tokenized（normalizer + added-token 切分），不含正则",
            ),
            _ => (
                "p4_tokenize",
                ids_len as u64,
                "fastokens 全量 encode（预分词 + BPE）；供与 tokenizer 项目结论对齐",
            ),
        };
        let iters = if op == "fastokens_encode_full" { 50 } else { 200 };
        let row = finalize(row, seg, &point, &op, &label, size, tokens, notes);
        let row = attach_allocs(row, iters, alloc_deltas[index], ALLOC_META);
        writer.push(&row).map_err(|error| error.to_string())?;
    }
    clock_row(&mut writer, &point)?;
    Ok(())
}

fn sha256_hex(data: &[u8]) -> String {
    // 微基准里不想引 sha2 依赖，直接用系统 sha256sum 的等价实现：
    // 这里只做短数据的校验和展示，用 FNV/自实现会误导，所以走 std::process。
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let mut child = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("sha256sum");
    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(data)
        .expect("write stdin");
    let output = child.wait_with_output().expect("sha256sum output");
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string()
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || argv.iter().any(|arg| arg == "-h" || arg == "--help") {
        print!("{HELP}");
        return;
    }

    let command = argv[0].clone();
    let args = match Args::parse(&argv[1..]) {
        Ok(args) => args,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2);
        }
    };

    let result = match command.as_str() {
        "d1" => run_d1(&args),
        "d2" => run_d2(&args),
        "d3" => run_d3(&args),
        "d4" => run_d4(&args),
        "d6" => run_d6(&args),
        other => {
            eprintln!("未知子命令: {other}\n");
            print!("{HELP}");
            std::process::exit(2);
        }
    };

    if let Err(error) = result {
        eprintln!("[micro-bench] 失败: {error}");
        std::process::exit(1);
    }
}
