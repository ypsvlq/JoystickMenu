const std = @import("std");
const wio = @import("wio");
const TrueType = @import("TrueType");
const shared = @import("shared.zig");

const Config = struct {
    title: []const u8,
    entries: []const struct {
        name: []const u8,
        start: []const u8,
    },
    stop: []const u8,
    timeout: u16,
    clients: []const []const u8,
    buttons: struct {
        up: u16,
        down: u16,
        select: u16,
    },
    ui: struct {
        x: u16,
        y: u16,
        title_size: u16,
        entry_size: u16,
    },

    pub fn load(arena: std.mem.Allocator, io: std.Io) !Config {
        const file = try std.Io.Dir.cwd().openFile(io, "config.txt", .{});
        defer file.close(io);

        var reader = file.reader(io, &.{});
        var list: std.ArrayList(u8) = .empty;
        try reader.interface.appendRemaining(arena, &list, .unlimited);
        const bytes = try list.toOwnedSliceSentinel(arena, 0);

        var diagnostics: std.zon.parse.Diagnostics = .{};
        return std.zon.parse.fromSliceAlloc(Config, arena, bytes, &diagnostics, .{}) catch |err| {
            std.log.err("{f}", .{diagnostics});
            return err;
        };
    }
};

var maybe_joystick: ?wio.Joystick = null;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    try wio.init(.{
        .allocator = gpa,
        .io = io,
        .eventFn = wio.EventQueue.eventFn,
        .joystickConnectedFn = joystickConnected,
    });
    defer wio.deinit();
    defer if (maybe_joystick) |*joystick| joystick.close();

    const config = Config.load(arena, io) catch |err| {
        wio.messageBox(.err, "Error", "Failed to load config.txt");
        return err;
    };
    if (config.entries.len == 0) {
        wio.messageBox(.err, "Error", "No entries in config.txt");
        return;
    }
    try exec(io, config.clients, config.stop);

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "JoystickMenu",
        .mode = .fullscreen,
    });
    defer window.destroy();
    window.setCursor(.none);

    const font = try TrueType.load(@embedFile("font"));
    const font_bold = try TrueType.load(@embedFile("font_bold"));

    var maybe_ui: ?Ui = null;
    defer if (maybe_ui) |*ui| ui.deinit(gpa);

    var position: usize = 0;
    var ignore_up = false;
    var ignore_down = false;
    var ignore_select = false;
    var last_timeout_seconds: i64 = 0;

    var timeout = if (config.timeout > 0)
        std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(config.timeout)).nanoseconds
    else
        0;

    while (true) {
        wio.update();

        var draw = false;
        var run = false;

        while (events.pop()) |event| {
            switch (event) {
                .close => return,
                .size_physical => |new_size| {
                    if (maybe_ui) |*ui| {
                        try ui.resize(&window, new_size);
                    } else {
                        maybe_ui = try .init(&window, new_size);
                    }
                },
                .draw => draw = true,
                else => {},
            }
        }

        if (maybe_joystick) |*joystick| {
            if (joystick.poll()) |joystick_state| {
                const buttons = joystick_state.buttons;
                if (config.buttons.up < buttons.len) {
                    if (buttons[config.buttons.up] and position > 0 and !ignore_up) {
                        position -= 1;
                        timeout = 0;
                        draw = true;
                    }
                    ignore_up = buttons[config.buttons.up];
                }
                if (config.buttons.down < buttons.len) {
                    if (buttons[config.buttons.down] and position + 1 < config.entries.len and !ignore_down) {
                        position += 1;
                        timeout = 0;
                        draw = true;
                    }
                    ignore_down = buttons[config.buttons.down];
                }
                if (config.buttons.select < buttons.len) {
                    if (buttons[config.buttons.select] and !ignore_select) {
                        run = true;
                        timeout = 0;
                    }
                    ignore_select = buttons[config.buttons.select];
                }
            } else {
                joystick.close();
                maybe_joystick = null;
            }
        }

        if (timeout > 0) {
            const now = std.Io.Timestamp.now(io, .awake);
            if (now.nanoseconds > timeout) {
                run = true;
                timeout = 0;
            } else if (now.toSeconds() != last_timeout_seconds) {
                draw = true;
                last_timeout_seconds = now.toSeconds();
            }
        }

        if (run) {
            if (maybe_ui) |*ui| {
                ui.clear();
                var y = config.ui.y;
                try ui.text(font, gpa, "Running...", config.ui.entry_size, config.ui.x, &y);
                window.presentFramebuffer(&ui.framebuffer);
                draw = true;
            }

            try exec(io, config.clients, config.entries[position].start);
            var start = try std.process.spawn(io, .{ .argv = &.{config.entries[position].start} });
            _ = try start.wait(io);

            try exec(io, config.clients, config.stop);
        }

        if (draw) {
            if (maybe_ui) |*ui| {
                ui.clear();
                var y = config.ui.y;
                try ui.text(font, gpa, config.title, config.ui.title_size, config.ui.x, &y);
                try ui.text(font, gpa, "", config.ui.entry_size, config.ui.x, &y);
                for (config.entries, 0..) |entry, i| {
                    try ui.text(if (i == position) font_bold else font, gpa, entry.name, config.ui.entry_size, config.ui.x, &y);
                }
                if (timeout > 0) {
                    const text = try std.fmt.allocPrint(gpa, "(starting {s} in {} seconds)", .{ config.entries[0].name, std.Io.Timestamp.now(io, .awake).durationTo(.{ .nanoseconds = timeout }).toSeconds() });
                    defer gpa.free(text);
                    try ui.text(font, gpa, "", config.ui.entry_size, config.ui.x, &y);
                    try ui.text(font, gpa, text, config.ui.entry_size, config.ui.x, &y);
                }
                window.presentFramebuffer(&ui.framebuffer);
            }
        }

        wio.wait(.{ .timeout_ns = std.time.ns_per_s / 30 });
    }
}

fn exec(io: std.Io, clients: []const []const u8, command: []const u8) !void {
    for (clients) |client| {
        const ip = std.Io.net.IpAddress.parseIp4(client, shared.port) catch |err| {
            wio.messageBox(.err, "Error", "Invalid client IP");
            return err;
        };

        const stream = ip.connect(io, .{ .mode = .stream }) catch |err| {
            wio.messageBox(.err, "Error", "Connection failed");
            return err;
        };
        defer stream.close(io);

        var writer = stream.writer(io, &.{});
        try writer.interface.writeAll(command);
    }
}

const Ui = struct {
    framebuffer: wio.Framebuffer,
    size: wio.Size,
    pixels: std.ArrayList(u8) = .empty,

    fn init(window: *wio.Window, size: wio.Size) !Ui {
        return .{
            .framebuffer = try window.createFramebuffer(size),
            .size = size,
        };
    }

    fn deinit(self: *Ui, gpa: std.mem.Allocator) void {
        self.framebuffer.destroy();
        self.pixels.deinit(gpa);
    }

    fn resize(self: *Ui, window: *wio.Window, size: wio.Size) !void {
        self.framebuffer.destroy();
        self.framebuffer = try window.createFramebuffer(size);
        self.size = size;
    }

    fn clear(self: *Ui) void {
        for (0..self.size.height) |y| {
            for (0..self.size.width) |x| {
                self.framebuffer.setPixel(x, y, 0xFFFFFF);
            }
        }
    }

    fn text(self: *Ui, font: TrueType, gpa: std.mem.Allocator, chars: []const u8, height: u16, start_x: u16, start_y: *u16) !void {
        const scale = font.scaleForPixelHeight(height);
        const metrics = font.verticalMetrics();

        var x = start_x;
        var y = start_y.*;
        y += @round(metrics.ascent * scale);

        for (chars) |char| {
            const glyph = font.codepointGlyphIndex(char);
            if (font.glyphBitmap(gpa, &self.pixels, glyph, scale, scale)) |bitmap| {
                var y_in: u16 = 0;
                while (y_in < bitmap.height) : (y_in += 1) {
                    const y_out = @as(isize, y) + bitmap.off_y + y_in;
                    if (y_out >= self.size.height) break;
                    var x_in: u16 = 0;
                    while (x_in < bitmap.width) : (x_in += 1) {
                        const x_out = @as(isize, x) + bitmap.off_x + x_in;
                        if (x_out >= self.size.width) break;
                        const pixel: u32 = 0xFF - self.pixels.items[y_in * bitmap.width + x_in];
                        self.framebuffer.setPixel(@intCast(x_out), @intCast(y_out), pixel << 16 | pixel << 8 | pixel);
                    }
                }
                self.pixels.clearRetainingCapacity();
            } else |err| switch (err) {
                error.GlyphNotFound => {},
                else => return err,
            }
            x += @round(font.glyphHMetrics(glyph).advance_width * scale);
        }

        y += @round((-metrics.descent + metrics.line_gap) * scale);
        start_y.* = y;
    }
};

fn joystickConnected(device: wio.JoystickDevice) void {
    defer device.release();
    if (maybe_joystick == null) {
        maybe_joystick = device.open();
    }
}
