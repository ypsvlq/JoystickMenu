const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wio = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_framebuffer = true,
        .enable_joystick = true,
    });

    const TrueType = b.dependency("TrueType", .{
        .target = target,
        .optimize = optimize,
    });

    const ttf_bitstream_vera = b.dependency("ttf_bitstream_vera", .{});

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wio", .module = wio.module("wio") },
                .{ .name = "TrueType", .module = TrueType.module("TrueType") },
                .{ .name = "font", .module = b.createModule(.{ .root_source_file = ttf_bitstream_vera.path("Vera.ttf") }) },
                .{ .name = "font_bold", .module = b.createModule(.{ .root_source_file = ttf_bitstream_vera.path("VeraBd.ttf") }) },
            },
        }),
    });

    const client = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(server);
    b.installArtifact(client);

    const run_server_cmd = b.addRunArtifact(server);
    run_server_cmd.step.dependOn(b.getInstallStep());
    const run_server_step = b.step("run-server", "Run the server");
    run_server_step.dependOn(&run_server_cmd.step);

    const run_client_cmd = b.addRunArtifact(client);
    run_client_cmd.step.dependOn(b.getInstallStep());
    const run_client_step = b.step("run-client", "Run the client");
    run_client_step.dependOn(&run_client_cmd.step);
}
