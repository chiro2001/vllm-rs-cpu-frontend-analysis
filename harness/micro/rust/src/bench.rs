//! 计时核心：与 Python 侧 `python/micro_py.py` 完全同构的循环与统计口径。
//!
//! 口径（两侧必须一致，否则数字不可比）：
//! * **一个点一个窗口**：每个（语言 × 负载点）先预热 ≥ `warmup_s` 秒，
//!   再采样 ≥ `sample_s` 秒；同点内的多个 op 在这个窗口里**轮转**，
//!   各自计时、各自统计（`measure_group`）；
//! * **单次耗时**：`Instant::now()` / `perf_counter_ns()` 夹住**一次**操作；
//! * **抽稀**：按每个 op 的估计耗时定 stride，样本上限 `max_samples`
//!   （到上限后继续跑满时间，只是不再记录，避免内存爆掉）；
//! * **统计量**：mean / p50 / p90 / p99 / min / max / stdev（最近秩法）。
//!
//! 轮转测量的代价：同点的几个 op 共享 cache / allocator 状态，比"一个 op
//! 独占一个窗口"略脏；两侧（Rust / Python）用同一规则，对照仍然成立。
//! 窗口时长写进每行的 `wall_s`（对同点的所有 op 是同一个值）。
//!
//! 轮转按**时间片**批量跑（每批目标 ~1 ms）：否则一个 300 µs 的慢 op 会把
//! 一个 5 µs 的快 op 饿死（30 s 窗口里只剩几十个样本）。
//!
//! 计时器自身的开销单独量一条 `seg=meta, op=clock_overhead` 的行，
//! 引用小操作（<1 µs）的数字时要先看它。

use std::io::Write;
use std::time::{Duration, Instant};

fn fmt_opt(value: Option<f64>) -> String {
    match value {
        Some(number) => format!("{number:.2}"),
        None => String::new(),
    }
}

/// CSV 转义：notes 里会出现逗号/引号，必须按 RFC4180 包一层
fn csv_escape(value: &str) -> String {
    if value.contains(',') || value.contains('"') || value.contains('\n') {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

pub const CSV_HEADER: &str = "lang,seg,point,op,input_label,input_bytes,tokens,iterations,samples,wall_s,\
mean_us,p50_us,p90_us,p99_us,min_us,max_us,stdev_us,ops_per_sec,bytes_per_op,allocs_per_op,\
alloc_bytes_per_op,notes";

#[derive(Clone, Debug)]
pub struct BenchConfig {
    pub warmup_s: f64,
    pub sample_s: f64,
    pub max_samples: usize,
}

impl Default for BenchConfig {
    fn default() -> Self {
        Self {
            warmup_s: 10.0,
            sample_s: 30.0,
            max_samples: 400_000,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Row {
    pub lang: String,
    pub seg: String,
    pub point: String,
    pub op: String,
    pub input_label: String,
    pub input_bytes: u64,
    pub tokens: u64,
    pub iterations: u64,
    pub samples: u64,
    pub wall_s: f64,
    pub mean_us: f64,
    pub p50_us: f64,
    pub p90_us: f64,
    pub p99_us: f64,
    pub min_us: f64,
    pub max_us: f64,
    pub stdev_us: f64,
    pub ops_per_sec: f64,
    pub bytes_per_op: f64,
    /// 每次操作的堆分配次数 / 字节数：只有 Rust 侧能采（计数分配器），
    /// Python 侧留空。见 rust/src/alloc.rs 的口径说明。
    pub allocs_per_op: Option<f64>,
    pub alloc_bytes_per_op: Option<f64>,
    pub notes: String,
}

fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    // 最近秩法（nearest-rank）：与 Python 侧的实现保持一致
    let rank = (q * sorted.len() as f64).ceil().max(1.0) as usize;
    sorted[rank.min(sorted.len()) - 1]
}

fn build_row(samples: &mut Vec<f64>, iterations: u64, bytes_sum: f64, wall_s: f64) -> Row {
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = samples.len() as f64;
    let mean = if n > 0.0 {
        samples.iter().sum::<f64>() / n
    } else {
        f64::NAN
    };
    let var = if n > 1.0 {
        samples.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0)
    } else {
        0.0
    };

    Row {
        lang: "rust".to_string(),
        seg: String::new(),
        point: String::new(),
        op: String::new(),
        input_label: String::new(),
        input_bytes: 0,
        tokens: 0,
        iterations,
        samples: samples.len() as u64,
        wall_s,
        mean_us: mean / 1000.0,
        p50_us: percentile(&samples, 0.50) / 1000.0,
        p90_us: percentile(&samples, 0.90) / 1000.0,
        p99_us: percentile(&samples, 0.99) / 1000.0,
        min_us: samples.first().copied().unwrap_or(f64::NAN) / 1000.0,
        max_us: samples.last().copied().unwrap_or(f64::NAN) / 1000.0,
        stdev_us: var.sqrt() / 1000.0,
        ops_per_sec: iterations as f64 / wall_s,
        bytes_per_op: if n > 0.0 { bytes_sum / n } else { 0.0 },
        allocs_per_op: None,
        alloc_bytes_per_op: None,
        notes: String::new(),
    }
}

/// 一组"互相独立"的操作在同一窗口里轮转测量。每个 op 返回本次操作的字节数。
pub fn measure_group(cfg: &BenchConfig, ops: &mut [(&str, &mut dyn FnMut() -> f64)]) -> Vec<Row> {
    let n = ops.len();
    assert!(n > 0, "measure_group 至少一个 op");

    // 1) 试跑：每个 op 单独估一次单次耗时，用来定各自的 stride
    let pilot_n = 200u32;
    let mut per_op_s = vec![1e-12f64; n];
    for (index, (_, func)) in ops.iter_mut().enumerate() {
        let start = Instant::now();
        for _ in 0..pilot_n {
            std::hint::black_box(func());
        }
        per_op_s[index] = (start.elapsed().as_secs_f64() / f64::from(pilot_n)).max(1e-12);
    }

    // 2) 预热：轮转跑满 warmup_s
    let warmup_deadline = Instant::now() + Duration::from_secs_f64(cfg.warmup_s);
    while Instant::now() < warmup_deadline {
        for (_, func) in ops.iter_mut() {
            std::hint::black_box(func());
        }
    }

    // 3) 采样：轮转跑满 sample_s；每个 op 按自己的 stride 抽稀
    // 每批目标时长 ~1 ms：快的 op 一批多跑几次，慢的 op 一批一次，
    // 这样每个 op 在窗口里拿到的**时间**相近，快 op 也有足够样本。
    const TARGET_BATCH_S: f64 = 1e-3;
    let batch_sizes: Vec<u64> = per_op_s
        .iter()
        .map(|per_op| (TARGET_BATCH_S / per_op).round().max(1.0) as u64)
        .collect();
    let strides: Vec<u64> = per_op_s
        .iter()
        .map(|per_op| {
            let samples_in_window = (cfg.sample_s / per_op) / n as f64;
            (samples_in_window / cfg.max_samples as f64).floor().max(1.0) as u64
        })
        .collect();

    let mut samples: Vec<Vec<f64>> = (0..n).map(|_| Vec::new()).collect();
    let mut iterations = vec![0u64; n];
    let mut bytes_sum = vec![0f64; n];
    let sample_start = Instant::now();
    let mut cycles: u64 = 0;
    loop {
        for (index, (_, func)) in ops.iter_mut().enumerate() {
            for _ in 0..batch_sizes[index] {
                if iterations[index] % strides[index] == 0
                    && samples[index].len() < cfg.max_samples
                {
                    let t0 = Instant::now();
                    let bytes = func();
                    let dt = t0.elapsed().as_nanos() as f64;
                    samples[index].push(dt);
                    bytes_sum[index] += bytes;
                } else {
                    std::hint::black_box(func());
                }
                iterations[index] += 1;
            }
        }
        cycles += 1;
        if cycles % 4 == 0 && sample_start.elapsed().as_secs_f64() >= cfg.sample_s {
            break;
        }
        // 兜底：估计严重偏差时也不能跑飞（样本数已满且时间早已超窗）
        if cycles % 4 == 0
            && sample_start.elapsed().as_secs_f64() > cfg.sample_s * 4.0
            && samples.iter().all(|row| row.len() >= cfg.max_samples / 2)
        {
            break;
        }
    }
    let wall_s = sample_start.elapsed().as_secs_f64();

    (0..n)
        .map(|index| {
            let mut row = build_row(
                &mut samples[index],
                iterations[index],
                bytes_sum[index],
                wall_s,
            );
            row.op = ops[index].0.to_string();
            row
        })
        .collect()
}

/// 单个操作独占一个窗口（配 `measure_group` 用；也给 clock_overhead 用）。
pub fn measure<F>(cfg: &BenchConfig, mut op: F) -> Row
where
    F: FnMut() -> f64,
{
    let rows = measure_group(cfg, &mut [("op", &mut op)]);
    rows.into_iter().next().unwrap()
}

pub struct CsvWriter {
    file: std::fs::File,
}

impl CsvWriter {
    pub fn create(path: &str) -> std::io::Result<Self> {
        let file = std::fs::File::create(path)?;
        let mut writer = Self { file };
        writeln!(writer.file, "{CSV_HEADER}")?;
        Ok(writer)
    }

    pub fn push(&mut self, row: &Row) -> std::io::Result<()> {
        writeln!(
            self.file,
            "{},{},{},{},{},{},{},{},{},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3},{:.1},{:.1},{},{},{}",
            row.lang,
            row.seg,
            row.point,
            csv_escape(&row.op),
            csv_escape(&row.input_label),
            row.input_bytes,
            row.tokens,
            row.iterations,
            row.samples,
            row.wall_s,
            row.mean_us,
            row.p50_us,
            row.p90_us,
            row.p99_us,
            row.min_us,
            row.max_us,
            row.stdev_us,
            row.ops_per_sec,
            row.bytes_per_op,
            fmt_opt(row.allocs_per_op),
            fmt_opt(row.alloc_bytes_per_op),
            csv_escape(&row.notes),
        )
    }
}
