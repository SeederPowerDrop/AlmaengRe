use serde::{Deserialize, Serialize};
const MIB: u64 = 1024 * 1024;
const GIB: u64 = 1024 * MIB;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    physical_memory: u64,
    active_processor_count: i64,
    apple_silicon: bool,
    is_app_active: bool,
    low_power_mode: bool,
    thermal: i32,
    memory_pressure: i32,
    cpu_busy_fraction: Option<f64>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    total_concurrent_loads: i64,
    render_cache_bytes: u64,
    thumbnail_cache_bytes: u64,
    prefetch_count: i64,
    prefetch_delay_milliseconds: i64,
    visible_task_priority: &'static str,
    permits_speculation: bool,
    inter_load_delay_milliseconds: i64,
}
fn cache(maximum: u64, memory: u64, fraction: u64) -> u64 {
    (maximum * MIB).min(memory / fraction)
}
pub fn adaptive(mode: &str, s: &Snapshot, storage: &str) -> Limits {
    let cores = s.active_processor_count.max(1);
    let memory = s.physical_memory;
    let memory_concurrency = if memory >= 16 * GIB {
        4
    } else if memory >= 8 * GIB {
        2
    } else {
        1
    };
    let aggressive = (if s.apple_silicon { 4 } else { 2 })
        .min((cores / 2).max(1))
        .min(memory_concurrency);
    let gentle = (if s.apple_silicon { 2 } else { 1 })
        .min((cores / 4).max(1))
        .min(if memory >= 16 * GIB { 2 } else { 1 });
    let mut r = match mode {
        "priority" => Limits {
            total_concurrent_loads: aggressive,
            render_cache_bytes: cache(256, memory, 64),
            thumbnail_cache_bytes: cache(128, memory, 128),
            prefetch_count: 4,
            prefetch_delay_milliseconds: 150,
            visible_task_priority: "userInitiated",
            permits_speculation: true,
            inter_load_delay_milliseconds: 0,
        },
        "comfortable" => Limits {
            total_concurrent_loads: gentle,
            render_cache_bytes: cache(128, memory, 128),
            thumbnail_cache_bytes: cache(64, memory, 256),
            prefetch_count: 2,
            prefetch_delay_milliseconds: 350,
            visible_task_priority: "utility",
            permits_speculation: true,
            inter_load_delay_milliseconds: 0,
        },
        "normal" => Limits {
            total_concurrent_loads: 1,
            render_cache_bytes: cache(96, memory, 160),
            thumbnail_cache_bytes: cache(48, memory, 320),
            prefetch_count: 1,
            prefetch_delay_milliseconds: 650,
            visible_task_priority: "utility",
            permits_speculation: true,
            inter_load_delay_milliseconds: 25,
        },
        _ => Limits {
            total_concurrent_loads: 1,
            render_cache_bytes: cache(64, memory, 256),
            thumbnail_cache_bytes: cache(32, memory, 512),
            prefetch_count: 0,
            prefetch_delay_milliseconds: 1000,
            visible_task_priority: "background",
            permits_speculation: false,
            inter_load_delay_milliseconds: 100,
        },
    };
    match storage {
        "internalSSD" => {}
        "external" => {
            r.total_concurrent_loads = r.total_concurrent_loads.min(2);
            r.prefetch_count = r.prefetch_count.min(1);
            r.prefetch_delay_milliseconds = r.prefetch_delay_milliseconds.max(600);
        }
        _ => {
            r.total_concurrent_loads = 1;
            r.prefetch_count = 0;
            r.inter_load_delay_milliseconds = r.inter_load_delay_milliseconds.max(40);
        }
    }
    let cpu = s
        .cpu_busy_fraction
        .filter(|v| v.is_finite())
        .unwrap_or(0.)
        .max(0.);
    if s.thermal == 1 {
        r.total_concurrent_loads = r.total_concurrent_loads.min(2);
        r.prefetch_count = r.prefetch_count.min(1);
        r.prefetch_delay_milliseconds = r.prefetch_delay_milliseconds.max(600);
        if r.visible_task_priority == "userInitiated" {
            r.visible_task_priority = "utility";
        }
    }
    if cpu >= 0.65 {
        r.total_concurrent_loads = r.total_concurrent_loads.min(2);
        r.prefetch_count = 0;
        if r.visible_task_priority == "userInitiated" {
            r.visible_task_priority = "utility";
        }
    }
    if !s.is_app_active
        || s.low_power_mode
        || s.thermal >= 2
        || s.memory_pressure != 0
        || cpu >= 0.8
    {
        r.total_concurrent_loads = 1;
        r.prefetch_count = 0;
        r.prefetch_delay_milliseconds = r.prefetch_delay_milliseconds.max(1000);
        r.inter_load_delay_milliseconds = r.inter_load_delay_milliseconds.max(60);
        if r.visible_task_priority == "userInitiated" {
            r.visible_task_priority = "utility";
        }
    }
    if !s.is_app_active {
        r.visible_task_priority = "background";
    }
    if s.memory_pressure == 2 {
        r.render_cache_bytes = 0;
        r.thumbnail_cache_bytes = 0;
        r.inter_load_delay_milliseconds = r.inter_load_delay_milliseconds.max(150);
    } else if s.memory_pressure == 1 || !s.is_app_active {
        r.render_cache_bytes /= 4;
        r.thumbnail_cache_bytes /= 4;
    }
    if s.thermal == 3 {
        r.visible_task_priority = "background";
        r.inter_load_delay_milliseconds = r.inter_load_delay_milliseconds.max(150);
    }
    r.permits_speculation = r.prefetch_count > 0;
    r
}
#[unsafe(no_mangle)]
pub extern "C" fn am_decode_concurrency(memory: u64, cores: i64, apple: bool) -> i64 {
    if memory < 8 * GIB {
        return 1;
    }
    let budget = if memory >= 16 * GIB { 4 } else { 2 };
    (if apple { 4 } else { 2 })
        .min((cores / 2).max(1))
        .min(budget)
}
#[unsafe(no_mangle)]
pub extern "C" fn am_render_cache_bytes(memory: u64) -> u64 {
    (memory / 32).clamp(64 * MIB, 256 * MIB)
}
#[unsafe(no_mangle)]
pub extern "C" fn am_pixel_bucket(value: i64) -> i64 {
    let bounded = value.clamp(256, 8192);
    ((bounded + 255) / 256) * 256
}
#[unsafe(no_mangle)]
pub extern "C" fn am_maximum_tile_pixels(count: i64, memory: u64) -> i64 {
    let page = (memory / 64).clamp(128 * MIB, 256 * MIB);
    let pixels = ((page as f64 / count.max(1) as f64 / 8.).sqrt()) as i64;
    ((pixels / 256) * 256).clamp(512, 8192)
}
#[unsafe(no_mangle)]
pub extern "C" fn am_requested_pixels(
    width: f64,
    height: f64,
    scale: f64,
    zoom: f64,
    actual: bool,
    count: i64,
    memory: u64,
) -> i64 {
    let cap = am_maximum_tile_pixels(count, memory);
    if actual {
        return 8192;
    }
    let desired = width.max(height) * scale * zoom.max(1.) * 1.2;
    if !desired.is_finite() {
        return cap;
    }
    let limit = if zoom > 1. { 8192 } else { cap };
    limit.min(am_pixel_bucket(desired.max(512.).min(limit as f64) as i64))
}
#[unsafe(no_mangle)]
pub extern "C" fn am_preview_pixels(value: i64) -> i64 {
    value.clamp(256, 1024)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pixel_and_memory_bounds() {
        assert_eq!(am_decode_concurrency(4 * GIB, 20, true), 1);
        assert_eq!(am_decode_concurrency(24 * GIB, 8, true), 4);
        assert_eq!(am_decode_concurrency(u64::MAX, i64::MAX, false), 2);
        assert_eq!(am_pixel_bucket(i64::MAX), 8192);
        assert_eq!(am_pixel_bucket(-1), 256);
        assert!(am_maximum_tile_pixels(10, 24 * GIB) <= am_maximum_tile_pixels(1, 24 * GIB));
    }
    #[test]
    fn pressure_reclaims_cache() {
        let s = Snapshot {
            physical_memory: 24 * GIB,
            active_processor_count: 8,
            apple_silicon: true,
            is_app_active: true,
            low_power_mode: false,
            thermal: 0,
            memory_pressure: 2,
            cpu_busy_fraction: None,
        };
        let r = adaptive("priority", &s, "internalSSD");
        assert_eq!(r.total_concurrent_loads, 1);
        assert_eq!(r.render_cache_bytes, 0);
        assert!(!r.permits_speculation);
    }
}
