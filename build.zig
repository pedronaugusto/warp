const std = @import("std");

/// What a project that depends on warp builds: the `warp` module, the library,
/// `libz` with `-Dc-abi`, and `addCompressedAsset` for a build that embeds a
/// compressed file. The tests, checks, benchmarks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = warpModule(b, target, optimize);
    b.modules.put(b.allocator, "warp", module) catch @panic("OOM");
    b.installArtifact(b.addLibrary(.{ .name = "warp", .root_module = module }));
    if (b.option(bool, "c-abi", "Build the zlib C stream ABI as libz") orelse false) {
        const c_module = b.createModule(.{ .root_source_file = b.path("src/c.zig"), .target = target, .optimize = optimize });
        addSourceImports(b, c_module, target, optimize);
        b.installArtifact(b.addLibrary(.{ .name = "z", .root_module = c_module }));
    }
}

/// warp's development: its tests, checks, examples and benchmarks under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const c_abi = b.option(bool, "c-abi", "Build the zlib C stream ABI as libz") orelse false;
    // Declare measurement settings up front, as options of this build.
    const package = b.dependency("warp", .{ .target = target, .optimize = optimize, .@"c-abi" = c_abi });
    const p = package.builder;

    const module = package.module("warp");
    const library = package.artifact("warp");

    const asset = compressedAsset(b, p, .{ .source = p.path("README.md"), .name = "README.gz" });
    const asset_test_module = b.createModule(.{
        .root_source_file = p.path("ci/asset.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{.{ .name = "warp", .module = warpModule(p, b.graph.host, .safe) }},
    });
    asset_test_module.addAnonymousImport("asset", .{ .root_source_file = asset });
    asset_test_module.addAnonymousImport("original", .{ .root_source_file = p.path("README.md") });
    const asset_test = b.addExecutable(.{ .name = "check-assets", .root_module = asset_test_module });
    b.step("check-assets", "Generate and verify an embedded compressed asset").dependOn(&b.addRunArtifact(asset_test).step);

    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSourceImports(p, test_module, target, optimize);
    addTestImports(b, p, test_module);
    const tests = b.addTest(.{ .name = "warp-tests", .filters = filters, .root_module = test_module });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The tests whose work is shared between threads: what ThreadSanitizer
    // runs, where the codecs' exhaustive single threaded loops would cost
    // its job its time and find nothing. The same root, built with only
    // their files' tests: a root of their own would compile in the tests of
    // every source file they import, which `test` runs already.
    const concurrent_files = [_][]const u8{ "testing.parallel_test.", "testing.speculative_test.", "testing.zstd_parallel_test.", "testing.index_test.", "testing.api_test." };
    const concurrent_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSourceImports(p, concurrent_module, target, optimize);
    addTestImports(b, p, concurrent_module);
    const concurrent_tests = b.addTest(.{
        .name = "warp-concurrent-tests",
        .filters = if (test_filter != null) filters else &concurrent_files,
        .root_module = concurrent_module,
    });
    b.step("concurrent", "Run the tests whose work is shared between threads").dependOn(&b.addRunArtifact(concurrent_tests).step);
    // The benchmarks' input generator and the code warp replaces carry tests
    // of their own; a test runs only from its module's root, so each is one.
    for ([_][]const u8{"bench/gen.zig"}) |source| {
        const suite = b.addTest(.{
            .root_module = b.createModule(.{ .root_source_file = p.path(source), .target = target, .optimize = optimize }),
            .filters = filters,
        });
        test_step.dependOn(&b.addRunArtifact(suite).step);
    }
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    check.dependOn(&concurrent_tests.step);
    check.dependOn(&library.step);
    if (c_abi) check.dependOn(&package.artifact("z").step);

    const cli = b.addExecutable(.{
        .name = "warp",
        .root_module = b.createModule(.{
            .root_source_file = p.path("bench/cli.zig"),
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
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "warp", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);

    const zstd_cli = b.addExecutable(.{
        .name = "zstd-cli",
        .root_module = b.createModule(.{ .root_source_file = p.path("bench/cli/zstd.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "warp", .module = module }} }),
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
                .root_source_file = p.path("ci/freestanding.zig"),
                .target = leg_target,
                .optimize = .small,
                .imports = &.{.{ .name = "warp", .module = warpModule(p, leg_target, .small) }},
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
            .root_source_file = p.path("ci/freestanding.zig"),
            .target = no_crc_target,
            .optimize = .small,
            .imports = &.{.{ .name = "warp", .module = warpModule(p, no_crc_target, .small) }},
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
        const abi_module = b.createModule(.{ .root_source_file = p.path("src/c.zig"), .target = abi_target, .optimize = .small });
        addSourceImports(p, abi_module, abi_target, .small);
        const object = b.addObject(.{ .name = b.fmt("check-c-abi-{d}", .{i}), .root_module = abi_module });
        abi_check.dependOn(&object.step);
    }
    check.dependOn(abi_check);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles are shakedown's.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    test_module.addImport("shakedown", shakedown.module("shakedown"));
    concurrent_module.addImport("shakedown", shakedown.module("shakedown"));

    const size_module = b.createModule(.{
        .root_source_file = p.path("ci/sizes.zig"),
        .target = b.graph.host,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "warp", .module = warpModule(p, b.graph.host, .fast) },
            .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = b.graph.host, .optimize = .fast }).module("aegis") },
        },
    });
    const captured_module = b.createModule(.{ .root_source_file = p.path("src/testing/corpus/data.zig"), .target = b.graph.host, .optimize = .fast });
    captured_module.addImport("gen", b.createModule(.{ .root_source_file = p.path("bench/gen.zig"), .target = b.graph.host, .optimize = .fast }));
    captured_module.addAnonymousImport("sizes.corpus", .{ .root_source_file = p.path("testdata/sizes.corpus") });
    size_module.addImport("captured", captured_module);
    const size_gate = b.addExecutable(.{ .name = "check-sizes", .root_module = size_module });
    const size_run = b.addRunArtifact(size_gate);
    size_run.setCwd(p.path("."));
    size_run.has_side_effects = true;
    b.step("check-sizes", "Check each level's total against the captured limit on every standard corpus").dependOn(&size_run.step);
    check.dependOn(&size_gate.step);
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier fuzzes every decoder entry, a campaign sized to
        // its job (ten thousand inputs a target outran twenty minutes),
        // and runs under ThreadSanitizer the tests whose work parallel
        // compression and decoding share between threads.
        .hardened = .{ .fuzz_step = "test", .tsan_step = "concurrent", .fuzz_iterations = 3000 },
        .bench = .{
            .programs = &.{
                .{ .name = "bench", .source = "bench/main.zig" },
                .{ .name = "zstd-bench", .source = "bench/zstd.zig" },
                .{ .name = "lz4-bench", .source = "bench/lz4.zig" },
                .{ .name = "brotli-bench", .source = "bench/brotli.zig" },
                .{ .name = "gdeflate-bench", .source = "bench/gdeflate.zig" },
                .{ .name = "bzip2-bench", .source = "bench/bzip2.zig" },
                .{ .name = "xz-bench", .source = "bench/xz.zig" },
                .{ .name = "snappy-bench", .source = "bench/snappy.zig" },
            },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on warp by path, with aegis alone to fetch:
    // the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "warp", .program = p.path("ci/consumer.zig"), .packages = &.{p.dependency("aegis", .{ .target = target, .optimize = optimize })} });
}

/// warp's one module. The checksum kernels that need instructions beyond the
/// target's baseline are modules of their own beneath it (`addKernelModules`).
fn warpModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const root = b.createModule(.{ .root_source_file = b.path("src/warp.zig"), .target = target, .optimize = optimize });
    addSourceImports(b, root, target, optimize);
    return root;
}

/// What warp's sources import: aegis, and the checksum kernels that need
/// instructions beyond the target's baseline, each a module of its own
/// built with those instructions enabled; warp calls one only where the CPU
/// has them (src/cpu.zig). Zig sets CPU features per module, so these are
/// the only modules that may use them: nothing else in warp can be compiled
/// into them.
/// What the tests read beside warp's sources: the differential corpus,
/// captured once from other implementations (pedronaugusto/trials, warp/),
/// the inputs it names, and the benchmarks' input generator.
fn addTestImports(b: *std.Build, p: *std.Build, module: *std.Build.Module) void {
    for ([_][]const u8{ "streams", "sizes", "invalid", "zstd-frames", "zstd-sizes", "zstd-invalid", "zstd-dictionaries", "deflate64", "lz4-blocks", "lz4-frames", "lz4-invalid", "brotli-streams", "brotli-invalid", "gdeflate", "bzip2-streams", "bzip2-invalid", "xz-streams", "xz-invalid", "bcj2", "snappy-blocks", "snappy-invalid", "snappy-streams", "snappy-stream-invalid" }) |name| {
        module.addAnonymousImport(b.fmt("{s}.corpus", .{name}), .{ .root_source_file = p.path(b.fmt("testdata/{s}.corpus", .{name})) });
    }
    module.addAnonymousImport("gen", .{ .root_source_file = p.path("bench/gen.zig") });
}

fn addSourceImports(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    module.addImport("aegis", b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
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
/// `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("warp", .{ .target = target, .optimize = optimize }).builder;
    const warp = warpModule(p, target, optimize);
    const gen = b.createModule(.{ .root_source_file = p.path("bench/gen.zig"), .target = target, .optimize = optimize });
    const ensign = b.dependency("ensign", .{ .target = target, .optimize = optimize }).module("ensign");
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "warp", .module = warp },
        .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "gen", .module = gen },
        .{ .name = "ensign", .module = ensign },
        .{ .name = "brotli-streams.corpus", .module = b.createModule(.{ .root_source_file = p.path("testdata/brotli-streams.corpus") }) },
        .{ .name = "bzip2-streams.corpus", .module = b.createModule(.{ .root_source_file = p.path("testdata/bzip2-streams.corpus") }) },
        .{ .name = "xz-streams.corpus", .module = b.createModule(.{ .root_source_file = p.path("testdata/xz-streams.corpus") }) },
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
    const output = run.addOutputFileArg2(options.name, .{});
    run.addArgs(&.{ @tagName(options.container), b.fmt("{d}", .{options.level}) });
    return output;
}
