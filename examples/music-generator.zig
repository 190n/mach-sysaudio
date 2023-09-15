const std = @import("std");
const sysaudio = @import("mach-sysaudio");

const Accidental = enum(i8) {
    flat = -1,
    none = 0,
    sharp = 1,
};

fn noteToFrequency(note: []const u8) f32 {
    var steps_from_a4: i32 = 0;

    const letter = note[0];
    const accidental: Accidental = switch (note.len) {
        2 => .none,
        3 => switch (note[1]) {
            '#' => .sharp,
            'b' => .flat,
            else => unreachable,
        },
        else => unreachable,
    };
    const octave = note[note.len - 1] - '0';

    steps_from_a4 += 12 * (@as(i16, octave) - 4);
    steps_from_a4 += switch (letter) {
        'C' => -9,
        'D' => -7,
        'E' => -5,
        'F' => -4,
        'G' => -2,
        'A' => 0,
        'B' => 2,
        else => unreachable,
    };
    steps_from_a4 += @intFromEnum(accidental);

    const half_step = comptime std.math.pow(f32, 2.0, 1.0 / 12.0);
    return 440.0 * std.math.pow(f32, half_step, @floatFromInt(steps_from_a4));
}

test noteToFrequency {
    try std.testing.expectApproxEqRel(@as(f32, 440), noteToFrequency("A4"), 0.0001);
    try std.testing.expectApproxEqRel(@as(f32, 261.6256), noteToFrequency("C4"), 0.0001);
}

const Note = struct {
    start: f32,
    duration: f32,
    pitch: f32,
};

var player: sysaudio.Player = undefined;

pub fn main() !void {
    var timer = try std.time.Timer.start();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = try sysaudio.Context.init(null, gpa.allocator(), .{ .deviceChangeFn = deviceChange });
    std.log.info("Took {} to initialize the context...", .{std.fmt.fmtDuration(timer.lap())});
    defer ctx.deinit();
    try ctx.refresh();
    std.log.info("Took {} to refresh the context...", .{std.fmt.fmtDuration(timer.lap())});

    const device = ctx.defaultDevice(.playback) orelse return error.NoDevice;
    std.log.info("Took {} to get the default playback device...", .{std.fmt.fmtDuration(timer.lap())});

    player = try ctx.createPlayer(device, writeCallback, .{});
    std.log.info("Took {} to create a player...", .{std.fmt.fmtDuration(timer.lap())});
    defer player.deinit();
    try player.start();
    std.log.info("Took {} to start the player...", .{std.fmt.fmtDuration(timer.lap())});

    try player.setVolume(0.02);
    std.log.info("Took {} to set the volume...", .{std.fmt.fmtDuration(timer.lap())});

    var buf: [16]u8 = undefined;
    std.log.info("player created & entering i/o loop...", .{});
    while (true) {
        std.debug.print("( paused = {}, volume = {d} )\n> ", .{ player.paused(), try player.volume() });
        const line = (try std.io.getStdIn().reader().readUntilDelimiterOrEof(&buf, '\n')) orelse break;
        var iter = std.mem.split(u8, line, ":");
        const cmd = std.mem.trimRight(u8, iter.first(), &std.ascii.whitespace);
        if (std.mem.eql(u8, cmd, "vol")) {
            var vol = try std.fmt.parseFloat(f32, std.mem.trim(u8, iter.next().?, &std.ascii.whitespace));
            try player.setVolume(vol);
        } else if (std.mem.eql(u8, cmd, "pause")) {
            try player.pause();
            try std.testing.expect(player.paused());
        } else if (std.mem.eql(u8, cmd, "play")) {
            try player.play();
            try std.testing.expect(!player.paused());
        } else if (std.mem.eql(u8, cmd, "exit")) {
            break;
        }
    }
}

var seconds_offset: f32 = 0.0;
fn writeCallback(_: ?*anyopaque, frames: usize) void {
    const seconds_per_frame = 1.0 / @as(f32, @floatFromInt(player.sampleRate()));

    const pitch = 440;
    const radians_per_second = pitch * 2.0 * std.math.pi;

    for (0..frames) |fi| {
        const sample = std.math.sin((seconds_offset + @as(f32, @floatFromInt(fi)) * seconds_per_frame) * radians_per_second);
        player.writeAll(fi, sample);
    }
    seconds_offset = @mod(seconds_offset + seconds_per_frame * @as(f32, @floatFromInt(frames)), 1.0);
}

fn deviceChange(_: ?*anyopaque) void {
    std.log.info("device change detected!", .{});
}
