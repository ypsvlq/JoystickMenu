const std = @import("std");
const dvui = @import("dvui");
const wio = dvui.backend.wio;
const shared = @import("shared.zig");

const Config = struct {
    title: []const u8,
    entries: []const struct {
        name: []const u8,
        exec: []const u8,
    },
    timeout: u32 = 0,
    clients: []const []const u8,
    buttons: struct {
        up: u8,
        down: u8,
        select: u8,
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

const State = struct {
    position: usize = 0,
    ignore_up: bool = false,
    ignore_down: bool = false,
};

const gl_options: wio.GlOptions = .{ .major_version = 3 };

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

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "JoystickMenu",
        .mode = .fullscreen,
        .gl_options = gl_options,
    });
    defer window.destroy();
    window.setCursor(.none);

    var context = try window.glCreateContext(.{ .options = gl_options });
    defer context.destroy();
    window.glMakeContextCurrent(context);
    window.glSwapInterval(1);

    var dvui_wio = try dvui.backend.init(.{ .io = io, .window = window });
    defer dvui_wio.deinit();

    var dvui_opengl = try dvui.render_backend.init(gpa, wio.glGetProcAddress, "130");
    defer dvui_opengl.deinit();

    var dvui_window = try dvui.Window.init(@src(), gpa, dvui_wio.backend(&dvui_opengl), .{});
    defer dvui_window.deinit();

    var state: State = .{};

    const timeout = if (config.timeout > 0)
        std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(config.timeout)).nanoseconds
    else
        0;

    while (true) {
        wio.update();

        while (events.pop()) |event| {
            switch (event) {
                .close => return,
                else => _ = try dvui_wio.addEvent(&dvui_window, event),
            }
        }

        if (maybe_joystick) |*joystick| {
            if (joystick.poll()) |joystick_state| {
                const buttons = joystick_state.buttons;
                if (config.buttons.up < buttons.len) {
                    if (buttons[config.buttons.up] and state.position > 0 and !state.ignore_up) {
                        state.position -= 1;
                    }
                    state.ignore_up = buttons[config.buttons.up];
                }
                if (config.buttons.down < buttons.len) {
                    if (buttons[config.buttons.down] and state.position + 1 < config.entries.len and !state.ignore_down) {
                        state.position += 1;
                    }
                    state.ignore_down = buttons[config.buttons.down];
                }
                if (config.buttons.select < buttons.len and buttons[config.buttons.select]) {
                    try run(io, config, state.position);
                    return;
                }
            } else {
                joystick.close();
                maybe_joystick = null;
            }
        }

        if (timeout > 0 and std.Io.Timestamp.now(io, .awake).nanoseconds > timeout) {
            try run(io, config, 0);
            return;
        }

        dvui_opengl.clear();

        try dvui_window.begin(dvui_wio.nanoTime());
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .background = true, .expand = .both });
            tl.addText(config.title, .{ .font = .theme(.title) });
            tl.addText("\n\n", .{});
            for (config.entries, 0..) |entry, i| {
                const font = if (i == state.position) dvui.themeGet().font_body.withWeight(.bold) else dvui.themeGet().font_body;
                tl.addText(entry.name, .{ .font = font });
                tl.addText("\n", .{});
            }
            tl.deinit();
        }
        _ = try dvui_window.end(.{ .manage_backend = false });

        window.glSwapBuffers();
    }
}

fn run(io: std.Io, config: Config, position: usize) !void {
    if (config.entries.len == 0) return;

    const exec = config.entries[position].exec;

    for (config.clients) |client| {
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
        try writer.interface.writeAll(exec);
    }

    _ = try std.process.spawn(io, .{ .argv = &.{exec} });
}

fn joystickConnected(device: wio.JoystickDevice) void {
    if (maybe_joystick == null) {
        maybe_joystick = device.open();
    }
}
