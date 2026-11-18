/// Shared engine namespace and payload bound; the old .record envelope is removed.
pub const Type = @import("metadata_engine").Type;
pub const max_payload_length = @import("metadata_engine").Limits.max_frame_bytes;
