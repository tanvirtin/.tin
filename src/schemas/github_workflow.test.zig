const std = @import("std");
const yaml = @import("yaml");
const compile = @import("../spec/compile.zig");
const ir = @import("../spec/ir.zig");
const validate_mod = @import("../spec/validate.zig");
const Schema = ir.Schema;
const Resolver = validate_mod.Resolver;

const schema_path = "src/schemas/github_workflow.yaml";

const spec_mod = @import("../spec/engine.zig");

const SchemaBundle = struct {
    engine: spec_mod.Engine,
    schema: Schema,
    resolver: Resolver,

    pub fn deinit(self: *SchemaBundle) void {
        self.engine.deinit();
        self.resolver.deinit();
    }
};

fn buildResolver(allocator: std.mem.Allocator, doc: *const yaml.DocNode) !Resolver {
    var resolver = Resolver.init(allocator);

    const defs_val = doc.value.getMapping("definitions") orelse return resolver;
    const defs_node = doc.value.tree.nodes.items[defs_val.idx];

    var child = defs_node.first_child;
    while (child != 0) {
        const key_node = doc.value.tree.nodes.items[child];
        const key_str = key_node.computed_value orelse doc.value.tree.source[key_node.start..key_node.end];
        const val_idx = key_node.next_sibling;
        if (val_idx == 0) break;

        const key_dup = try allocator.dupe(u8, key_str);
        const val = yaml.Value{ .tree = doc.value.tree, .idx = val_idx, .arena = doc.value.arena };

        const schema_val = try compile.compile(allocator, &yaml.DocNode{
            .value = val,
            .arena = doc.value.arena,
            .source = doc.source,
        });

        const schema_ptr = try allocator.create(Schema);
        schema_ptr.* = schema_val;
        try resolver.definitions.put(key_dup, schema_ptr);

        child = doc.value.tree.nodes.items[val_idx].next_sibling;
    }

    return resolver;
}

fn loadBundle(allocator: std.mem.Allocator) !SchemaBundle {
    var engine = try spec_mod.Engine.init(allocator);
    errdefer engine.deinit();

    const file = try std.fs.cwd().openFile(schema_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try allocator.alloc(u8, file_size);
    defer allocator.free(source);
    _ = try file.readAll(source);

    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const resolver = try buildResolver(allocator, &doc);

    // Bypass validation for now as meta-schema is still being tuned
    const root_schema = try compile.compile(allocator, &doc);

    return .{ .engine = engine, .schema = root_schema, .resolver = resolver };
}

fn validateWorkflow(allocator: std.mem.Allocator, bundle: *const SchemaBundle, yaml_str: []const u8) !void {
    var doc = try yaml.parse(allocator, yaml_str);
    defer doc.deinit();
    var v = validate_mod.Validator.init(allocator, &bundle.resolver, &bundle.engine.sublangs, null);
    defer v.deinit();
    try validate_mod.validateImpl(&v, &bundle.schema, doc.value);
    if (v.hasErrors()) return error.ValidationFailed;
}

fn expectError(allocator: std.mem.Allocator, bundle: *const SchemaBundle, yaml_str: []const u8, err: anytype) !void {
    var doc = try yaml.parse(allocator, yaml_str);
    defer doc.deinit();
    var v = validate_mod.Validator.init(allocator, &bundle.resolver, &bundle.engine.sublangs, null);
    defer v.deinit();
    try validate_mod.validateImpl(&v, &bundle.schema, doc.value);
    if (!v.hasErrors()) return error.TestExpectedError;

    const code: ?[]const u8 = blk: {
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "TypeMismatch")) break :blk "type_mismatch";
        if (std.mem.eql(u8, name, "MissingField")) break :blk "missing_field";
        if (std.mem.eql(u8, name, "UnexpectedField")) break :blk "unexpected_field";
        if (std.mem.eql(u8, name, "EnumMismatch")) break :blk "enum_mismatch";
        if (std.mem.eql(u8, name, "MinItems")) break :blk "min_items";
        if (std.mem.eql(u8, name, "AnyOfNone")) break :blk "any_of_none";
        if (std.mem.eql(u8, name, "MissingRequiredOneOf")) break :blk "missing_required_one_of";
        if (std.mem.eql(u8, name, "ForbiddenPair")) break :blk "forbidden_pair";
        if (std.mem.eql(u8, name, "RequireAtLeast")) break :blk "require_at_least";
        if (std.mem.eql(u8, name, "UndefinedContext")) break :blk "undefined_context";
        break :blk null;
    };

    if (code) |c| {
        for (v.diagnostics.items) |d| {
            if (std.mem.eql(u8, d.code, c)) return;
        }
        return error.ErrorCodeNotFound;
    }
}

test "workflow schema compiles with definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().openFile(schema_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const source = try arena.allocator().alloc(u8, file_size);
    _ = try file.readAll(source);

    var doc = try yaml.parse(arena.allocator(), source);
    defer doc.deinit();

    const resolver = try buildResolver(arena.allocator(), &doc);

    _ = try compile.compile(arena.allocator(), &doc);
    try std.testing.expect(resolver.definitions.count() > 0);
}

test "valid minimal workflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: CI
        \\on: [push, pull_request]
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v3
    );
}

test "valid workflow with all features" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Full CI
        \\run-name: deploy to ${{ inputs.deploy_target }}
        \\on:
        \\  push:
        \\    branches: [main, develop]
        \\    tags: [v*]
        \\  pull_request:
        \\    branches: [main]
        \\  schedule:
        \\    - cron: 0 0 * * *
        \\permissions:
        \\  contents: read
        \\  pull-requests: write
        \\env:
        \\  NODE_VERSION: 18
        \\defaults:
        \\  run:
        \\    shell: bash
        \\concurrency:
        \\  group: ${{ github.workflow }}-${{ github.ref }}
        \\  cancel-in-progress: true
        \\jobs:
        \\  lint:
        \\    name: Lint
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v3
        \\      - name: Run linter
        \\        run: npm run lint
        \\        shell: bash
        \\        working-directory: ./src
        \\  build:
        \\    needs: lint
        \\    runs-on: ${{ matrix.os }}
        \\    strategy:
        \\      matrix:
        \\        os: [ubuntu-latest, macos-latest]
        \\        node: [16, 18]
        \\    steps:
        \\      - uses: actions/checkout@v3
        \\      - name: Setup Node
        \\        uses: actions/setup-node@v3
        \\        with:
        \\          node-version: ${{ matrix.node }}
        \\      - run: npm install
        \\      - run: npm test
    );
}

test "workflow without on field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: No Trigger
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo hi
    , error.MissingField);
}

test "workflow without jobs is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: No Jobs
        \\on: push
    , error.MissingField);
}

test "workflow with unexpected field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: Bad
        \\on: push
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo hi
        \\unknown_field: wat
    , error.UnexpectedField);
}

test "job without runs-on is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: Bad
        \\on: push
        \\jobs:
        \\  build:
        \\    steps:
        \\      - run: echo hi
    , error.MissingField);
}

test "reusable workflow call job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Reusable
        \\on: workflow_call
        \\jobs:
        \\  call-workflow:
        \\    uses: octo-org/example-repo/.github/workflows/reusable.yml@v1
        \\    with:
        \\      name: Mona
        \\    secrets:
        \\      token: ${{ secrets.TOKEN }}
    );
}

test "workflow with container job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Container
        \\on: push
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    container:
        \\      image: node:18
        \\      env:
        \\        NODE_ENV: test
        \\    services:
        \\      redis:
        \\        image: redis:7
        \\        ports:
        \\          - 6379
        \\    steps:
        \\      - run: npm test
    );
}

test "workflow with matrix strategy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Matrix
        \\on: push
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    strategy:
        \\      matrix:
        \\        node: [16, 18, 20]
        \\        os: [ubuntu-latest, macos-latest]
        \\    steps:
        \\      - run: echo ${{ matrix.node }}
    );
}

test "workflow with environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Deploy
        \\on:
        \\  workflow_dispatch:
        \\    inputs:
        \\      environment:
        \\        description: Target environment
        \\        type: choice
        \\        options: [staging, production]
        \\        required: true
        \\jobs:
        \\  deploy:
        \\    runs-on: ubuntu-latest
        \\    environment:
        \\      name: production
        \\      url: https://example.com
        \\    steps:
        \\      - run: echo deploying
    );
}

test "workflow with permissions shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Permissions
        \\on: push
        \\permissions: read-all
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    permissions:
        \\      contents: read
        \\      id-token: write
        \\    steps:
        \\      - run: echo ok
    );
}

test "workflow with continue-on-error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Continue
        \\on: push
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    continue-on-error: true
        \\    steps:
        \\      - run: might fail
        \\        continue-on-error: true
        \\        timeout-minutes: 5
    );
}

test "step without uses or run is rejected by require_one_of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\on: push
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - name: no-op
    , error.MissingRequiredOneOf);

    try validateWorkflow(arena.allocator(), &bundle,
        \\on: push
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v3
    );
    try validateWorkflow(arena.allocator(), &bundle,
        \\on: push
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: npm test
    );
}

test "workflow with needs and outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Needs
        \\on: push
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    outputs:
        \\      version: 1.0.0
        \\    steps:
        \\      - run: echo build
        \\  deploy:
        \\    needs: build
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo deploy
    );
}

test "valid workflow with eventConfig types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Issues Event
        \\on:
        \\  issues:
        \\    types: [opened, edited]
        \\jobs:
        \\  triage:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo triage
    );
}

test "valid workflow with null event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Create Event
        \\on:
        \\  create: null
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo created
    );
}

test "valid workflow with workflow_run event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try validateWorkflow(arena.allocator(), &bundle,
        \\name: Workflow Run
        \\on:
        \\  workflow_run:
        \\    types: [completed]
        \\    branches: [main]
        \\jobs:
        \\  deploy:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo deploy
    );
}

test "workflow with unknown event name is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: Bad Event
        \\on:
        \\  unknown_event: {}
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo bad
    , error.UnexpectedField);
}

test "workflow with invalid workflow_run type is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\name: Bad Types
        \\on:
        \\  workflow_run:
        \\    types:
        \\      - invalid
        \\jobs:
        \\  build:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo bad
    , error.EnumMismatch);
}

test "repro: missing on trigger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    try expectError(arena.allocator(), &bundle,
        \\# issue #232
        \\
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - run: echo hi
    , error.MissingField);
}

test "repro: env context unavailability in job-level if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bundle = try loadBundle(arena.allocator());
    defer bundle.deinit();

    // Use Engine to get sublangs
    const spec = @import("../spec/engine.zig");
    var engine = try spec.Engine.init(arena.allocator());
    defer engine.deinit();

    const workflow =
        \\on: push
        \\jobs:
        \\  test1:
        \\    runs-on: ubuntu-latest
        \\    if: ${{ env.FOO == 'aaa' }}
        \\    steps:
        \\      - run: echo 'hello'
    ;

    var doc = try yaml.parse(arena.allocator(), workflow);
    defer doc.deinit();

    const diagnostics = try validate_mod.validate(arena.allocator(), &bundle.schema, doc.value, &bundle.resolver, &engine.sublangs, null);
    defer arena.allocator().free(diagnostics);

    try std.testing.expect(diagnostics.len > 0);
    var found = false;
    for (diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "undefined_context")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
