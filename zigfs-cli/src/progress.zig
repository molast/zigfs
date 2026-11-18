//! Process-local terminal UI. Nested protocol calls inherit the outer command's
//! output policy, so internal JSON decoding does not suppress human progress.
pub extern fn zc_progress_configure(enabled: c_int, color: c_int) void;
pub extern fn zc_progress_stage(label: [*:0]const u8, total: u64) void;
pub extern fn zc_progress_update(done: u64) void;
pub extern fn zc_progress_part(number: u64, count: u64, offset: u64, total: u64) void;
pub extern fn zc_progress_finish(code: c_int) void;
pub extern fn zc_progress_object_begin(total: u64, resumed: u64, parts: u64) ?*anyopaque;
pub extern fn zc_progress_object_attach(object: ?*anyopaque, part: u64) void;
pub extern fn zc_progress_object_end(object: ?*anyopaque) void;
