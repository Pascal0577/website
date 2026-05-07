const std = @import("std");
const net = std.Io.net;
const http = std.http;
const PATH_MAX = std.Io.Dir.max_path_bytes;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = try net.IpAddress.parse("0.0.0.0", 8080);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };

        _ = io.async(handleConnectionWrapper, .{ io, stream });
    }
}

fn handleConnectionWrapper(io: std.Io, stream: std.Io.net.Stream) error{Canceled}!void {
    defer stream.close(io);
    handleConnection(io, stream) catch |err| {
        std.log.err("connection error: {s}", .{@errorName(err)});
    };
}

const RequestResult = union(enum) {
    request: http.Server.ReceiveHeadError!http.Server.Request,
    timer: error{Canceled}!void,
};

fn handleConnection(io: std.Io, stream: std.Io.net.Stream) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    var http_server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var buf: [2]RequestResult = undefined;
        var select = std.Io.Select(RequestResult).init(io, &buf);

        select.async(.request, std.http.Server.receiveHead, .{&http_server});
        select.async(.timer, std.Io.sleep, .{ io, .fromSeconds(5), .awake });
        var request = switch (try select.await()) {
            .timer => {
                select.cancelDiscard();
                return error.Timeout;
            },
            .request => |r| blk: {
                select.cancelDiscard();
                break :blk r catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    else => return err,
                };
            },
        };

        const keep_alive = request.head.keep_alive;

        switch (request.head.method) {
            .GET => try handleGet(io, &request),
            else => {
                try request.respond("Not implemented.", .{ .status = .not_implemented });
            },
        }

        if (!keep_alive) return;
    }
}

fn handleGet(io: std.Io, request: *std.http.Server.Request) !void {
    const cwd = std.Io.Dir.cwd();
    const target = request.head.target;
    std.debug.print("target: {s}\n", .{target});

    if (std.mem.indexOf(u8, target, "..")) |_| {
        try request.respond("", .{ .status = .forbidden });
        return;
    }

    if (std.mem.eql(u8, "/", target)) {
        std.debug.print("redirecting to /home\n", .{});
        try request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/home" },
            },
        });
        return;
    }

    var fmt_buf: [PATH_MAX]u8 = undefined;
    // `target` always begins with `/`
    const to_open = try std.fmt.bufPrint(&fmt_buf, "web{s}", .{target});
    const metadata = cwd.statFile(io, to_open, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            try request.respond("404 not found", .{ .status = .not_found });
            return;
        },
        else => return e,
    };

    var path: []const u8 = to_open;
    var file: std.Io.File = undefined;
    switch (metadata.kind) {
        .file, .sym_link => file = try cwd.openFile(io, to_open, .{}),
        .directory => {
            var dir_buf: [PATH_MAX]u8 = undefined;
            path = try std.fmt.bufPrint(&dir_buf, "{s}/index.html", .{to_open});
            file = try cwd.openFile(io, path, .{});
        },
        else => return error.UnexpectedFileType,
    }
    defer file.close(io);

    const file_stat = try file.stat(io);
    var stream_buf: [4096]u8 = undefined;
    var response = try request.respondStreaming(&stream_buf, .{
        .content_length = file_stat.size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = mimeType(path) },
        } },
    });

    var offset: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (offset < file_stat.size) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try response.writer.writeAll(buf[0..n]);
        offset += n;
    }

    try response.end();
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    return "application/octet-stream";
}
