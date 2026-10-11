const std = @import("std");

pub fn main() !void {
    // #region listen
    const address = try std.net.Address.parseIp("127.0.0.1", 4000);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    // #endregion listen

    // #region accept
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();
        try conn.stream.writeAll("HTTP/1.1 200 OK\r\n\r\nhello\n");
    }
    // #endregion accept
}
