const std = @import("std");
const net = std.Io.net;
const http = std.http;
const PATH_MAX = std.Io.Dir.max_path_bytes;
var is_tty: bool = false;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    try setIsTty();
    std.debug.print("is tty? {}\n", .{is_tty});

    const addr = try net.IpAddress.parse("0.0.0.0", 8080);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        // It is handleConnectionWrapper's responsibility to free this memory
        // since it is async
        const owned_stream = try gpa.create(std.Io.net.Stream);
        owned_stream.* = server.accept(io) catch |err| {
            log(.warn, null, "accept failed: {s}\n", .{@errorName(err)});
            continue;
        };

        var fb: [22]u8 = undefined;
        var fb_writer = std.Io.Writer.fixed(&fb);
        try owned_stream.socket.address.format(&fb_writer);
        const owned_ip_address = try gpa.dupe(u8, fb[0..fb_writer.end]);
        log(.info, null, "instantiated connection with {s}\n", .{owned_ip_address});

        _ = io.async(handleConnectionWrapper, .{ io, gpa, owned_stream, owned_ip_address });
    }
}

fn log(
    comptime level: enum { info, debug, warn, err },
    comptime src: ?std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const arguments = switch (level) {
        .info, .debug, .warn => args,
        .err => .{ src.?.fn_name, src.?.line } ++ args,
    };

    if (is_tty) {
        const color = switch (level) {
            .info => "\x1b[32m",
            .debug => "\x1b[34m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };

        const format = switch (level) {
            .info, .debug, .warn => fmt,
            .err => color ++ "{s}: {} " ++ fmt,
        };

        std.debug.print(color ++ "[{s}]\x1b[0m " ++ format, .{@tagName(level)} ++ arguments);
    } else {
        const format = switch (level) {
            .info, .debug, .warn => fmt,
            .err => "{s}: {} " ++ fmt,
        };

        std.debug.print("[{s}] " ++ format, .{@tagName(level)} ++ arguments);
    }
}

fn setIsTty() !void {
    var t = std.Io.Threaded.init_single_threaded;
    defer t.deinit();
    const io = t.io();
    is_tty = try std.Io.File.stderr().isTty(io);
}

fn handleConnectionWrapper(
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: *const std.Io.net.Stream,
    address: []const u8,
) error{Canceled}!void {
    defer gpa.destroy(stream);
    defer gpa.free(address);
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
        select.async(.timer, std.Io.sleep, .{ io, .fromSeconds(5), .awake });
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
            .GET => try handleGet(io, &request, addr),
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

fn handleGet(
    io: std.Io,
    request: *std.http.Server.Request,
    addr: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const target = request.head.target;
    log(.info, null, "{s}: Received GET method with target: {s}\n", .{ addr, target });

    if (std.mem.indexOf(u8, target, "..")) |_| {
        log(.warn, null, "{s}: Tried to access file outside `web`", .{addr});
        try request.respond("", .{ .status = .forbidden });
        return;
    }

    if (std.mem.eql(u8, "/", target)) {
        log(.info, null, "{s}: Redirecting request to /home\n", .{addr});
        log(.info, null, "{s}: Responding 302 FOUND\n", .{addr});
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

    log(.info, null, "{s}: Responding with: {s}\n", .{ addr, path });

    const file_stat = try file.stat(io);
    var stream_buf: [4096]u8 = undefined;
    log(.info, null, "{s}: Responding 100 CONTINUE\n", .{addr});
    var response = request.respondStreaming(&stream_buf, .{
        .content_length = file_stat.size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = mimeType(path) },
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

    var offset: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (offset < file_stat.size) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        response.writer.writeAll(buf[0..n]) catch |err| {
            log(.err, @src(), "{s}: Failed to write response: {}\n", .{ addr, err });
            log(.info, null, "{s}: Responding 500 INTERNAL_SERVER_ERROR\n", .{addr});
            try request.respond(
                "500 internal server error",
                .{ .status = .internal_server_error },
            );
            return;
        };
        offset += n;
    }

    log(.info, null, "{s}: Responding 200 OK\n", .{addr});
    try response.end();
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    return "application/octet-stream";
}
