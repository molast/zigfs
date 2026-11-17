/// Limits cover logical key/payload bytes, not total allocator or RSS overhead.
pub const Options = struct {
    max_records: usize = 1_000_000,
    max_live_bytes: usize = 512 * 1024 * 1024,
    max_snapshot_bytes: usize = 512 * 1024 * 1024,
    segment_bytes: u64 = 16 * 1024 * 1024,
    max_wal_bytes: u64 = 1024 * 1024 * 1024,
    max_page_records: usize = 10_000,
    max_page_bytes: usize = 16 * 1024 * 1024,
    /// Audit mode validates without creating files or truncating a torn WAL tail.
    read_only: bool = false,
    /// Clock reads are disabled unless diagnostics are requested.
    diagnostics: bool = false,

    pub fn validate(self: Options) !void {
        if (self.max_records == 0 or self.max_live_bytes == 0 or
            self.max_snapshot_bytes == 0 or self.segment_bytes < 128 or
            self.max_wal_bytes < self.segment_bytes or self.max_page_records == 0 or
            self.max_page_bytes == 0) return error.InvalidOptions;
    }
};

pub const Stats = struct {
    phases: PhaseStats = .{},
    generation: u64 = 0,
    /// Persistent absence fence; increments only when tombstones are reclaimed.
    gc_epoch: u48 = 0,
    tombstones_reclaimed: u64 = 0,
    checkpoint_generation: u64 = 0,
    records: usize = 0,
    live_bytes: usize = 0,
    /// Cumulative committed key/payload bytes since snapshot capture (not unique dirty keys).
    dirty_bytes: u64 = 0,
    wal_bytes: u64 = 0,
    active_wal_bytes: u64 = 0,
    commits: u64 = 0,
    syncs: u64 = 0,
    groups: u64 = 0,
    rotations: u64 = 0,
    linked_rotations: u64 = 0,
    rotation_copy_bytes: u64 = 0,
    checkpoints: u64 = 0,
    recovered_frames: u64 = 0,
    incomplete_tail_bytes: u64 = 0,
    orphan_temporaries_removed: usize = 0,
    /// A write that could fit after a checkpoint was rejected by the WAL quota.
    wal_pressure: bool = false,
    /// Snapshot is durable but covered WAL deletion/directory sync still needs work.
    cleanup_pending: bool = false,
    cleanup_retries: u64 = 0,
    recovery_required: bool = false,
};

pub const PhaseStats = struct {
    lock_wait: @import("timing.zig").Timing = .{},
    lock_hold: @import("timing.zig").Timing = .{},
    wal_append: @import("timing.zig").Timing = .{},
    wal_sync: @import("timing.zig").Timing = .{},
    rotation: @import("timing.zig").Timing = .{},
    snapshot_capture: @import("timing.zig").Timing = .{},
    snapshot_install: @import("timing.zig").Timing = .{},
    cleanup_io: @import("timing.zig").Timing = .{},
};
