const std = @import("std");
const net = std.Io.net;
const http = std.http;
const PATH_MAX = std.Io.Dir.max_path_bytes;
var is_tty: bool = false;
var active_connections: std.atomic.Value(u32) = .init(0);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = .unlimited });
    const io = threaded.io();
    is_tty = try std.Io.File.stderr().isTty(io);
    log(.debug, null, "is tty? {}\n", .{is_tty});

    const addr = try net.IpAddress.parse("0.0.0.0", 8080);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        // It is handleConnectionWrapper's responsibility to free this memory
        // since it is async
        const owned_stream = try gpa.create(std.Io.net.Stream);
        owned_stream.* = server.accept(io) catch |err| {
            gpa.destroy(owned_stream);
            log(.warn, null, "accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        _ = active_connections.fetchAdd(1, .seq_cst);

        var fb: [22]u8 = undefined;
        var fb_writer = std.Io.Writer.fixed(&fb);
        try owned_stream.socket.address.format(&fb_writer);
        const owned_ip_address = try gpa.dupe(u8, fb[0..fb_writer.end]);
        log(.info, null, "instantiated connection with {s} ({d} active)\n", .{
            owned_ip_address,
            active_connections.load(.seq_cst),
        });

        _ = io.async(handleConnectionWrapper, .{ io, gpa, owned_stream, owned_ip_address });
    }
}

fn log(
    comptime level: enum { info, debug, warn, err },
    comptime src: ?std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const format = switch (level) {
        .info, .debug, .warn => fmt,
        .err => "{s}: {} " ++ fmt,
    };

    const arguments = switch (level) {
        .info, .debug, .warn => args,
        .err => .{ src.?.fn_name, src.?.line } ++ args,
    };

    const color = switch (level) {
        .info => "\x1b[32m",
        .debug => "\x1b[34m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };

    if (is_tty) {
        std.debug.print(color ++ "[{s}]\x1b[0m " ++ format, .{@tagName(level)} ++ arguments);
    } else {
        std.debug.print("[{s}] " ++ format, .{@tagName(level)} ++ arguments);
    }
}

fn handleConnectionWrapper(
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: *const std.Io.net.Stream,
    address: []const u8,
) error{Canceled}!void {
    defer gpa.free(address);
    defer log(.info, null, "Dropped connection with {s} ({d} active)\n", .{
        address,
        active_connections.load(.seq_cst),
    });
    defer _ = active_connections.fetchSub(1, .seq_cst);
    defer gpa.destroy(stream);
    defer stream.close(io);
    handleConnection(io, stream, address) catch |err| {
        log(.err, @src(), "connection error: {s}\n", .{@errorName(err)});
    };
}

const RequestResult = union(enum) {
    request: http.Server.ReceiveHeadError!http.Server.Request,
    timer: error{Canceled}!void,
};

fn handleConnection(
    io: std.Io,
    stream: *const std.Io.net.Stream,
    addr: []const u8,
) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    var http_server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        // Begin a race between a timer and receiving the request
        var buf: [2]RequestResult = undefined;
        var select = std.Io.Select(RequestResult).init(io, &buf);

        select.async(.request, std.http.Server.receiveHead, .{&http_server});
        select.async(.timer, std.Io.sleep, .{ io, .fromSeconds(1), .awake });
        var request = switch (try select.await()) {
            .timer => {
                select.cancelDiscard();
                log(.warn, null, "{s}: Request timed out\n", .{addr});
                return;
            },
            .request => |r| blk: {
                select.cancelDiscard();
                break :blk r catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    error.HttpRequestTruncated => {
                        log(.warn, null, "{s}: Connection closed before receiving headers\n", .{addr});
                        return;
                    },
                    error.ReadFailed => {
                        log(.warn, null, "{s}: Reading the HTTP request failed\n", .{addr});
                        return;
                    },
                    error.HttpHeadersOversize => {
                        log(.warn, null, "{s}: Client-sent headers were too large\n", .{addr});
                        writer.interface.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n") catch {};
                        return;
                    },
                    error.HttpHeadersInvalid => {
                        log(.warn, null, "{s}: Client sent invalid headers\n", .{addr});
                        writer.interface.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
                        return;
                    },
                };
            },
        };

        const method = request.head.method;
        switch (method) {
            .GET, .HEAD => try handleGetAndHead(io, &request, addr),
            else => {
                log(.warn, null, "{s}: Client requested {s}, but it's not implemented\n", .{ addr, @tagName(method) });
                log(.info, null, "{s}: Responding 501 NOT_IMPLEMENTED\n", .{addr});
                try request.respond("Not implemented.", .{ .status = .not_implemented });
            },
        }

        const keep_alive = request.head.keep_alive;
        if (keep_alive) log(.info, null, "{s}: Keeping connection alive\n", .{addr});
        if (!keep_alive) return;
    }
}

// returns where the request gets redirected to or null if it doesn't need redirect
fn redirect(request: *std.http.Server.Request, addr: []const u8) !?[]const u8 {
    const target = request.head.target;
    if (std.mem.eql(u8, "/", target)) {
        log(.info, null, "{s}: Redirecting request to /home\n", .{addr});
        log(.info, null, "{s}: Responding 302 FOUND\n", .{addr});
        try request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/home" },
            },
        });
        return "/home";
    }

    return null;
}

// GET and HEAD are very similar, so we handle them both
fn handleGetAndHead(
    io: std.Io,
    request: *std.http.Server.Request,
    addr: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const target: []const u8 = request.head.target;
    const method: std.http.Method = request.head.method;
    log(.info, null, "{s}: Received {s} method with target: {s}\n", .{ addr, @tagName(method), target });

    if (std.mem.indexOf(u8, target, "..")) |_| {
        log(.warn, null, "{s}: Tried to access file outside `web`\n", .{addr});
        try request.respond("", .{ .status = .forbidden });
        return;
    }

    // the loop in `handleConnection` will handle the new request
    if (try redirect(request, addr)) |_| return;

    var fmt_buf: [PATH_MAX]u8 = undefined;
    // `target` always begins with `/`
    const to_open = try std.fmt.bufPrint(&fmt_buf, "web{s}", .{target});
    const metadata = cwd.statFile(io, to_open, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            log(.warn, null, "{s}: Requested file `{s}` does not exist\n", .{ addr, to_open });
            log(.info, null, "{s}: Responding 404 NOT_FOUND\n", .{addr});
            try request.respond("404 not found", .{ .status = .not_found });
            return;
        },
        else => {
            log(.err, @src(), "{s}: Error get file stat: {s}, {any}\n", .{ addr, to_open, e });
            log(.info, null, "{s}: Responding 500 INTERNAL_SERVER_ERROR\n", .{addr});
            try request.respond("500 internal server error", .{ .status = .internal_server_error });
            return;
        },
    };

    var path: []const u8 = to_open;
    const file = switch (metadata.kind) {
        .file, .sym_link => try cwd.openFile(io, to_open, .{}),
        .directory => blk: {
            var dir_buf: [PATH_MAX]u8 = undefined;
            path = try std.fmt.bufPrint(&dir_buf, "{s}/index.html", .{to_open});
            break :blk try cwd.openFile(io, path, .{});
        },
        else => return error.UnexpectedFileType,
    };
    defer file.close(io);

    const file_size = (try file.stat(io)).size;
    var stream_buf: [4096]u8 = undefined;
    log(.info, null, "{s}: Responding 100 CONTINUE\n", .{addr});
    var response = request.respondStreaming(&stream_buf, .{
        .content_length = file_size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = mimeType(path) },
            .{ .name = "Cache-Control", .value = cacheControl(path) },
        } },
    }) catch |err| switch (err) {
        error.HttpExpectationFailed => return,
        error.WriteFailed => {
            log(.err, @src(), "{s}: Failed to respond 100 CONTINUE\n", .{addr});
            log(.info, null, "{s}: Responding 500 INTERNAL_SERVER_ERROR\n", .{addr});
            try request.respond(
                "500 internal server error",
                .{ .status = .internal_server_error },
            );
            return;
        },
    };

    if (request.head.method == .HEAD) {
        log(.info, null, "{s}: Responding 200 OK\n", .{addr});
        try request.respond("", .{});
        return;
    }

    log(.info, null, "{s}: Responding with: {s}\n", .{ addr, path });
    var offset: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (offset < file_size) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        response.writer.writeAll(buf[0..n]) catch |err| {
            log(.err, @src(), "{s}: Failed to write response: {}\n", .{ addr, err });
            return;
        };
        offset += n;
    }

    log(.info, null, "{s}: Responding 200 OK\n", .{addr});
    try response.end();
}

fn cacheControl(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "no-cache";
    if (std.mem.endsWith(u8, path, ".css")) return "no-cache";
    return "public, max-age=604800";
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}
