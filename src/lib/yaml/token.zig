pub const TokenTag = enum {
    stream_start,
    stream_end,
    document_start,
    document_end,
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    flow_entry,
    block_entry,
    key_token,
    value_token,
    scalar,
    alias,
    anchor,
    tag,
};

pub const ScalarStyle = enum { plain, single_quoted, double_quoted, literal, folded };

pub const Token = struct {
    tag: TokenTag,
    value: ?[]const u8 = null,
    style: ScalarStyle = .plain,
};
