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

pub const SourceMap = struct {
    entries: []const Entry,

    pub const Entry = struct {
        parsed: u32,
        source: u32,
    };

    pub fn map(self: SourceMap, offset: u32) u32 {
        if (self.entries.len == 0) return offset;
        
        var low: usize = 0;
        var high: usize = self.entries.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.entries[mid].parsed <= offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low == 0) return self.entries[0].source + offset;
        const entry = self.entries[low - 1];
        return entry.source + (offset - entry.parsed);
    }
};

pub const Token = struct {
    tag: TokenTag,
    value: ?[]const u8 = null,
    start: u32 = 0,
    end: u32 = 0,
    style: ScalarStyle = .plain,
    source_map: ?SourceMap = null,
};
