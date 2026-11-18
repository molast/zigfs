pub const Status = enum {
    initializing,
    recovering,
    ready,
    recovery_required,
};

pub const Failure = enum {
    none,
    corrupt_journal,
    corrupt_record,
    inconsistent_journal,
    unrecoverable_transaction,
    unavailable,
    out_of_memory,
};

pub const State = struct {
    status: Status = .initializing,
    failure: Failure = .none,

    pub fn begin(self: *State) void {
        self.* = .{ .status = .recovering };
    }

    pub fn markReady(self: *State) void {
        self.* = .{ .status = .ready };
    }

    pub fn markRequired(self: *State, err: Error) void {
        self.* = .{
            .status = .recovery_required,
            .failure = failureFromError(err),
        };
    }

    pub fn isReady(self: State) bool {
        return self.status == .ready;
    }
};

pub const Error = error{
    OutOfMemory,
    CorruptJournal,
    CorruptRecord,
    InconsistentJournal,
    UnrecoverableTransaction,
    Unavailable,
};

pub const Report = struct {
    committed_transactions: usize = 0,
    rolled_back_transactions: usize = 0,
    orphan_temporaries_removed: usize = 0,
};

pub fn failureFromError(err: Error) Failure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.CorruptJournal => .corrupt_journal,
        error.CorruptRecord => .corrupt_record,
        error.InconsistentJournal => .inconsistent_journal,
        error.UnrecoverableTransaction => .unrecoverable_transaction,
        error.Unavailable => .unavailable,
    };
}
