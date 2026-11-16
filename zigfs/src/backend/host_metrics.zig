const std = @import("std");
pub const Sample = extern struct {
    cpu_total: f64,
    cpu_idle: f64,
    cores: f64,
    memory_total: f64,
    memory_available: f64,
    virtual_bytes: f64,
    peak_rss: f64,
    threads: f64,
    descriptors: f64,
    descriptor_limit: f64,
    read_bytes: f64,
    write_bytes: f64,
    receive_bytes: f64,
    transmit_bytes: f64,
    user_seconds: f64,
    kernel_seconds: f64,
    load1: f64,
    load5: f64,
    load15: f64,
};
extern fn zigfs_host_metrics_read(sample: *Sample) void;
pub fn read() Sample {
    var result: Sample = undefined;
    zigfs_host_metrics_read(&result);
    return result;
}
pub fn available(value: f64) ?f64 {
    return if (std.math.isFinite(value) and value >= 0) value else null;
}
