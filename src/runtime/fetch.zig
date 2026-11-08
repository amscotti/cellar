const std = @import("std");
const vm = @import("../vm/vm.zig");

/// Outbound fetch policy, built once from `Config` by the scheduler and
/// handed to the pool threads. See `docs/BINDINGS.md` for the operator view.
pub const FetchPolicy = struct {
    allow_private: bool = false,
    allow_hosts: []const []const u8 = &.{},

    pub const default: FetchPolicy = .{};
};

pub const PolicyError = error{FetchBlocked};

/// Validate a guest-supplied URL against `policy`.
///
/// This is a URL-literal check only: it cannot see DNS answers, so a
/// hostname that *resolves* to a private address (rebinding) is not caught
/// here. What it does stop is the direct case — a guest asking for
/// `http://169.254.169.254/`, `http://127.0.0.1:2379/` or an RFC1918
/// address — plus non-HTTP schemes and credential-bearing URLs.
/// Redirects are not followed (see `fetchHttpWithPolicy`), so a public
/// URL cannot bounce the pool onto a private one either.
pub fn validateFetchUrl(url: []const u8, policy: FetchPolicy) PolicyError!void {
    const uri = std.Uri.parse(url) catch return error.FetchBlocked;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return error.FetchBlocked;
    // Credentials in the URL end up in logs and confuse the host check.
    if (uri.user != null or uri.password != null) return error.FetchBlocked;
    const host_comp = uri.host orelse return error.FetchBlocked;
    var hbuf: [512]u8 = undefined;
    const raw_host = host_comp.toRaw(&hbuf) catch return error.FetchBlocked;
    if (raw_host.len == 0) return error.FetchBlocked;

    // Normalise: lower-case into a stack buffer, strip IPv6 brackets and a
    // trailing root dot (`example.com.` is the same host).
    var lbuf: [512]u8 = undefined;
    if (raw_host.len > lbuf.len) return error.FetchBlocked;
    var host: []u8 = lbuf[0..raw_host.len];
    for (raw_host, 0..) |ch, i| host[i] = std.ascii.toLower(ch);
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host = host[1 .. host.len - 1];
    if (host.len > 0 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0) return error.FetchBlocked;

    if (!policy.allow_private) {
        if (isPrivateHost(host)) return error.FetchBlocked;
    }
    if (policy.allow_hosts.len > 0 and !hostAllowed(host, policy.allow_hosts))
        return error.FetchBlocked;
}

fn hostAllowed(host: []const u8, allow_hosts: []const []const u8) bool {
    for (allow_hosts) |entry_raw| {
        // Entries are operator-supplied; compare case-insensitively.
        var ebuf: [512]u8 = undefined;
        if (entry_raw.len > ebuf.len) continue;
        var entry = ebuf[0..entry_raw.len];
        for (entry_raw, 0..) |ch, i| entry[i] = std.ascii.toLower(ch);
        if (entry.len > 0 and entry[entry.len - 1] == '.') entry = entry[0 .. entry.len - 1];
        if (std.mem.startsWith(u8, entry, "*.")) {
            const suffix = entry[2..];
            if (suffix.len == 0) continue;
            // `*.example.com` matches `a.example.com` but not `example.com`
            // or `badexample.com`: require a label boundary.
            if (host.len > suffix.len + 1 and host[host.len - suffix.len - 1] == '.' and
                std.mem.eql(u8, host[host.len - suffix.len ..], suffix)) return true;
        } else if (std.mem.eql(u8, host, entry)) {
            return true;
        }
    }
    return false;
}

fn isPrivateHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost") or
        std.mem.endsWith(u8, host, ".localhost") or
        std.mem.eql(u8, host, "metadata.google.internal") or
        std.mem.eql(u8, host, "metadata.google"))
        return true;

    // Ambiguous numeric forms (`2130706433`, `0x7f000001`, `0177.0.0.1`):
    // different resolvers read these differently, so refuse them outright
    // rather than guessing which address the client will use.
    if (parseIpv4(host)) |ip| return isPrivateIpv4(ip);
    if (looksLikeNumericHost(host)) return true;

    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return isPrivateIpv6(host);
    }
    return false;
}

fn looksLikeNumericHost(host: []const u8) bool {
    // Single-integer host or any 0x-prefixed part.
    if (std.mem.startsWith(u8, host, "0x")) return true;
    var all_digit = true;
    for (host) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digit = false;
            break;
        }
    }
    if (all_digit and host.len > 0) return true;
    var parts = std.mem.splitScalar(u8, host, '.');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "0x")) return true;
        if (part.len > 1 and part[0] == '0') {
            // Leading-zero octet (`0177`): octal to some resolvers.
            var digits = true;
            for (part) |ch| if (!std.ascii.isDigit(ch)) {
                digits = false;
                break;
            };
            if (digits) return true;
        }
    }
    return false;
}

fn parseIpv4(host: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    return if (i == 4) out else null;
}

fn isPrivateIpv4(ip: [4]u8) bool {
    const a = ip[0];
    const b = ip[1];
    if (a == 0) return true;
    if (a == 10) return true;
    if (a == 127) return true;
    if (a == 169 and b == 254) return true;
    if (a == 172 and b >= 16 and b <= 31) return true;
    if (a == 192 and b == 168) return true;
    if (a == 100 and b >= 64 and b <= 127) return true; // CGNAT 100.64/10
    if (a == 192 and b == 0) return true; // 192.0.0.0/24
    if (a == 198 and (b == 18 or b == 19)) return true; // benchmarking
    if (a >= 240) return true; // reserved + broadcast
    return false;
}

fn isPrivateIpv6(host: []const u8) bool {
    if (std.mem.eql(u8, host, "::") or std.mem.eql(u8, host, "::1")) return true;
    // Decode the first hextet (before any `::` compression or `:`).
    // Empty first piece means the address starts with `::`, i.e. the
    // unspecified/loopback neighbourhood already handled above; any other
    // `::`-leading address with more groups is still in ::/8 territory
    // only when the first hextet is 0, which we treat conservatively.
    const first_end = std.mem.indexOfScalar(u8, host, ':') orelse host.len;
    const first = host[0..first_end];
    if (first.len == 0) return true;
    const v = std.fmt.parseInt(u16, first, 16) catch return true;
    if (v == 0) return true;
    if (v >= 0xfe80 and v <= 0xfebf) return true; // link-local fe80::/10
    if (v >= 0xfc00 and v <= 0xfdff) return true; // unique local fc00::/7
    // IPv4-mapped/compatible forms embed the v4 address after the last ':'.
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        if (parseIpv4(host[colon + 1 ..])) |ip| return isPrivateIpv4(ip);
    }
    return false;
}

/// A blocking HTTP(S) fetch. Runs on a pool thread — never on a shard thread,
/// which is the whole point of the park/resume machinery.
///
/// TLS is handled by std.http.Client, which rescans the system CA bundle on the
/// first HTTPS connection. The response body is allocated with `gpa` and owned by
/// the caller (the completion carries it back to the shard, which frees it after
/// the guest has seen it).
pub fn fetchHttp(gpa: std.mem.Allocator, io: std.Io, req: vm.FetchReq) vm.FetchRes {
    return fetchHttpWithPolicy(gpa, io, req, .default);
}

pub fn fetchHttpWithPolicy(gpa: std.mem.Allocator, io: std.Io, req: vm.FetchReq, policy: FetchPolicy) vm.FetchRes {
    const method = methodOf(req.method) catch return .{ .ok = false, .err = dupErr(gpa, "unsupported method") };
    validateFetchUrl(req.url, policy) catch
        return .{ .ok = false, .err = dupErr(gpa, "fetch blocked by policy") };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    const result = client.fetch(.{
        .location = .{ .url = req.url },
        .method = method,
        .payload = if (req.body.len > 0) req.body else null,
        .response_writer = &aw.writer,
        // Never chase a redirect onto a host we have not validated: the
        // guest receives the 3xx and can decide for itself, and a second
        // fetch re-enters `validateFetchUrl`.
        .redirect_behavior = .unhandled,
    }) catch |err| {
        aw.deinit();
        return .{ .ok = false, .err = dupErr(gpa, @errorName(err)) };
    };

    var list = aw.toArrayList();
    const body = list.toOwnedSlice(gpa) catch {
        list.deinit(gpa);
        return .{ .ok = false, .err = &.{} };
    };
    return .{
        .ok = true,
        .status = @backingInt(result.status),
        .body = body,
    };
}

/// Every failure string a completion carries must be owned by the same allocator
/// the shard frees it with; a literal would be a free of static memory.
fn dupErr(gpa: std.mem.Allocator, msg: []const u8) []const u8 {
    return gpa.dupe(u8, msg) catch &.{};
}

pub fn methodOf(name: []const u8) error{UnsupportedMethod}!std.http.Method {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "GET")) return .GET;
    if (eq(name, "POST")) return .POST;
    if (eq(name, "PUT")) return .PUT;
    if (eq(name, "DELETE")) return .DELETE;
    if (eq(name, "PATCH")) return .PATCH;
    if (eq(name, "HEAD")) return .HEAD;
    return error.UnsupportedMethod;
}

/// Indirection so tests can run the whole park/resume path without a network.
pub const FetchFn = *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, req: vm.FetchReq) vm.FetchRes;

pub fn defaultFetch(ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, req: vm.FetchReq) vm.FetchRes {
    const policy: FetchPolicy = if (ctx) |p| @as(*const FetchPolicy, @ptrCast(@alignCast(p))).* else .default;
    return fetchHttpWithPolicy(gpa, io, req, policy);
}

test "only the methods we can name are accepted" {
    try std.testing.expect(try methodOf("get") == .GET);
    try std.testing.expect(try methodOf("POST") == .POST);
    try std.testing.expectError(error.UnsupportedMethod, methodOf("TRACE"));
    try std.testing.expectError(error.UnsupportedMethod, methodOf(""));
}

test "fetch policy blocks private and metadata addresses" {
    const blocked = [_][]const u8{
        "http://169.254.169.254/latest/meta-data/",
        "http://127.0.0.1:2379/v2/keys",
        "http://10.0.0.5/admin",
        "http://172.16.0.1/",
        "http://192.168.1.1/",
        "http://localhost:8080/admin",
        "http://[::1]/",
        "http://[fe80::1]/",
        "http://2130706433/",
        "http://0x7f000001/",
        "ftp://example.com/file",
        "http://user:pass@example.com/",
        "http://metadata.google.internal/",
    };
    for (blocked) |u|
        try std.testing.expectError(error.FetchBlocked, validateFetchUrl(u, .default));
    try validateFetchUrl("https://example.com/path?q=1", .default);
    try validateFetchUrl("https://93.184.216.34/", .default);
    // Opt-in escape hatch for a trusted network.
    try validateFetchUrl("http://127.0.0.1:8080/", .{ .allow_private = true });
}

test "fetch allowlist requires a label boundary" {
    const policy: FetchPolicy = .{ .allow_hosts = &.{ "api.example.com", "*.example.org" } };
    try validateFetchUrl("https://api.example.com/", policy);
    try validateFetchUrl("https://a.example.org/", policy);
    try std.testing.expectError(error.FetchBlocked, validateFetchUrl("https://example.org/", policy));
    try std.testing.expectError(error.FetchBlocked, validateFetchUrl("https://badexample.org/", policy));
    try std.testing.expectError(error.FetchBlocked, validateFetchUrl("https://other.net/", policy));
}
