pub const Envelope = struct {
    profile: [32]u8 = @splat(0),
    key_id: [256]u8 = @splat(0),
    key_len: u16 = 0,
    ciphertext: [512]u8 = @splat(0),
    ciphertext_len: u16 = 0,
    pub fn key(self: *const Envelope) []const u8 {
        return self.key_id[0..self.key_len];
    }
};
