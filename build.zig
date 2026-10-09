const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("warp", .{ .root_source_file = b.path("src/warp.zig"), .target = target, .optimize = optimize });
    addKernels(b, module, target, optimize);
    const library = b.addLibrary(.{ .name = "warp", .root_module = module });
    b.installArtifact(library);
    var c_library: ?*std.Build.Step.Compile = null;
    if (b.option(bool, "c-abi", "Build the zlib C stream ABI as libz") orelse false) {
        const c_module = b.createModule(.{ .root_source_file = b.path("src/c.zig"), .target = target, .optimize = optimize });
        addKernels(b, c_module, target, optimize);
        const artifact = b.addLibrary(.{ .name = "z", .root_module = c_module });
        b.installArtifact(artifact);
        c_library = artifact;
    }

    // Everything below is this repository's own: a project depending on
    // warp builds the module and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;

    const asset = compressedAsset(b, b, .{ .source = b.path("README.md"), .name = "README.gz" });
    const asset_test_module = b.createModule(.{
        .root_source_file = b.path("ci/asset.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{.{ .name = "warp", .module = warpModule(b, b.graph.host, .safe) }},
    });
    asset_test_module.addAnonymousImport("asset", .{ .root_source_file = asset });
    asset_test_module.addAnonymousImport("original", .{ .root_source_file = b.path("README.md") });
    const asset_test = b.addExecutable(.{ .name = "check-assets", .root_module = asset_test_module });
    b.step("check-assets", "Generate and verify an embedded compressed asset").dependOn(&b.addRunArtifact(asset_test).step);

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
    if (c_library) |artifact| check.dependOn(&artifact.step);

    const cli = b.addExecutable(.{
        .name = "warp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "warp", .module = module }},
        }),
    });
    const cli_step = b.step("cli", "Build and run the compression example");
    const cli_run = b.addRunArtifact(cli);
    cli_run.addPassthruArgs();
    cli_step.dependOn(&cli_run.step);
    check.dependOn(&cli.step);

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
    const zstd_cli_run = b.addRunArtifact(zstd_cli);
    zstd_cli_run.stdio = .inherit;
    zstd_cli_run.addPassthruArgs();
    b.step("zstd-cli", "Run the streaming zstd command example").dependOn(&zstd_cli_run.step);
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
    const no_crc_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m3 },
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{.crc}),
        .os_tag = .linux,
    });
    const no_crc = b.addObject(.{
        .name = "check-no-crc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/freestanding.zig"),
            .target = no_crc_target,
            .optimize = .small,
            .imports = &.{.{ .name = "warp", .module = warpModule(b, no_crc_target, .small) }},
        }),
    });
    const no_crc_step = b.step("check-no-crc", "Build with an explicitly disabled CRC CPU feature");
    no_crc_step.dependOn(&no_crc.step);
    check.dependOn(no_crc_step);
    const abi_check = b.step("check-c-abi", "Compile the C ABI natively, for 32-bit Linux and with CRC disabled");
    const abi_targets = [_]std.Build.ResolvedTarget{
        target,
        b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux }),
        no_crc_target,
    };
    for (abi_targets, 0..) |abi_target, i| {
        const abi_module = b.createModule(.{ .root_source_file = b.path("src/c.zig"), .target = abi_target, .optimize = .small });
        addKernels(b, abi_module, abi_target, .small);
        const object = b.addObject(.{ .name = b.fmt("check-c-abi-{d}", .{i}), .root_module = abi_module });
        abi_check.dependOn(&object.step);
    }
    check.dependOn(abi_check);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles are shakedown's, a lazy dependency only the tests
    // import. Its error is returned last, so one configure pass asks for it
    // and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    // Manual indicative measurements; ordinary CI compiles without fetching
    // a historical package. The workflow explicitly enables its pinned main.
    if (b.option(bool, "hosted-previous-main", "Compare indicative rows with pinned previous main") orelse false) {
        if (b.dependencyLazy("previous_main", .{ .target = target, .optimize = .fast })) |previous| {
            addHostedBench(b, target, previous.module("warp"), true, check);
        } else |err| needed = err;
    } else addHostedBench(b, target, warpModule(b, target, .fast), false, check);

    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        test_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    const size_module = b.createModule(.{
        .root_source_file = b.path("ci/sizes.zig"),
        .target = b.graph.host,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "warp", .module = warpModule(b, b.graph.host, .fast) },
            .{ .name = "gen", .module = b.createModule(.{ .root_source_file = b.path("bench/gen.zig"), .target = b.graph.host, .optimize = .fast }) },
        },
    });
    const captured_module = b.createModule(.{ .root_source_file = b.path("src/testing/corpus/data.zig"), .target = b.graph.host, .optimize = .fast });
    captured_module.addImport("gen", size_module.import_table.get("gen").?);
    captured_module.addAnonymousImport("sizes.corpus", .{ .root_source_file = b.path("testdata/sizes.corpus") });
    size_module.addImport("captured", captured_module);
    const size_gate = b.addExecutable(.{ .name = "check-sizes", .root_module = size_module });
    const size_run = b.addRunArtifact(size_gate);
    size_run.setCwd(b.path("."));
    size_run.has_side_effects = true;
    b.step("check-sizes", "Check each level's total against the captured limit on every standard corpus").dependOn(&size_run.step);
    check.dependOn(&size_gate.step);
    // CI wiring. preflight is lazy and only the root build asks for it.
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            // This ship requires compile-only benchmarks in CI. Their
            // manual runs and compile dependencies are owned below.
            .bench = .{
                .programs = &.{},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        const bench_step = &b.top_level_steps.get("bench").?.step;
        const programs = [_]struct { name: []const u8, source: []const u8 }{
            .{ .name = "bench", .source = "bench/main.zig" },
            .{ .name = "zstd-bench", .source = "bench/zstd.zig" },
        };
        var previous: ?*std.Build.Step = null;
        for (programs) |program| {
            const artifact = b.addExecutable(.{
                .name = program.name,
                .root_module = b.createModule(.{ .root_source_file = b.path(program.source), .target = target, .optimize = .fast, .imports = benchImports(b, target, .fast) }),
            });
            check.dependOn(&artifact.step);
            test_step.dependOn(&artifact.step);
            bench_step.dependOn(&b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
            const run = b.addRunArtifact(artifact);
            run.setCwd(b.tmpPath());
            run.has_side_effects = true;
            if (previous) |before| run.step.dependOn(before);
            previous = &run.step;
            bench_step.dependOn(&run.step);
        }
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
            query.cpu_features_sub.removeFeature(index);
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

pub const AssetOptions = struct {
    source: std.Build.LazyPath,
    name: []const u8,
    container: enum { raw, zlib, gzip } = .gzip,
    level: u4 = 12,
};

/// Build a deterministic compressed asset with a host executable. The
/// returned path can be embedded, installed or passed to another step.
/// `dependency` is warp's dependency, regardless of its name in the caller.
pub fn addCompressedAsset(b: *std.Build, dependency: *std.Build.Dependency, options: AssetOptions) std.Build.LazyPath {
    return compressedAsset(b, dependency.builder, options);
}

fn compressedAsset(b: *std.Build, root: *std.Build, options: AssetOptions) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "warp-asset",
        .root_module = b.createModule(.{
            .root_source_file = root.path("build/asset.zig"),
            .target = b.graph.host,
            .optimize = .fast,
            .imports = &.{.{ .name = "warp", .module = warpModule(root, b.graph.host, .fast) }},
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(options.source);
    const output = run.addOutputFileArg(options.name);
    run.addArgs(&.{ @tagName(options.container), b.fmt("{d}", .{options.level}) });
    return output;
}

fn addHostedBench(b: *std.Build, target: std.Build.ResolvedTarget, previous: *std.Build.Module, enabled: bool, check: *std.Build.Step) void {
    const current = warpModule(b, target, .fast);
    const options = b.addOptions();
    options.addOption(bool, "previous_main", enabled);
    options.addOption(bool, "control", b.option(bool, "hosted-control", "Use previous main in both DEFLATE arms") orelse false);
    options.addOption([]const u8, "commit", b.option([]const u8, "hosted-commit", "Revision for indicative measurement provenance") orelse "working-tree");
    const m = b.createModule(.{
        .root_source_file = b.path("bench/hosted.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "warp", .module = current },
            .{ .name = "previous", .module = if (enabled) previous else current },
            .{ .name = "gen", .module = b.createModule(.{ .root_source_file = b.path("bench/gen.zig"), .target = target, .optimize = .fast }) },
        },
    });
    m.addOptions("options", options);
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = .fast })) |shakedown| {
        m.addImport("shakedown", shakedown.module("shakedown"));
    } else |_| return;
    const artifact = b.addExecutable(.{ .name = "hosted-bench", .root_module = m });
    check.dependOn(&artifact.step);
    const step = b.step("hosted-bench", "Run indicative paired own/std/previous-main measurements");
    const run = b.addRunArtifact(artifact);
    run.has_side_effects = true;
    step.dependOn(&run.step);
}
