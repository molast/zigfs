const std = @import("std");

/// Engine maps own these nodes and their record bytes; AVL borrows them. Generic
/// index users may supply borrowed keys instead. Index.deinit frees nodes only.
/// Allocate candidates before WAL append; insertion and rotations cannot fail.
pub const Node = struct {
    key: []const u8,
    left: ?*Node = null,
    right: ?*Node = null,
    payload: []u8 = &.{},
    generation: u64 = 0,
    height: i16 = 1,
    tombstone: bool = false,
    /// One internal checkpoint may borrow this version. The first overwrite or
    /// view release atomically transfers responsibility for freeing its payload.
    snapshot_pinned: std.atomic.Value(bool) = .init(false),

    /// Borrowed view; the engine owns the key and payload through this node.
    pub fn record(self: *const Node) @import("repository.zig").Record {
        return .{ .key = @constCast(self.key), .payload = self.payload, .generation = self.generation, .tombstone = self.tombstone };
    }
};

pub const Index = struct {
    root: ?*Node = null,

    pub fn upsert(self: *Index, allocator: std.mem.Allocator, node: *Node) void {
        self.root = insert(self.root, allocator, node);
    }

    /// Nodes must be sorted by unique key and owned by the caller.
    pub fn buildSorted(self: *Index, nodes: []*Node) void {
        self.root = balanced(nodes);
    }

    fn balanced(nodes: []*Node) ?*Node {
        if (nodes.len == 0) return null;
        const middle = nodes.len / 2;
        const root = nodes[middle];
        root.left = balanced(nodes[0..middle]);
        root.right = balanced(nodes[middle + 1 ..]);
        update(root);
        return root;
    }

    pub fn lowerBound(self: Index, key: []const u8, exclusive: bool) ?[]const u8 {
        var current = self.root;
        var candidate: ?[]const u8 = null;
        while (current) |node| {
            const order = std.mem.order(u8, node.key, key);
            if (order == .gt or (!exclusive and order == .eq)) {
                candidate = node.key;
                current = node.left;
            } else {
                current = node.right;
            }
        }
        return candidate;
    }

    /// Iterator borrows nodes and keys. The index must not be mutated until it
    /// is discarded; Engine holds its state mutex for the entire page traversal.
    pub fn iterator(self: Index, key: []const u8, exclusive: bool) Iterator {
        var result: Iterator = .{};
        var current = self.root;
        while (current) |node| {
            const order = std.mem.order(u8, node.key, key);
            if (order == .gt or (!exclusive and order == .eq)) {
                result.push(node);
                current = node.left;
            } else {
                current = node.right;
            }
        }
        return result;
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        destroy(self.root, allocator);
        self.* = .{};
    }
};

/// AVL height is less than twice log2(node_count + 1). A stack of twice the
/// address width therefore covers any tree representable in this address space.
/// No per-node parent pointers or traversal heap allocations are needed.
pub const Iterator = struct {
    path: [2 * @bitSizeOf(usize)]*const Node = undefined,
    depth: usize = 0,

    fn push(self: *Iterator, node: *const Node) void {
        std.debug.assert(self.depth < self.path.len);
        self.path[self.depth] = node;
        self.depth += 1;
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        return if (self.nextNode()) |node| node.key else null;
    }

    /// Borrowed node view with the same lock/lifetime requirement as next().
    pub fn nextNode(self: *Iterator) ?*const Node {
        if (self.depth == 0) return null;
        self.depth -= 1;
        const node = self.path[self.depth];
        var current = node.right;
        while (current) |child| {
            self.push(child);
            current = child.left;
        }
        return node;
    }
};

fn height(node: ?*Node) i16 {
    return if (node) |value| value.height else 0;
}

fn update(node: *Node) void {
    node.height = 1 + @max(height(node.left), height(node.right));
}

fn rotateRight(node: *Node) *Node {
    const root = node.left.?;
    node.left = root.right;
    root.right = node;
    update(node);
    update(root);
    return root;
}

fn rotateLeft(node: *Node) *Node {
    const root = node.right.?;
    node.right = root.left;
    root.left = node;
    update(node);
    update(root);
    return root;
}

fn insert(current: ?*Node, allocator: std.mem.Allocator, node: *Node) *Node {
    const root = current orelse return node;
    switch (std.mem.order(u8, node.key, root.key)) {
        .lt => root.left = insert(root.left, allocator, node),
        .gt => root.right = insert(root.right, allocator, node),
        .eq => {
            root.key = node.key;
            allocator.destroy(node);
            return root;
        },
    }
    update(root);
    const balance = height(root.left) - height(root.right);
    if (balance > 1) {
        if (height(root.left.?.left) < height(root.left.?.right)) root.left = rotateLeft(root.left.?);
        return rotateRight(root);
    }
    if (balance < -1) {
        if (height(root.right.?.right) < height(root.right.?.left)) root.right = rotateRight(root.right.?);
        return rotateLeft(root);
    }
    return root;
}

fn destroy(node: ?*Node, allocator: std.mem.Allocator) void {
    if (node) |value| {
        destroy(value.left, allocator);
        destroy(value.right, allocator);
        allocator.destroy(value);
    }
}
