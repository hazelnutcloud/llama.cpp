// Compatible with Zig Version 0.12.0-dev.xx
const std = @import("std");
const ArrayList = std.ArrayList;
const Compile = std.Build.Step.Compile;
const ConfigHeader = std.Build.Step.ConfigHeader;
const Mode = std.builtin.OptimizeMode;
const Target = std.Build.ResolvedTarget;

const Maker = struct {
    builder: *std.Build,
    target: Target,
    optimize: Mode,
    enable_lto: bool,
    build_all: bool,
    install_libs: bool,

    include_dirs: ArrayList([]const u8),
    cflags: ArrayList([]const u8),
    cxxflags: ArrayList([]const u8),
    objs: ArrayList(*Compile),

    fn addInclude(m: *Maker, dir: []const u8) !void {
        try m.include_dirs.append(dir);
    }
    fn addProjectInclude(m: *Maker, path: []const []const u8) !void {
        try m.addInclude(try m.builder.build_root.join(m.builder.allocator, path));
    }
    fn addCFlag(m: *Maker, flag: []const u8) !void {
        try m.cflags.append(flag);
    }
    fn addCxxFlag(m: *Maker, flag: []const u8) !void {
        try m.cxxflags.append(flag);
    }
    fn addFlag(m: *Maker, flag: []const u8) !void {
        try m.addCFlag(flag);
        try m.addCxxFlag(flag);
    }

    fn init(builder: *std.Build) !Maker {
        const target = builder.standardTargetOptions(.{});
        const zig_version = @import("builtin").zig_version_string;
        const commit_hash = try std.ChildProcess.run(
            .{ .allocator = builder.allocator, .argv = &.{ "git", "rev-parse", "HEAD" } },
        );
        try std.fs.cwd().writeFile("common/build-info.cpp", builder.fmt(
            \\int LLAMA_BUILD_NUMBER = {};
            \\char const *LLAMA_COMMIT = "{s}";
            \\char const *LLAMA_COMPILER = "Zig {s}";
            \\char const *LLAMA_BUILD_TARGET = "{s}";
            \\
        , .{ 0, commit_hash.stdout[0 .. commit_hash.stdout.len - 1], zig_version, try target.query.zigTriple(builder.allocator) }));

        var m = Maker{
            .builder = builder,
            .target = target,
            .optimize = builder.standardOptimizeOption(.{}),
            .enable_lto = false,
            .build_all = false,
            .install_libs = false,
            .include_dirs = ArrayList([]const u8).init(builder.allocator),
            .cflags = ArrayList([]const u8).init(builder.allocator),
            .cxxflags = ArrayList([]const u8).init(builder.allocator),
            .objs = ArrayList(*Compile).init(builder.allocator),
        };

        try m.addCFlag("-std=c11");
        try m.addCxxFlag("-std=c++11");

        if (m.target.result.abi == .gnu) {
            try m.addFlag("-D_GNU_SOURCE");
        }
        if (m.target.result.os.tag == .macos) {
            try m.addFlag("-D_DARWIN_C_SOURCE");
        }
        try m.addFlag("-D_XOPEN_SOURCE=600");

        try m.addProjectInclude(&.{});
        try m.addProjectInclude(&.{"common"});
        return m;
    }

    fn lib(m: *const Maker, name: []const u8, src: []const u8) *Compile {
        const o = m.builder.addStaticLibrary(.{ .name = name, .target = m.target, .optimize = m.optimize });

        if (std.mem.endsWith(u8, src, ".c") or std.mem.endsWith(u8, src, ".m")) {
            o.addCSourceFiles(.{ .files = &.{src}, .flags = m.cflags.items });
            o.linkLibC();
        } else {
            o.addCSourceFiles(.{ .files = &.{src}, .flags = m.cxxflags.items });
            if (m.target.result.abi == .msvc) {
                o.linkLibC(); // need winsdk + crt
            } else {
                // linkLibCpp already add (libc++ + libunwind + libc)
                o.linkLibCpp();
            }
        }
        for (m.include_dirs.items) |i| o.addIncludePath(.{ .path = i });
        o.want_lto = m.enable_lto;
        if (m.install_libs) m.builder.installArtifact(o);
        return o;
    }

    fn exe(m: *const Maker, name: []const u8, src: []const u8, deps: []const *Compile) ?*Compile {
        const opt = m.builder.option(bool, name, std.fmt.allocPrint(m.builder.allocator, "Build and install the {s} executable", .{name}) catch @panic("OOM")) orelse false;
        if (!opt and !m.build_all) return null;

        const e = m.builder.addExecutable(.{ .name = name, .target = m.target, .optimize = m.optimize });
        e.addCSourceFiles(.{ .files = &.{src}, .flags = m.cxxflags.items });
        for (deps) |d| e.linkLibrary(d);
        for (m.include_dirs.items) |i| e.addIncludePath(.{ .path = i });

        // https://github.com/ziglang/zig/issues/15448
        if (m.target.result.abi == .msvc) {
            e.linkLibC(); // need winsdk + crt
        } else {
            // linkLibCpp already add (libc++ + libunwind + libc)
            e.linkLibCpp();
        }
        m.builder.installArtifact(e);
        e.want_lto = m.enable_lto;
        return e;
    }
};

pub fn build(b: *std.Build) !void {
    var make = try Maker.init(b);
    make.enable_lto = b.option(bool, "lto", "Enable LTO optimization, (default: false)") orelse false;
    make.build_all = b.option(bool, "build-all", "Build all executables, (default: false)") orelse false;
    make.install_libs = b.option(bool, "install-libs", "Install all libraries, (default: false)") orelse false;

    // Options
    const llama_vulkan = b.option(bool, "llama-vulkan", "Enable Vulkan backend for Llama, (default: false)") orelse false;
    const llama_metal = b.option(bool, "llama-metal", "Enable Metal backend for Llama, (default: false, true for macos)") orelse (make.target.result.os.tag == .macos);
    const llama_no_accelerate = b.option(bool, "llama-no-accelerate", "Disable Accelerate framework for Llama, (default: false)") orelse false;
    const llama_accelerate = !llama_no_accelerate and make.target.result.os.tag == .macos;

    // Flags
    if (llama_accelerate) {
        try make.addFlag("-DGGML_USE_ACCELERATE");
        try make.addFlag("-DACCELERATE_USE_LAPACK");
        try make.addFlag("-DACCELERATE_LAPACK_ILP64");
    }

    // Libraries
    var extra_libs = ArrayList(*Compile).init(b.allocator);

    if (llama_vulkan) {
        try make.addFlag("-DGGML_USE_VULKAN");
        const ggml_vulkan = make.lib("ggml-vulkan", "ggml-vulkan.cpp");
        try extra_libs.append(ggml_vulkan);
    }

    if (llama_metal) {
        try make.addFlag("-DGGML_USE_METAL");
        const ggml_metal = make.lib("ggml-metal", "ggml-metal.m");
        try extra_libs.append(ggml_metal);
    }

    const ggml = make.lib("ggml", "ggml.c");
    const ggml_alloc = make.lib("ggml-alloc", "ggml-alloc.c");
    const ggml_backend = make.lib("ggml-backend", "ggml-backend.c");
    const ggml_quants = make.lib("ggml-quants", "ggml-quants.c");
    const llama = make.lib("llama", "llama.cpp");
    const buildinfo = make.lib("common", "common/build-info.cpp");
    const common = make.lib("common", "common/common.cpp");
    const console = make.lib("console", "common/console.cpp");
    const sampling = make.lib("sampling", "common/sampling.cpp");
    const grammar_parser = make.lib("grammar-parser", "common/grammar-parser.cpp");
    const clip = make.lib("clip", "examples/llava/clip.cpp");
    const train = make.lib("train", "common/train.cpp");

    // Executables
    const main = make.exe("main", "examples/main/main.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo, sampling, console, grammar_parser, clip });
    const quantize = make.exe("quantize", "examples/quantize/quantize.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo });
    const perplexity = make.exe("perplexity", "examples/perplexity/perplexity.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo });
    const embedding = make.exe("embedding", "examples/embedding/embedding.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo });
    const finetune = make.exe("finetune", "examples/finetune/finetune.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo, train });
    const train_text_from_scratch = make.exe("train-text-from-scratch", "examples/train-text-from-scratch/train-text-from-scratch.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo, train });
    const server = make.exe("server", "examples/server/server.cpp", &.{ ggml, ggml_alloc, ggml_backend, ggml_quants, llama, common, buildinfo, sampling, console, grammar_parser, clip });
    if (make.target.result.os.tag == .windows and server != null) {
        server.?.linkSystemLibrary("ws2_32");
    }

    const exes = [_]?*Compile{ main, server, quantize, perplexity, embedding, finetune, train_text_from_scratch };

    for (exes) |e| {
        if (e == null) continue;
        for (extra_libs.items) |o| e.?.addObject(o);

        if (llama_vulkan) {
            e.?.linkSystemLibrary("vulkan");
        }

        if (llama_metal) {
            e.?.linkFramework("Foundation");
            e.?.linkFramework("Metal");
            e.?.linkFramework("MetalKit");
        }

        if (llama_accelerate) {
            e.?.linkFramework("Accelerate");
        }
    }
}
