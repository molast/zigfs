/// Stable namespaces matching ZigFS MetadataRepository; payloads remain opaque.
pub const Type = enum(u8) {
    system = 1,
    bucket = 2,
    object = 3,
    multipart = 4,
    credential = 5,
    directory = 6,
};
