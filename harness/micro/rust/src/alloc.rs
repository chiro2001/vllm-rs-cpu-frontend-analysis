//! 计数分配器：量每个 op 在解析/序列化路径里**分配了多少次、多少字节**。
//!
//! 为什么需要：B 线的 perf 实测显示 `vllm-rs` 热点里 `serde_json` 几乎不进
//! top-20，真正大的是 **memcpy/memmove（10.6%）** 与 **mimalloc 家族（≈11%）**。
//! 光报"解析耗时"答不了"那 memcpy 从哪来"，所以这里补一条结构性证据：
//!
//!   * 分配**次数** × 平均块大小 → 有多少是"小对象分配"（allocator 内部搬数据）
//!   * 分配**总字节** ÷ 输入字节 → 解析一次要搬几倍于输入的数据
//!
//! 口径限制（写进文档）：
//!   * 只统计**分配**，不统计 release 时的合并/拷贝；
//!   * 只统计堆分配，栈上拷贝与 memcpy 不在这里（那是装载阶段）；
//!   * `realloc`（Vec 增长）按"一次分配 + 新增字节"计。

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering};

pub static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
pub static ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);
pub static REALLOC_COUNT: AtomicU64 = AtomicU64::new(0);

pub struct CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        ALLOC_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        REALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        if new_size > layout.size() {
            ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
            ALLOC_BYTES
                .fetch_add((new_size - layout.size()) as u64, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        ALLOC_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        unsafe { System.alloc_zeroed(layout) }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct AllocDelta {
    pub allocs: u64,
    pub bytes: u64,
    pub reallocs: u64,
}

impl AllocDelta {
    pub fn as_note(&self) -> String {
        format!(
            "allocs/op={:.1} alloc_bytes/op={:.0} reallocs/op={:.1}",
            self.allocs as f64,
            self.bytes as f64,
            self.reallocs as f64
        )
    }
}

/// 跑 `iterations` 次 `op`，返回这段区间里的分配增量。用于校准（不计时）。
///
/// 泛型参数不限定返回类型：同一个闭包既给 `measure_group`（返回字节数 f64）
/// 也给这里用，省得写两遍。
pub fn measure_allocs<R, F: FnMut() -> R>(iterations: u64, mut op: F) -> AllocDelta {
    let count0 = ALLOC_COUNT.load(Ordering::Relaxed);
    let bytes0 = ALLOC_BYTES.load(Ordering::Relaxed);
    let realloc0 = REALLOC_COUNT.load(Ordering::Relaxed);
    for _ in 0..iterations {
        std::hint::black_box(op());
    }
    let count1 = ALLOC_COUNT.load(Ordering::Relaxed);
    let bytes1 = ALLOC_BYTES.load(Ordering::Relaxed);
    let realloc1 = REALLOC_COUNT.load(Ordering::Relaxed);
    AllocDelta {
        allocs: count1.saturating_sub(count0),
        bytes: bytes1.saturating_sub(bytes0),
        reallocs: realloc1.saturating_sub(realloc0),
    }
}
