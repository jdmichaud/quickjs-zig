const std = @import("std");
const Io = std.Io;

const PortableAddCSourceFilesOptions = if (@hasDecl(std.Build.Module, "AddCSourceFilesOptions"))
    std.Build.Module.AddCSourceFilesOptions else std.Build.Step.Compile.AddCSourceFilesOptions;

pub fn portableAddCSourceFiles(c: *std.Build.Step.Compile, options: PortableAddCSourceFilesOptions) void {
    if (@hasDecl(std.Build.Step.Compile, "addCSourceFiles")) {
        c.addCSourceFiles(options);
    } else {
        c.root_module.addCSourceFiles(options);
    }
}

pub fn portableLinkSystemLibrary(c: *std.Build.Step.Compile, name: []const u8) void {
    if (@hasDecl(std.Build.Step.Compile, "linkSystemLibrary")) {
        c.linkSystemLibrary(name);
    } else {
        c.root_module.linkSystemLibrary(name, .{});
    }
}

pub fn portableLinkLibC(c: *std.Build.Step.Compile) void {
    if (@hasDecl(std.Build.Step.Compile, "linkLibC")) {
        c.linkLibC();
    } else {
        c.root_module.link_libc = true;
    }
}

pub fn portableLinkLibrary(c: *std.Build.Step.Compile, library: *std.Build.Step.Compile) void {
    if (@hasDecl(std.Build.Step.Compile, "linkLibrary")) {
        c.linkLibrary(library);
    } else {
        c.root_module.linkLibrary(library);
    }
}

fn addDefines(c: *std.Build.Step.Compile, b: *std.Build, version: []const u8) void {
    c.root_module.addCMacro("CONFIG_BIGNUM", "1");
    c.root_module.addCMacro("_GNU_SOURCE", "1");
    var buf: [256]u8 = undefined;
    const version_str = std.fmt.bufPrint(&buf, "\"{s}\"", .{ version })
        catch @panic("could not format version");
    c.root_module.addCMacro("CONFIG_VERSION", version_str);
    _ = b;
}

fn addStdLib(c: *std.Build.Step.Compile, cflags: []const []const u8, root: *std.Build.Dependency) void {
    if (c.rootModuleTarget().os.tag == .wasi) {
        c.root_module.addCMacro("_WASI_EMULATED_PROCESS_CLOCKS", "1");
        c.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        portableLinkSystemLibrary(c, "wasi-emulated-process-clocks");
        portableLinkSystemLibrary(c, "wasi-emulated-signal");
    }
    portableAddCSourceFiles(c, .{ .files = &.{"quickjs-libc.c"}, .flags = cflags, .root = root.path(".") });
}

var buffer: [256]u8 = undefined;

pub fn getVersion(b: *std.Build, csrc: *std.Build.Dependency) []const u8 {
    const version_path = csrc.path("VERSION").getPath(b);
    var file = std.fs.cwd().openFile(version_path, .{})
        catch @panic("fail to read VERSION file");
    defer file.close();

    const reader = file.reader();

    const first_line = reader.readUntilDelimiterOrEofAlloc(
        b.allocator,
        '\n',
        128,
    ) catch @panic("fail to read VERSION file");

    if (first_line) |_| {} else {
        @panic("fail to read VERSION file");
    }

    return first_line.?;
}

pub fn getVersionIo(b: *std.Build, csrc: *std.Build.Dependency) []const u8 {
    var threaded: std.Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const version_path = csrc.path("VERSION").getPath(b);
    var file = std.Io.Dir.cwd().openFile(io, version_path, .{})
        catch @panic("fail to read VERSION file");
    defer file.close(io);

    var reader = file.reader(io, &buffer);

    const first_line = reader.interface.takeDelimiterExclusive('\n')
        catch @panic("fail to read VERSION file");

    return first_line;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const include_stdlib = b.option(bool, "stdlib", "include stdlib in library") orelse true;

    const csrc = b.dependency("quickjs", .{});

    const version = if (@hasDecl(std, "Io")) getVersionIo(b, csrc) else getVersion(b, csrc);
    defer b.allocator.free(version);

    const cflags = &.{
        "-Wno-implicit-fallthrough",
        "-Wno-sign-compare",
        "-Wno-missing-field-initializers",
        "-Wno-unused-parameter",
        "-Wno-unused-but-set-variable",
        "-Wno-array-bounds",
        "-Wno-format-truncation",
        "-funsigned-char",
        "-fwrapv",
    };

    const libquickjs_source = &.{
        "quickjs.c",
        "libregexp.c",
        "libunicode.c",
        "cutils.c",
        "dtoa.c",
    };

    const libquickjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    portableAddCSourceFiles(libquickjs, .{
        .files = libquickjs_source,
        .flags = cflags,
        .root = csrc.path("."),
    });
    addDefines(libquickjs, b, version);
    if (include_stdlib) {
        addStdLib(libquickjs, cflags, csrc);
    }
    portableLinkLibC(libquickjs);
    if (target.result.os.tag == .windows) {
        libquickjs.stack_size = 0xF00000;
    }
    b.installArtifact(libquickjs);

    const qjsc = b.addExecutable(.{
        .name = "qjsc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    portableAddCSourceFiles(qjsc, .{
        .files = &.{"qjsc.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    portableLinkLibrary(qjsc, libquickjs);
    addDefines(qjsc, b, version);
    if (!include_stdlib) {
        addStdLib(qjsc, cflags, csrc);
    }
    b.installArtifact(qjsc);

    const qjsc_host = b.addExecutable(.{
        .name = "qjsc-host",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    if (b.graph.host.result.os.tag == .windows) {
        qjsc_host.stack_size = 0xF00000;
    }

    portableAddCSourceFiles(qjsc_host, .{
        .files = &.{"qjsc.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    portableAddCSourceFiles(qjsc_host, .{
        .files = libquickjs_source,
        .flags = cflags,
        .root = csrc.path("."),
    });
    addStdLib(qjsc_host, cflags, csrc);
    addDefines(qjsc_host, b, version);
    portableLinkLibC(qjsc_host);

    const header = b.addTranslateC(.{
        .root_source_file = csrc.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });
    _ = b.addModule("quickjs", .{ .root_source_file = header.getOutput() });

    const gen_repl = b.addRunArtifact(qjsc_host);
    gen_repl.addArg("-s");
    gen_repl.addArg("-c");
    gen_repl.addArg("-o");
    const gen_repl_out = gen_repl.addOutputFileArg("repl.c");
    gen_repl.addArg("-m");
    gen_repl.addFileArg(csrc.path("repl.js"));

    const qjs = b.addExecutable(.{
        .name = "qjs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    qjs.root_module.addCMacro("CONFIG_VERSION", "1.0.0");
    portableAddCSourceFiles(qjs, .{
        .files = &.{"qjs.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    portableAddCSourceFiles(qjs, .{
        .files = &.{"repl.c"},
        .root = gen_repl_out.dirname(),
        .flags = cflags,
    });
    if (!include_stdlib) {
        addStdLib(qjs, cflags, csrc);
    }
    portableLinkLibrary(qjs, libquickjs);
    addDefines(qjs, b, version);
    qjs.step.dependOn(&gen_repl.step);
    b.installArtifact(qjs);
}
