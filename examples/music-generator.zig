const std = @import("std");
const sysaudio = @import("mach-sysaudio");

const Accidental = enum(i8) {
    flat = -1,
    none = 0,
    sharp = 1,
};

fn pitchFromString(note: []const u8) f32 {
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
        'c' => -9,
        'd' => -7,
        'e' => -5,
        'f' => -4,
        'g' => -2,
        'a' => 0,
        'b' => 2,
        else => unreachable,
    };
    steps_from_a4 += @intFromEnum(accidental);
    return steps_from_a4;
}

fn frequencyFromPitch(pitch: f32) f32 {
    const half_step = comptime std.math.pow(f32, 2.0, 1.0 / 12.0);
    return 440.0 * std.math.pow(f32, half_step, pitch);
}

test pitchFromString {
    // try std.testing.expectApproxEqRel(@as(f32, 440), pitchFromString("A4"), 0.0001);
    // try std.testing.expectApproxEqRel(@as(f32, 261.6256), pitchFromString("C4"), 0.0001);
}

const Note = struct {
    /// time when the note starts playing, in beats
    start: f32,
    /// how long the note plays for, in beats
    duration: f32,
    /// which note should play, in half steps from A4, or null for rest
    pitch: ?f32,

    pub fn init(start: f32, duration: f32, maybe_note_name: ?[]const u8) Note {
        return .{
            .start = start,
            .duration = duration,
            .pitch = if (maybe_note_name) |note_name| pitchFromString(note_name) else null,
        };
    }
};

const megalovania_notes = [_]Note{
    Note.init(0.0, 0.5, "d4"),
    Note.init(0.5, 0.5, "d4"),
    Note.init(1.0, 1.0, "d5"),
    Note.init(2.0, 1.5, "a4"),
    Note.init(3.5, 1.0, "g#4"),
    Note.init(4.5, 1.0, "g4"),
    Note.init(5.5, 1.0, "f4"),
    Note.init(6.5, 0.5, "d4"),
    Note.init(7.0, 0.5, "f4"),
    Note.init(7.5, 0.5, "g4"),

    Note.init(8.0, 0.5, "c4"),
    Note.init(8.5, 0.5, "c4"),
    Note.init(9.0, 1.0, "d5"),
    Note.init(10.0, 1.5, "a4"),
    Note.init(11.5, 1.0, "g#4"),
    Note.init(12.5, 1.0, "g4"),
    Note.init(13.5, 1.0, "f4"),
    Note.init(14.5, 0.5, "d4"),
    Note.init(15.0, 0.5, "f4"),
    Note.init(15.5, 0.5, "g4"),

    Note.init(16.0, 0.5, "b3"),
    Note.init(16.5, 0.5, "b3"),
    Note.init(17.0, 1.0, "d5"),
    Note.init(18.0, 1.5, "a4"),
    Note.init(19.5, 1.0, "g#4"),
    Note.init(20.5, 1.0, "g4"),
    Note.init(21.5, 1.0, "f4"),
    Note.init(22.5, 0.5, "d4"),
    Note.init(23.0, 0.5, "f4"),
    Note.init(23.5, 0.5, "g4"),

    Note.init(24.0, 0.5, "bb3"),
    Note.init(24.5, 0.5, "bb3"),
    Note.init(25.0, 1.0, "d5"),
    Note.init(26.0, 1.5, "a4"),
    Note.init(27.5, 1.0, "g#4"),
    Note.init(28.5, 1.0, "g4"),
    Note.init(29.5, 1.0, "f4"),
    Note.init(30.5, 0.5, "d4"),
    Note.init(31.0, 0.5, "f4"),
    Note.init(31.5, 0.5, "g4"),
};

const Voice = struct {
    notes: []const Note,
    note_index: usize = 0,
    seconds_offset: f32 = 0.0,
    decay: f32,
    seconds_per_beat: f32,

    pub fn init(notes: []const Note, bpm: f32, decay: f32) Voice {
        return .{
            .notes = notes,
            .decay = decay,
            .seconds_per_beat = 60.0 / bpm,
        };
    }

    pub fn generateSample(self: *Voice, increment: f32) f32 {
        defer self.seconds_offset += increment;

        var beat_offset = self.seconds_offset / self.seconds_per_beat;

        // check if we need to find the next note
        var note = self.notes[self.note_index];
        while (beat_offset >= note.start + note.duration) {
            self.note_index += 1;
            if (self.note_index >= self.notes.len) {
                self.note_index = 0;
                self.seconds_offset = 0;
                beat_offset = 0;
            }
            note = self.notes[self.note_index];
        }

        const radians_per_second = frequencyFromPitch(note.pitch orelse return 0) * 2.0 * std.math.pi;

        var sample = std.math.sin(self.seconds_offset * radians_per_second);
        const amplitude = std.math.pow(f32, self.decay, beat_offset - note.start);
        sample *= amplitude;

        return sample;
    }
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

    try player.setVolume(0.1);
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

var melody = Voice.init(&megalovania_notes, 240.0, 0.1);
var bass = Voice.init(&.{
    Note.init(0.0, 8.0, "d3"),
    Note.init(8.0, 8.0, "c3"),
    Note.init(16.0, 8.0, "b2"),
    Note.init(24.0, 4.0, "bb2"),
    Note.init(28.0, 4.0, "c3"),
}, 240.0, 0.8);

fn writeCallback(_: ?*anyopaque, frames: usize) void {
    const seconds_per_frame = 1.0 / @as(f32, @floatFromInt(player.sampleRate()));

    for (0..frames) |fi| {
        var sample = melody.generateSample(seconds_per_frame);
        sample += bass.generateSample(seconds_per_frame);
        player.writeAll(fi, sample);
    }
}

fn deviceChange(_: ?*anyopaque) void {
    std.log.info("device change detected!", .{});
}
