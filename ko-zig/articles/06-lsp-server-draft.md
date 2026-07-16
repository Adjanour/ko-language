# Building an LSP Server Without Dependencies

An editor without language support is like a car without headlights. You can drive, but you're going to hit something eventually. Syntax highlighting helps, but it's not enough. You need hover information to see types. You need completion to discover APIs. You need diagnostics to catch errors before you run the code.

The Language Server Protocol (LSP) is the standard for editor integration. VS Code, Vim, Emacs, and dozens of other editors support it. If you build an LSP server, your language works in all of them.

Kō has an LSP server. It provides hover, completion, and diagnostics. It's written in Zig with no external dependencies. No LLVM, no standard library I/O, no third-party packages. Just raw Linux syscalls for reading and writing.

This was a deliberate choice. The LSP server needs to be fast, small, and portable. LLVM is large and slow to compile. The standard library's I/O doesn't work well with subprocess pipes. Third-party packages add complexity. Raw syscalls are simple and reliable.

---

The LSP protocol is JSON-RPC over stdio. The client sends requests, the server responds. The client sends notifications, the server processes them. It's straightforward, but the details are fiddly.

The key methods are `initialize`, `textDocument/didOpen`, `textDocument/hover`, `textDocument/completion`, and `textDocument/definition`. Each has a specific request format and response format.

`initialize` is the handshake. The client tells the server what capabilities it supports. The server responds with its capabilities.

`textDocument/didOpen` is a notification. The client sends the full text of a file. The server parses it, typechecks it, and stores the results.

`textDocument/hover` is a request. The client sends a position (line and character). The server finds the identifier at that position and returns its type.

`textDocument/completion` is a request. The client sends a position. The server finds all identifiers that match the partial input and returns them.

`textDocument/definition` is a request. The client sends a position. The server finds where the identifier at that position is defined and returns the location.

---

The I/O is the tricky part. LSP uses JSON-RPC over stdio. The server reads from stdin and writes to stdout. The Zig standard library's `Io` doesn't work well with subprocess pipes. `Io.File.Reader` uses `sendFile` for streaming, which returns 0 on pipes. The `Io.Reader` interface doesn't properly delegate to the file for pipe reads.

The solution is raw Linux syscalls. For reads, use `std.posix.read()`. For writes, use `linux.write` on Linux and `std.c.write` on macOS.

The read pattern:

```zig
fn rawRead(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
        return switch (e) {
            .INTR => rawRead(fd, buf),  // retry on interrupt
            else => error.ReadFailed,
        };
    }
    if (rc == 0) return error.EndOfStream;
    return @intCast(rc);
}
```

The write pattern:

```zig
fn writeAll(fd: i32, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = if (comptime @import("builtin").os.tag == .linux)
            linux.write(fd, data[pos..].ptr, data.len - pos)
        else
            std.c.write(fd, data[pos..].ptr, data.len - pos);
        if (rc < 0) {
            const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
            switch (e) {
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        pos += @intCast(rc);
    }
}
```

It's verbose, but it works. No dependencies, no magic, just syscalls.

---

The header parsing is where most LSP servers get tripped up. LSP messages have a header: `Content-Length: N\r\n\r\n` followed by N bytes of JSON. The server must read the header, extract the content length, then read exactly that many bytes.

The gotcha is the `\r\n`. LSP uses CRLF line endings. The header parser must handle both `\n` and `\r\n`. If you don't strip the `\r`, the content length extraction fails.

Another gotcha: don't increment `line_len` when you break on `\n`. The original code did `line_len += 1; break;` which included the `\n` in the returned line. This caused empty lines to be returned as `"\r\n"` instead of `""`. The fix is to break without incrementing.

```zig
fn readLine(fd: i32, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.EndOfStream) return error.ConnectionClosed;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        if (line_buf[line_len] == '\n') break;
        line_len += n;
    }
    const end = if (line_len > 0 and line_buf[line_len - 1] == '\r') line_len - 1 else line_len;
    return line_buf[0..end];
}
```

It's fiddly, but it works.

---

Hover is the most useful feature. When you hover over an identifier, the editor shows its type. This is invaluable for understanding code.

The implementation: find the document in the store, parse the source to find the identifier at the position, look up the type in the type environment, format the type as markdown, return the response.

Type pretty-printing is the hard part. Kō's typechecker stores types as internal data structures, not strings. The LSP server must convert them to human-readable strings.

The conversion handles: Int, Float, Bool, String, Char, Unit (written as `()`), arrow types (auto-parenthesized: `(Int -> Int) -> Int`), tuples, constructors, records, refs. Type variables get friendly names (a, b, c) based on their position in the quantified list.

The result is a hover response like:

```json
{
  "contents": {
    "kind": "markdown",
    "value": "**add** : `Int -> Int -> Int`\n\nAdds two integers"
  }
}
```

It's simple, but it works.

---

Completion is the second most useful feature. When you type a partial identifier, the editor suggests completions. This is invaluable for discovering APIs.

The implementation: find the document in the store, get the partial identifier at the position, search the type environment for matching names, format each match as a completion item, return the response.

The partial identifier is the text from the start of the identifier to the cursor position. If the cursor is in the middle of an identifier, you only match the prefix. If the cursor is after the identifier, you match the full name.

The completion items include the label (the name), the kind (function, variable, constructor), the detail (the type), and documentation (if available).

The result is a completion response like:

```json
{
  "items": [
    {
      "label": "add",
      "kind": 3,
      "detail": "Int -> Int -> Int"
    },
    {
      "label": "head",
      "kind": 3,
      "detail": "List a -> a"
    }
  ]
}
```

It's simple, but it works.

---

Diagnostics are the third most useful feature. When you open a file, the editor shows errors and warnings. This is invaluable for catching mistakes early.

The implementation: parse the source code, typecheck the AST, collect all errors, format each error as a diagnostic, send the notification.

The diagnostics include the range (start and end positions), the severity (error, warning, info), and the message (the error description).

The result is a diagnostic notification like:

```json
{
  "method": "textDocument/publishDiagnostics",
  "params": {
    "uri": "file:///path/to/file.ko",
    "diagnostics": [
      {
        "range": {
          "start": { "line": 5, "character": 10 },
          "end": { "line": 5, "character": 15 }
        },
        "severity": 1,
        "message": "Expected Int, got String"
      }
    ]
  }
}
```

It's simple, but it works.

---

The main loop is straightforward. Read a message, parse it, handle it, respond.

```zig
while (true) {
    const content_length = readContentLength() catch |err| {
        if (err == error.ConnectionClosed) break;
        return err;
    };
    const message = readMessage(content_length);
    const parsed = try std.json.parseFromSlice(Message, allocator, message, .{});
    defer parsed.deinit();
    switch (parsed.method) {
        "initialize" => try handleInitialize(parsed.params),
        "textDocument/didOpen" => try handleDidOpen(&store, parsed.params),
        "textDocument/hover" => try handleHover(&store, parsed.params),
        "textDocument/completion" => try handleCompletion(&store, parsed.params),
        "textDocument/definition" => try handleDefinition(&store, parsed.params),
        "shutdown" => break,
        else => {},
    }
}
```

It's simple. It works. It's about 1,000 lines of Zig.

---

The document store is the core data structure. It maps URIs to documents. Each document has the URI, the text, the parsed AST, the type information, and any errors.

When a file is opened, the document is parsed and typechecked. The results are stored. When hover or completion is requested, the stored results are used. When the file is changed, it's reparsed and retypechecked.

The store is a hash map. Lookups are O(1). The implementation is straightforward.

---

The VS Code extension ties it all together. It has a TextMate grammar for syntax highlighting and an LSP client for language server communication.

The TextMate grammar defines patterns for keywords, types, constructors, strings, numbers, and comments. VS Code uses these patterns to highlight the source code.

The LSP client launches the `ko-lsp` subprocess and communicates with it over stdio. It sends requests when you hover, type, or open files. It receives responses with types, completions, and diagnostics.

The extension is about 200 lines of JSON and TypeScript. It's simple, but it works.

---

Performance matters for LSP. Hover, completion, and diagnostics must be instant. If they're slow, the editor feels sluggish.

Kō's LSP server is fast. The parser is about 100ms for typical files. The typechecker is about 50ms. Total: about 150ms per keystroke. This is acceptable for LSP — users don't notice delays under 200ms.

The main bottleneck is parsing. Every keystroke triggers a reparse. Incremental parsing would help, but it's not implemented yet. For now, full reparse is fast enough.

The typechecker is incremental in practice — it only retypechecks the changed parts. But the implementation does a full retypecheck. This is a future optimization.

---

I learned a lot building the LSP server. Some of it was technical, some of it was about the process.

Raw syscalls work, but they're tedious. Every read and write is a potential error. The error handling is explicit and verbose. But it's reliable. No hidden I/O, no hidden buffering, no hidden behavior.

JSON parsing in Zig is straightforward. The standard library's JSON parser handles the LSP protocol messages. The only gotcha is memory management — JSON slices are temporary and must be copied if you need them later.

The LSP protocol is well-documented but complex. There are many methods, many parameters, many response formats. The spec is clear, but it takes time to understand. The best approach is to implement one method at a time, starting with hover.

Error handling is critical. The server must never crash. If a request fails, the server must return an error response and continue. If the client disconnects, the server must exit cleanly. If the file is malformed, the server must report diagnostics and continue.

Testing with VS Code is invaluable. You can't test an LSP server without an editor. VS Code's output panel shows the JSON-RPC messages. The debugger shows the server's state. The extension host provides a realistic environment.

---

The LSP server is about 1,000 lines of Zig. It provides hover, completion, and diagnostics. It uses raw syscalls for I/O. It has no external dependencies.

It's not perfect. Incremental parsing would make it faster. Go-to-definition would make it more useful. Refactoring support would make it a full IDE. But for a first implementation, it works.

The LSP server is the most visible part of Kō's tooling. When you hover over an identifier and see its type, you're using the LSP server. When you type and see completions, you're using the LSP server. When you open a file and see errors, you're using the LSP server.

It's simple. It works. And it makes Kō usable.

---

*Kō (光) means "light" in Japanese. The LSP server is how Kō illuminates your code — showing you types, catching errors, and suggesting completions.*
