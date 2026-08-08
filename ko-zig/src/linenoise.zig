pub extern fn linenoise(prompt: [*:0]const u8) ?[*:0]u8;
pub extern fn linenoiseFree(ptr: ?*anyopaque) void;
pub extern fn linenoiseHistoryAdd(line: [*:0]const u8) c_int;
pub extern fn linenoiseHistorySetMaxLen(len: c_int) c_int;
pub extern fn linenoiseHistorySave(filename: [*:0]const u8) c_int;
pub extern fn linenoiseHistoryLoad(filename: [*:0]const u8) c_int;
pub extern fn linenoiseSetMultiLine(ml: c_int) void;
pub extern fn linenoiseSetCompletionCallback(cb: CompletionCallback) void;
pub extern fn linenoiseAddCompletion(completions: *Completions, str: [*:0]const u8) void;
pub extern fn linenoiseClearScreen() void;

pub const Completions = extern struct {
    len: usize,
    cvec: [*c][*c]u8,
};

pub const CompletionCallback = *const fn ([*:0]const u8, *Completions) callconv(.c) void;

pub fn historyAdd(line: [*:0]const u8) c_int {
    return linenoiseHistoryAdd(line);
}

pub fn historySetMaxLen(len: c_int) c_int {
    return linenoiseHistorySetMaxLen(len);
}

pub fn historySave(filename: [*:0]const u8) c_int {
    return linenoiseHistorySave(filename);
}

pub fn historyLoad(filename: [*:0]const u8) c_int {
    return linenoiseHistoryLoad(filename);
}

pub fn setMultiLine(ml: c_int) void {
    linenoiseSetMultiLine(ml);
}

pub fn setCompletionCallback(cb: CompletionCallback) void {
    linenoiseSetCompletionCallback(cb);
}

pub fn addCompletion(completions: *Completions, str: [*:0]const u8) void {
    linenoiseAddCompletion(completions, str);
}

pub fn clearScreen() void {
    linenoiseClearScreen();
}
