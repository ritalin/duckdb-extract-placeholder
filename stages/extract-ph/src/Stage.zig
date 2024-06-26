const std = @import("std");
const zmq = @import("zmq");
const core = @import("core");

const Setting = @import("./Setting.zig");

const Symbol = core.Symbol;
const ExtractWorker = @import("./ExtractWorker.zig");

const APP_CONTEXT = "exctract-ph";
const Self = @This();

allocator: std.mem.Allocator,
context: *zmq.ZContext, // TODO 初期化をConnectionに組み込む
connection: *core.sockets.Connection.Client(ExtractWorker),
logger: core.Logger,

pub fn init(allocator: std.mem.Allocator, setting: Setting) !Self {
    const ctx = try allocator.create(zmq.ZContext);
    ctx.* = try zmq.ZContext.init(allocator);

    var connection = try core.sockets.Connection.Client(ExtractWorker).init(allocator, ctx);
    try connection.subscribe_socket.addFilters(.{
        .request_topic = true,
        .source_path = true,
        .end_watch_path = true,
        .quit_all = true,
        .quit = true,
    });
    try connection.connect(setting.endpoints);

    return .{
        .allocator = allocator,
        .context = ctx,
        .connection = connection,
        .logger = core.Logger.init(allocator, APP_CONTEXT, connection.dispatcher, false),
    };
}

pub fn deinit(self: *Self) void {
    self.connection.deinit();
    self.context.deinit();
    self.allocator.destroy(self.context);
}

pub fn run(self: *Self, setting: Setting) !void {
    try self.logger.log(.info, "Beginning...", .{});
    try self.logger.log(.debug, "Subscriber filters: {}", .{self.connection.subscribe_socket.listFilters()});

    dump_setting: {
        try self.logger.log(.debug, "CLI: Req/Rep Channel = {s}", .{setting.endpoints.req_rep});
        try self.logger.log(.debug, "CLI: Pub/Sub Channel = {s}", .{setting.endpoints.pub_sub});
        break :dump_setting;
    }

    launch: {
        try self.connection.dispatcher.post(.{
            .launched = try core.EventPayload.Stage.init(self.allocator, APP_CONTEXT),
        });
        break :launch;
    }

    var body_lookup = std.StringHashMap(LookupEntry).init(self.allocator);
    defer body_lookup.deinit();

    while (self.connection.dispatcher.isReady()) {
        const _item = self.connection.dispatcher.dispatch() catch |err| switch (err) {
            error.InvalidResponse => {
                try self.logger.log(.warn, "Unexpected data received", .{});
                continue;
            },
            else => return err,
        };

        if (_item) |item| {
            defer item.deinit();
            
            switch (item.event) {
                .request_topic => {
                    const topic = try core.EventPayload.Topic.init(
                        self.allocator, &.{ExtractWorker.Topics.Query, ExtractWorker.Topics.Placeholder}
                    );
                    
                    topics: {
                        try self.connection.dispatcher.post(.{.topic = topic});
                        break :topics;
                    }
                },
                .source_path => |path| {
                    try self.logger.log(.debug, "Accept source path: {s}", .{path.path});
                    try self.logger.log(.trace, "Begin worker process", .{});

                    const p1 = try path.clone(self.allocator);
                    try body_lookup.put(p1.path, .{.path = p1, .ref_count = 0});

                    const worker = try ExtractWorker.init(self.allocator, path.path);
                    try self.connection.pull_sink_socket.spawn(worker);
                },
                .worker_result => |result| {
                    try self.processWorkerResult(result.content, &body_lookup);

                    try self.logger.log(.trace, "End worker process", .{});

                    if (body_lookup.count() == 0) {
                        try self.connection.dispatcher.post(.finish_topic_body);
                    }
                },
                .end_watch_path => {
                    if (body_lookup.count() == 0) {
                        try self.connection.dispatcher.post(.finish_topic_body);
                    }
                },
                .quit, .quit_all => {
                    try self.connection.dispatcher.post(.{
                        .quit_accept = try core.EventPayload.Stage.init(self.allocator, APP_CONTEXT),
                    });
                },
                .log => |log| {
                    try self.logger.log(log.level, "{s}", .{log.content});
                },
                else => {
                    try self.logger.log(.warn, "Discard command: {}", .{std.meta.activeTag(item.event)});
                },
            }
        }
    }
}

fn processWorkerResult(self: *Self, result_content: Symbol, lookup: *std.StringHashMap(LookupEntry)) !void {
    var reader = core.CborStream.Reader.init(result_content);

    const item_count = try reader.readUInt(u32);
    const item_index = try reader.readUInt(u32);

    const result = try reader.readSlice(self.allocator, core.EventPayload.TopicBody.Item.Values);
    defer self.allocator.free(result);

    const lookup_key = result[0][1];

    if (lookup.getPtr(lookup_key)) |entry| {
        const path = entry.path;

        defer {
            if (entry.ref_count == item_count) {
                const ss = lookup.remove(lookup_key);
                std.debug.assert(ss);
                path.deinit();
            }
        }
        defer entry.ref_count += 1;

        var topic_body = try core.EventPayload.TopicBody.init(self.allocator, path, result);
        const event: core.Event = .{
            .topic_body = topic_body.withNewIndex(item_index, item_count),
        };

        try self.connection.dispatcher.post(event);
    } 
}

const LookupEntry = struct {
    path: core.EventPayload.SourcePath,
    ref_count: usize,
};