const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("warp", .{ .root_source_file = b.path("src/warp.zig"), .target = target, .optimize = optimize });
    addKernels(b, module, target, optimize);
    const library = b.addLibrary(.{ .name = "warp", .root_module = module });
    b.installArtifact(library);
    // Everything below is this repository's own: a project depending on
    // warp builds the module and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;

    const filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{};
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addKernels(b, test_module, target, optimize);
    // The differential corpus, captured once from other implementations
    // (pedronaugusto/trials, warp/), and the inputs it names.
    for ([_][]const u8{ "streams", "sizes", "invalid", "zstd-frames", "zstd-sizes", "zstd-invalid", "zstd-dictionaries" }) |name| {
        test_module.addAnonymousImport(b.fmt("{s}.corpus", .{name}), .{ .root_source_file = b.path(b.fmt("testdata/{s}.corpus", .{name})) });
    }
    test_module.addAnonymousImport("gen", .{ .root_source_file = b.path("bench/gen.zig") });
    const tests = b.addTest(.{ .name = "warp-tests", .filters = filters, .root_module = test_module });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    check.dependOn(&library.step);

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "warp", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);

    const zstd_cli = b.addExecutable(.{
        .name = "zstd-cli",
        .root_module = b.createModule(.{ .root_source_file = b.path("bench/cli/zstd.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "warp", .module = module }} }),
    });
    const cli_run = b.addRunArtifact(zstd_cli);
    cli_run.stdio = .inherit;
    cli_run.addPassthruArgs();
    b.step("zstd-cli", "Run the streaming zstd command example").dependOn(&cli_run.step);
    check.dependOn(&zstd_cli.step);

    // No Io and no OS calls but CPU detection: the library builds for a
    // target with no OS at all, and for a 32-bit and a big-endian one.
    const legs = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "check-freestanding", .query = .{ .cpu_arch = .wasm32, .os_tag = .freestanding } },
        .{ .name = "check-big-endian", .query = .{ .cpu_arch = .powerpc64, .os_tag = .linux } },
        .{ .name = "check-32-bit", .query = .{ .cpu_arch = .x86, .os_tag = .linux } },
    };
    for (legs) |leg| {
        const leg_target = b.resolveTargetQuery(leg.query);
        const object = b.addObject(.{
            .name = leg.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("ci/freestanding.zig"),
                .target = leg_target,
                .optimize = .small,
                .imports = &.{.{ .name = "warp", .module = warpModule(b, leg_target, .small) }},
            }),
        });
        b.step(leg.name, b.fmt("Build every public call for {s}", .{@tagName(leg.query.cpu_arch.?)})).dependOn(&object.step);
    }
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles are shakedown's, a lazy dependency only the tests
    // import. Its error is returned last, so one configure pass asks for it
    // and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        test_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    // CI wiring. preflight is lazy and only the root build asks for it.
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{ .{ .name = "bench", .source = "bench/main.zig" }, .{ .name = "zstd-bench", .source = "bench/zstd.zig" } },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on warp by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "warp", .program = b.path("ci/consumer.zig") });
    }
    return needed;
}

/// warp for `target` in `optimize`, with its checksum kernels.
fn warpModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/warp.zig"), .target = target, .optimize = optimize });
    addKernels(b, module, target, optimize);
    return module;
}

/// The checksum kernels that need instructions beyond the target's
/// baseline, each a module of its own built with those instructions
/// enabled; warp calls one only where the CPU has them (src/cpu.zig).
/// Zig sets CPU features per module, so these are the only modules that
/// may use them: nothing else in warp can be compiled into them.
fn addKernels(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    const fold = b.createModule(.{ .root_source_file = b.path("src/kernels/fold.zig"), .target = target, .optimize = optimize });
    const Kernel = struct { name: []const u8, source: []const u8, features: []const []const u8 };
    const kernels: []const Kernel = switch (target.result.cpu.arch) {
        .aarch64 => &.{
            .{ .name = "kernels_arm_crc", .source = "arm_crc", .features = &.{"crc"} },
            .{ .name = "kernels_arm_pmull", .source = "arm_pmull", .features = &.{ "crc", "aes" } },
            .{ .name = "kernels_arm_eor3", .source = "arm_eor3", .features = &.{ "crc", "aes", "sha3" } },
            .{ .name = "kernels_arm_dotprod", .source = "arm_dotprod", .features = &.{"dotprod"} },
        },
        .x86_64 => &.{
            .{ .name = "kernels_x86_crc", .source = "x86_crc", .features = &.{"sse4_2"} },
            .{ .name = "kernels_x86_sse", .source = "x86_sse", .features = &.{ "sse4_1", "pclmul" } },
            .{ .name = "kernels_x86_avx2", .source = "x86_avx2", .features = &.{ "avx2", "pclmul", "vpclmulqdq" } },
        },
        else => &.{},
    };
    for (kernels) |k| {
        var query = std.Target.Query.fromTarget(&target.result);
        for (k.features) |f| {
            const index = switch (target.result.cpu.arch) {
                .aarch64 => @backingInt(std.meta.stringToEnum(std.Target.aarch64.Feature, f).?),
                else => @backingInt(std.meta.stringToEnum(std.Target.x86.Feature, f).?),
            };
            query.cpu_features_add.addFeature(index);
        }
        const kernel = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/kernels/{s}.zig", .{k.source})),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
            .imports = &.{.{ .name = "kernels_fold", .module = fold }},
        });
        module.addImport(k.name, kernel);
    }
}

/// warp again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module. The benchmarks also import the generators and
/// the code warp replaces, copied as it was.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const warp = warpModule(b, target, optimize);
    const gen = b.createModule(.{ .root_source_file = b.path("bench/gen.zig"), .target = target, .optimize = optimize });
    const baseline = b.createModule(.{ .root_source_file = b.path("bench/baseline/baseline.zig"), .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "warp", .module = warp },
        .{ .name = "gen", .module = gen },
        .{ .name = "baseline", .module = baseline },
    }) catch @panic("OOM");
}
