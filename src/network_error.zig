pub const Recoverable = error{
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionTimedOut,
    ConnectionResetByPeer,
    UnknownHostName,
    TemporaryNameServerFailure,
    NameServerFailure,
};

pub fn errorClassifier(err: anyerror) ?Recoverable {
    return switch (err) {
        error.ConnectionRefused => Recoverable.ConnectionRefused,
        error.NetworkUnreachable => Recoverable.NetworkUnreachable,
        error.ConnectionTimedOut => Recoverable.ConnectionTimedOut,
        error.ConnectionResetByPeer => Recoverable.ConnectionResetByPeer,
        error.UnknownHostName => Recoverable.UnknownHostName,
        error.TemporaryNameServerFailure => Recoverable.TemporaryNameServerFailure,
        error.NameServerFailure => Recoverable.NameServerFailure,
        else => null,
    };
}

pub fn toString(err: Recoverable) []const u8 {
    return switch (err) {
        Recoverable.UnknownHostName => "unknown hostname",
        Recoverable.ConnectionRefused => "connection refused",
        Recoverable.ConnectionTimedOut => "connection timed out",
        Recoverable.ConnectionResetByPeer => "connection reset by peer",
        Recoverable.NameServerFailure => "nameserver failure",
        Recoverable.TemporaryNameServerFailure => "temporary nameserver failure",
        Recoverable.NetworkUnreachable => "network unreachable",
    };
}
