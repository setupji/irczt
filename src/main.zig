// Copyright (C) 2018-2020 Petr Pavlu <setup@dagobah.cz>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const net = std.net;
const os = std.os;
const rand = std.rand;
const time = std.time;

const assert = std.debug.assert;
const expect = std.testing.expect;

const avl = @import("avl.zig");
const config = @import("config.zig");

const timestamp_str_width = "[18446744073709551.615]".len;

/// Convert a specified timestamp to a human-readable format.
fn formatTimeStamp(output: *[timestamp_str_width]u8, milliseconds: u64) void {
    var rem = milliseconds;
    var i = timestamp_str_width;
    while (i > 0) : (i -= 1) {
        if (i == timestamp_str_width) {
            output[i - 1] = ']';
        } else if (i == timestamp_str_width - 4) {
            output[i - 1] = '.';
        } else if (i == 1) {
            output[i - 1] = '[';
        } else if (rem == 0) {
            if (i > timestamp_str_width - 6) {
                output[i - 1] = '0';
            } else {
                output[i - 1] = ' ';
            }
        } else {
            output[i - 1] = '0' + @intCast(u8, rem % 10);
            rem /= 10;
        }
    }
}

test "format timestamp" {
    var buffer: [timestamp_str_width]u8 = undefined;

    formatTimeStamp(&buffer, 0);
    expect(mem.eql(u8, buffer[0..], "[                0.000]"));

    formatTimeStamp(&buffer, 1);
    expect(mem.eql(u8, buffer[0..], "[                0.001]"));

    formatTimeStamp(&buffer, 100);
    expect(mem.eql(u8, buffer[0..], "[                0.100]"));

    formatTimeStamp(&buffer, 1000);
    expect(mem.eql(u8, buffer[0..], "[                1.000]"));

    formatTimeStamp(&buffer, 10000);
    expect(mem.eql(u8, buffer[0..], "[               10.000]"));

    formatTimeStamp(&buffer, 1234567890);
    expect(mem.eql(u8, buffer[0..], "[          1234567.890]"));

    formatTimeStamp(&buffer, 18446744073709551615);
    expect(mem.eql(u8, buffer[0..], "[18446744073709551.615]"));
}

/// Format and print an info message on the standard output.
fn info(comptime fmt: []const u8, args: anytype) void {
    var timestamp: [timestamp_str_width]u8 = undefined;
    formatTimeStamp(&timestamp, @intCast(u64, time.milliTimestamp()));
    const writer = io.getStdOut().writer();
    writer.print("{} " ++ fmt, .{timestamp} ++ args) catch return;
}

/// Format and print a warning message on the standard error output.
fn warn(comptime fmt: []const u8, args: anytype) void {
    var timestamp: [timestamp_str_width]u8 = undefined;
    formatTimeStamp(&timestamp, @intCast(u64, time.milliTimestamp()));
    const writer = io.getStdErr().writer();
    writer.print("\x1b[31m{} " ++ fmt ++ "\x1b[0m", .{timestamp} ++ args) catch return;
}

/// Thin wrapper for a character slice to output non-printable characters as escaped values with
/// std.fmt.
const EscapeFormatter = struct {
    /// Managed slice.
    _slice: []const u8,

    /// Construct an EscapeFormatter.
    fn init(slice: []const u8) EscapeFormatter {
        return EscapeFormatter{ ._slice = slice };
    }

    /// Return the managed slice.
    fn getSlice(self: *const EscapeFormatter) []const u8 {
        return self._slice;
    }

    /// Format and output the slice.
    pub fn format(
        self: EscapeFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len > 0) {
            @compileError("Unknown format character: '" ++ fmt ++ "'");
        }

        for (self._slice) |char| {
            if (char == '\\') {
                try out_stream.writeAll("\\\\");
            } else if (char == '\'') {
                try out_stream.writeAll("\\'");
            } else if (char >= ' ' and char <= '~') {
                try out_stream.writeAll(&[_]u8{char});
            } else {
                try out_stream.writeAll("\\x");
                try out_stream.writeAll(&[_]u8{'0' + (char / 10)});
                try out_stream.writeAll(&[_]u8{'0' + (char % 10)});
            }
        }
    }
};

/// Alias for EscapeFormatter.init().
fn E(slice: []const u8) EscapeFormatter {
    return EscapeFormatter.init(slice);
}

/// Conditional variant of EscapeFormatter.
const ConditionalEscapeFormatter = struct {
    /// Wrapped EscapeFormatter.
    _escape: EscapeFormatter,

    /// Pointer to an outside flag that controls whether the slice should be escaped during the
    /// format() call or not.
    _cond: *bool,

    /// Construct a ConditionalEscapeFormatter.
    fn init(slice: []const u8, cond: *bool) ConditionalEscapeFormatter {
        return ConditionalEscapeFormatter{
            ._escape = EscapeFormatter.init(slice),
            ._cond = cond,
        };
    }

    /// Format and output the slice.
    pub fn format(
        self: ConditionalEscapeFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len > 0) {
            @compileError("Unknown format character: '" ++ fmt ++ "'");
        }

        if (self._cond.*) {
            try self._escape.format(fmt, options, out_stream);
        } else {
            try out_stream.writeAll(self._escape.getSlice());
        }
    }
};

/// Alias for ConditionalEscapeFormatter.init().
fn CE(slice: []const u8, cond: *bool) ConditionalEscapeFormatter {
    return ConditionalEscapeFormatter.init(slice, cond);
}

/// Lexical analyzer for IRC messages and list parameters.
const Lexer = struct {
    /// Input string.
    _string: []const u8,

    /// Current position in the input string.
    _pos: usize,

    /// Construct a Lexer.
    fn init(string: []const u8) Lexer {
        return Lexer{
            ._string = string,
            ._pos = 0,
        };
    }

    /// Return the current position in the input string.
    fn getCurPos(self: *const Lexer) usize {
        return self._pos;
    }

    /// Return the current character.
    fn getCurChar(self: *const Lexer) u8 {
        if (self._pos < self._string.len) {
            return self._string[self._pos];
        }
        return 0;
    }

    /// Skip to a next character in the string.
    fn nextChar(self: *Lexer) void {
        if (self._pos < self._string.len) {
            self._pos += 1;
        }
    }

    /// Read all space characters at the current position if a separator is valid at this point.
    fn _processSpace(self: *Lexer) void {
        if (self._pos == 0) {
            return;
        }

        while (self.getCurChar() == ' ') {
            self.nextChar();
        }
    }

    /// Read one word starting at exactly the current position.
    fn _readWordNow(self: *Lexer) ?[]const u8 {
        const begin = self._pos;
        var end = begin;
        while (self.getCurChar() != '\x00' and self.getCurChar() != ' ') : (end += 1) {
            self.nextChar();
        }

        return if (begin != end) self._string[begin..end] else null;
    }

    /// Read a next word from the string.
    fn readWord(self: *Lexer) ?[]const u8 {
        self._processSpace();
        return self._readWordNow();
    }

    /// Read a next parameter from the string.
    fn readParam(self: *Lexer) ?[]const u8 {
        self._processSpace();

        if (self.getCurChar() == ':') {
            const begin = self._pos + 1;
            const end = self._string.len;
            self._pos = end;
            // The last parameter after ':' is always valid and can be empty.
            return self._string[begin..end];
        }
        return self._readWordNow();
    }

    /// Read a next list item from the string. Individual items are separated by commas, the string
    /// should not contain any spaces. This function is used to parse list items from parameters.
    fn readListItem(self: *Lexer) ?[]const u8 {
        if (self._pos != 0 and self.getCurChar() == ',') {
            self.nextChar();
        }

        const begin = self._pos;
        var end = begin;
        while (self.getCurChar() != '\x00' and self.getCurChar() != ',') : (end += 1) {
            self.nextChar();
        }

        return if (begin != end) self._string[begin..end] else null;
    }

    /// Query whether all characters were read.
    fn isAtEnd(self: *const Lexer) bool {
        return self._pos == self._string.len;
    }

    /// Read a remainder of the string.
    fn readRest(self: *Lexer) ?[]const u8 {
        const begin = self._pos;
        const end = self._string.len;
        self._pos = end;
        return if (begin != end) self._string[begin..end] else null;
    }
};

/// User on the server. This is the base type for a remote Client or an artificial LocalBot.
const User = struct {
    const Type = enum {
        Client,
        LocalBot,
    };

    /// User type.
    _type: Type,

    /// Parent server.
    _server: *Server,

    /// Unique nick name (owned).
    _nickname: ?[]u8,

    /// Username (owned).
    _username: ?[]u8,

    /// Realname (owned).
    _realname: ?[]u8,

    /// Joined channels.
    _channels: ChannelSet,

    /// Construct a new User.
    fn init(type_: Type, server: *Server) User {
        const allocator = server.getAllocator();

        return User{
            ._type = type_,
            ._server = server,
            ._nickname = null,
            ._username = null,
            ._realname = null,
            ._channels = ChannelSet.init(allocator),
        };
    }

    /// Quit the server and destroy the user.
    fn deinit(self: *User) void {
        // Quit all channels.
        self._quit("Client quit");
        assert(self._channels.count() == 0);
        self._channels.deinit();

        const allocator = self._server.getAllocator();
        if (self._nickname) |nickname| {
            allocator.free(nickname);
        }
        if (self._username) |username| {
            allocator.free(username);
        }
        if (self._realname) |realname| {
            allocator.free(realname);
        }
    }

    /// Quit the server. The operation leaves all joined channels and informs their members about
    /// the quit.
    fn _quit(self: *User, quit_message: []const u8) void {
        // Send a QUIT message to users in all joined channels.
        if (self._channels.count() == 0) {
            return;
        }

        var ec: bool = undefined;

        const users = self._server.getUsers();
        var user_iter = users.iterator();
        while (user_iter.next()) |user_node| {
            const user = user_node.value();

            // Skip if this is the current user.
            if (user == self) {
                continue;
            }

            // Check if the user is in any joined channel.
            var found = false;
            var channel_iter = self._channels.iterator();
            while (channel_iter.next()) |channel_node| {
                const channel = channel_node.key();
                const members = channel.getMembers();
                const member_iter = members.find(user);
                if (member_iter.valid()) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }

            // Inform the user about the quit.
            user.sendMessage(&ec, "{} QUIT :{}", .{ CE(self._nickname.?, &ec), quit_message });
        }

        // Quit all joined channels.
        var channel_iter = self._channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.key();
            channel.quit(self);
        }
        self._channels.clear();
    }

    /// Obtain the current nickname or "*" if the name has not been set yet.
    fn getNickName(self: *const User) []const u8 {
        return if (self._nickname) |nickname| nickname else "*";
    }

    /// Return whether the user has its nickname set.
    fn hasNickName(self: *const User) bool {
        return self._nickname != null;
    }

    /// Set a new nickname. Note that it is a caller's responsibility to make sure that this name
    /// does not duplicate a nickname of another user on the server.
    fn _nick(self: *User, nickname: []const u8) !void {
        const allocator = self._server.getAllocator();

        // Make a copy of the nickname string.
        const nickname_copy = allocator.alloc(u8, nickname.len) catch |err| {
            self._warn(
                "Failed to allocate a nickname storage with size of '{}' bytes: {}.\n",
                .{ nickname.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(nickname_copy);
        mem.copy(u8, nickname_copy, nickname);

        // Tell the server about the new nickname.
        // TODO Fix passing of the self._nickname parameter which is a workaround for a bug in the
        // Zig compiler.
        try self._server.recordNickNameChange(
            self,
            if (self._nickname) |old_nickname| old_nickname else null,
            nickname_copy,
        );

        // Set the new nickname.
        if (self._nickname) |old_nickname| {
            allocator.free(old_nickname);
        }
        self._nickname = nickname_copy;
    }

    /// Obtain the current username or "*" if the name has not been set yet.
    fn getUserName(self: *const User) []const u8 {
        return if (self._username) |username| username else "*";
    }

    /// Obtain the current realname or "*" if the name has not been set yet.
    fn getRealName(self: *const User) []const u8 {
        return if (self._realname) |realname| realname else "*";
    }

    /// Set a new username and realname.
    fn _user(self: *User, username: []const u8, realname: []const u8) !void {
        const allocator = self._server.getAllocator();

        // Make a copy of the username string.
        const username_copy = allocator.alloc(u8, username.len) catch |err| {
            self._warn(
                "Failed to allocate a username storage with size of '{}' bytes: {}.\n",
                .{ username.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(username_copy);
        mem.copy(u8, username_copy, username);

        // Make a copy of the realname string.
        const realname_copy = allocator.alloc(u8, realname.len) catch |err| {
            self._warn(
                "Failed to allocate a realname storage with size of '{}' bytes: {}.\n",
                .{ realname.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(realname_copy);
        mem.copy(u8, realname_copy, realname);

        // Set the new username and realname.
        if (self._username) |old_username| {
            allocator.free(old_username);
        }
        self._username = username_copy;

        if (self._realname) |old_realname| {
            allocator.free(old_realname);
        }
        self._realname = realname_copy;
    }

    /// Format and print an info message on the standard output.
    fn _info(self: *const User, comptime fmt: []const u8, args: anytype) void {
        switch (self._type) {
            .Client => {
                return Client.fromConstUser(self)._info(fmt, args);
            },
            .LocalBot => {
                return LocalBot.fromConstUser(self)._info(fmt, args);
            },
        }
    }

    /// Format and print a warning message on the standard error output.
    fn _warn(self: *const User, comptime fmt: []const u8, args: anytype) void {
        switch (self._type) {
            .Client => {
                return Client.fromConstUser(self)._warn(fmt, args);
            },
            .LocalBot => {
                return LocalBot.fromConstUser(self)._warn(fmt, args);
            },
        }
    }

    /// Join a specified channel. Note that it is a caller's responsibility to make sure that the
    /// user is not already in the channel.
    fn _joinChannel(self: *User, channel: *Channel) !void {
        const channel_iter = self._channels.insert(channel, {}) catch |err| {
            self._warn(
                "Failed to insert channel '{}' in the channel set: {}.\n",
                .{ E(channel.getName()), @errorName(err) },
            );
            return err;
        };
        errdefer self._channels.remove(channel_iter);

        try channel.join(self);
    }

    /// Leave a specified channel.
    fn _partChannel(self: *User, channel: *Channel, part_message: []const u8) void {
        const channel_iter = self._channels.find(channel);
        assert(channel_iter.valid());

        channel.part(self, part_message);
        self._channels.remove(channel_iter);
    }

    /// Send a private message to the user.
    fn sendPrivMsg(self: *User, from: []const u8, to: []const u8, text: []const u8) void {
        switch (self._type) {
            .Client => {
                return Client.fromUser(self)._sendPrivMsg(from, to, text);
            },
            .LocalBot => {
                // Ignore because local bots do not care about received private messages.
            },
        }
    }

    /// Send an IRC protocol message to the user.
    fn sendMessage(
        self: *User,
        escape_cond: ?*bool,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        switch (self._type) {
            .Client => {
                Client.fromUser(self)._sendMessage(escape_cond, fmt, args);
            },
            .LocalBot => {
                // Ignore because local bots do not send messages anywhere.
            },
        }
    }
};

const UserSet = avl.Map(*User, void, avl.getLessThanFn(*User));

const UserNameSet = avl.Map([]const u8, *User, avl.getLessThanFn([]const u8));

/// Remote client.
const Client = struct {
    const InputState = enum {
        Normal,
        Normal_CR,
    };

    const AcceptParamError = error{MissingParameter};
    const CheckRegisteredError = error{NotRegistered};

    const InputError = error{
        MalformedMessage,
        EndOfFile,
        Quit,
    };

    /// User definition.
    _user: User,

    /// Client's socket.
    _fd: i32,
    /// Client's network address.
    _addr: net.Address,

    /// Writer to the client's socket.
    _file_writer: fs.File.Writer,
    /// Reader from the client's socket.
    _file_reader: fs.File.Reader,

    /// Input buffer for IRC messages.
    _input_buffer: [512]u8,
    /// Number of bytes currently stored in _input_buffer that compose an incomplete message.
    _input_received: usize,
    /// Current input state at the _input_received position.
    _input_state: InputState,

    /// Create a new Client instance. Ownership of a specified client descriptor is transferred to
    /// the created instance. If constructing the client fails, the file descriptor gets closed by
    /// the function.
    fn create(fd: i32, addr: net.Address, server: *Server) !*Client {
        errdefer os.close(fd);

        info("{}: Creating the client.\n", .{addr});

        const allocator = server.getAllocator();
        const client = allocator.create(Client) catch |err| {
            warn("{}: Failed to allocate a client instance: {}.\n", .{ addr, @errorName(err) });
            return err;
        };
        const file = fs.File{ .handle = fd };
        client.* = Client{
            ._user = User.init(.Client, server),
            ._fd = fd,
            ._addr = addr,
            ._file_writer = file.writer(),
            ._file_reader = file.reader(),
            ._input_buffer = undefined,
            ._input_received = 0,
            ._input_state = .Normal,
        };
        return client;
    }

    /// Close the remote client connection and destroy the client.
    fn destroy(self: *Client) void {
        self._info("Destroying the client.\n", .{});

        os.close(self._fd);

        const allocator = self._user._server.getAllocator();
        self._user.deinit();
        allocator.destroy(self);
    }

    /// Get a Client base pointer given a pointer to its embedded User member.
    fn fromUser(user: *User) *Client {
        assert(user._type == .Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    /// Get a const Client base pointer given a const pointer to its embedded User member.
    fn fromConstUser(user: *const User) *const Client {
        assert(user._type == .Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    /// Get a pointer to the embedded User member.
    fn toUser(self: *Client) *User {
        return &self._user;
    }

    /// Get the client's file descriptor.
    fn getFileDescriptor(self: *const Client) i32 {
        return self._fd;
    }

    /// Format and print an info message on the standard output.
    fn _info(self: *const Client, comptime fmt: []const u8, args: anytype) void {
        info("{}: " ++ fmt, .{self._addr} ++ args);
    }

    /// Format and print a warning message on the standard error output.
    fn _warn(self: *const Client, comptime fmt: []const u8, args: anytype) void {
        warn("{}: " ++ fmt, .{self._addr} ++ args);
    }

    /// Read one parameter from a specified message (lexer). Upon successful completion, a slice
    /// with the parameter is returned. Otherwise, error AcceptParamError.MissingParameter is
    /// returned. If the parameter is additionally marked as mandatory then an error reply is sent
    /// to the user.
    fn _acceptParam(
        self: *Client,
        lexer: *Lexer,
        command: []const u8,
        requirement: enum { Mandatory, Optional, Silent },
    ) AcceptParamError![]const u8 {
        const maybe_param = lexer.readParam();
        if (maybe_param) |param| {
            return param;
        }

        if (requirement == .Mandatory) {
            // Send ERR_NEEDMOREPARAMS.
            var ec: bool = undefined;
            self._sendMessage(
                &ec,
                ":{} 461 {} {} :Not enough parameters",
                .{
                    self._user._server.getHostName(),
                    CE(self._user.getNickName(), &ec),
                    CE(command, &ec),
                },
            );
        }
        return AcceptParamError.MissingParameter;
    }

    /// Read an optional parameter from a specified message (lexer). If it is missing then a given
    /// default value is returned instead.
    fn _acceptParamOrDefault(
        self: *Client,
        lexer: *Lexer,
        command: []const u8,
        default: []const u8,
    ) []const u8 {
        return self._acceptParam(lexer, command, .Optional) catch |err| {
            switch (err) {
                AcceptParamError.MissingParameter => {
                    return default;
                },
            }
        };
    }

    /// Check that the end of a specified message (lexer) has been reached. A warning is reported if
    /// that is not the case.
    fn _acceptEndOfMessage(self: *Client, lexer: *Lexer, command: []const u8) void {
        if (lexer.isAtEnd())
            return;

        const pos = lexer.getCurPos() + 1;
        const rest = lexer.readRest() orelse unreachable;
        self._warn(
            "Expected the end of the '{}' message at position '{}' but found '{}'.\n",
            .{ command, pos, E(rest) },
        );
    }

    /// Process the NICK command.
    /// RFC 1459: Parameters: <nickname> [ <hopcount> ]
    /// RFC 2812: Parameters: <nickname>
    ///    IRCZT: Parameters: <nickname>
    fn _processCommand_NICK(self: *Client, lexer: *Lexer) !void {
        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        const new_nickname = self._acceptParam(lexer, "NICK", .Silent) catch |err| {
            switch (err) {
                AcceptParamError.MissingParameter => {
                    // Send ERR_NONICKNAMEGIVEN.
                    self._sendMessage(
                        &ec,
                        ":{} 431 {} :No nickname given",
                        .{ CE(hostname, &ec), CE(nickname, &ec) },
                    );
                    return;
                },
            }
        };
        self._acceptEndOfMessage(lexer, "NICK");

        // Validate the nickname.
        for (new_nickname) |char, i| {
            // <letter>
            if ((char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z')) {
                continue;
            }

            if (i != 0) {
                // <number>
                if (char >= '0' and char <= '9') {
                    continue;
                }
                // <special>
                if (char == '-' or char == '[' or char == ']' or char == '\\' or char == '`' or
                    char == '^' or char == '{' or char == '}')
                {
                    continue;
                }
            }

            // Send ERR_ERRONEUSNICKNAME.
            self._sendMessage(
                &ec,
                ":{} 432 {} {} :Erroneus nickname",
                .{ hostname, CE(nickname, &ec), CE(new_nickname, &ec) },
            );
            return;
        }

        // Check that the nickname is not already in use.
        if (self._user._server.lookupUser(new_nickname) != null) {
            // Send ERR_NICKNAMEINUSE.
            self._sendMessage(
                &ec,
                ":{} 433 {} {} :Nickname is already in use",
                .{ CE(hostname, &ec), CE(nickname, &ec), CE(new_nickname, &ec) },
            );
            return;
        }

        const is_first_nickname = self._user._nickname == null;

        self._user._nick(new_nickname) catch |err| {
            self._sendMessage(
                null,
                "ERROR :NICK command failed on the server: {}",
                .{@errorName(err)},
            );
            return err;
        };

        assert((self._user._username != null) == (self._user._realname != null));
        if (is_first_nickname and self._user._username != null) {
            // Complete the join if the initial NICK and USER pair was received.
            self._completeRegistration();
        }
    }

    /// Process the USER command.
    /// RFC 1459: Parameters: <username> <hostname> <servername> <realname>
    /// RFC 2812: Parameters: <user> <mode> <unused> <realname>
    ///    IRCZT: Parameters: <username> <unused> <unused> <realname>
    fn _processCommand_USER(self: *Client, lexer: *Lexer) !void {
        assert((self._user._username != null) == (self._user._realname != null));
        if (self._user._username != null) {
            // Send ERR_ALREADYREGISTRED.
            var ec: bool = undefined;
            self._sendMessage(
                &ec,
                ":{} 462 {} :You may not reregister",
                .{ self._user._server.getHostName(), CE(self._user.getNickName(), &ec) },
            );
            return;
        }

        const username = self._acceptParam(lexer, "USER", .Mandatory) catch return;
        const hostname = self._acceptParam(lexer, "USER", .Mandatory) catch return;
        const servername = self._acceptParam(lexer, "USER", .Mandatory) catch return;
        const realname = self._acceptParam(lexer, "USER", .Mandatory) catch return;
        self._acceptEndOfMessage(lexer, "USER");

        self._user._user(username, realname) catch |err| {
            self._sendMessage(
                null,
                "ERROR :USER command failed on the server: {}",
                .{@errorName(err)},
            );
            return err;
        };

        if (self._user._nickname != null) {
            // Complete the join if the initial NICK and USER pair was received.
            self._completeRegistration();
        }
    }

    /// Complete join of the client after the initial USER and NICK pair is received.
    fn _completeRegistration(self: *Client) void {
        assert(self._user._nickname != null);
        assert(self._user._username != null);
        assert(self._user._realname != null);

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        // Send RPL_LUSERCLIENT.
        const users = self._user._server.getUsers();
        self._sendMessage(
            &ec,
            ":{} 251 {} :There are {} users and 0 invisible on 1 servers",
            .{ CE(hostname, &ec), CE(nickname, &ec), users.count() },
        );

        // Send motd.
        self._sendMessage(
            &ec,
            ":{} 375 {} :- {} Message of the Day -",
            .{ CE(hostname, &ec), CE(nickname, &ec), CE(hostname, &ec) },
        );
        self._sendMessage(
            &ec,
            ":{} 372 {} :- Welcome to the {} IRC network!",
            .{ CE(hostname, &ec), CE(nickname, &ec), CE(hostname, &ec) },
        );
        self._sendMessage(
            &ec,
            ":{} 376 {} :End of /MOTD command.",
            .{ CE(hostname, &ec), CE(nickname, &ec) },
        );

        // Welcome the user also via a private message.
        self._sendMessage(
            &ec,
            ":irczt-connect PRIVMSG {} :Welcome to {}",
            .{ CE(nickname, &ec), CE(hostname, &ec) },
        );
    }

    /// Check that the user has completed the initial registration and is fully joined. If that is
    /// not the case then reply ERR_NOTREGISTERED is sent to the client and
    /// error CheckRegisteredError.NotRegistered is returned.
    fn _checkRegistered(self: *Client) !void {
        assert((self._user._username != null) == (self._user._realname != null));
        if (self._user._nickname != null and self._user._username != null) {
            return;
        }
        self._sendMessage(
            null,
            ":{} 451 * :You have not registered",
            .{self._user._server.getHostName()},
        );
        return Client.CheckRegisteredError.NotRegistered;
    }

    /// Process the QUIT command.
    /// RFC 1459: Parameters: [<Quit message>]
    /// RFC 2812: Parameters: [ <Quit Message> ]
    ///    IRCZT: Parameters: [ <Quit Message> ]
    fn _processCommand_QUIT(self: *Client, lexer: *Lexer) !void {
        const quit_message = self._acceptParamOrDefault(lexer, "QUIT", "Client quit");
        self._acceptEndOfMessage(lexer, "QUIT");

        var ec: bool = undefined;
        self._sendMessage(&ec, "ERROR :{}", .{CE(quit_message, &ec)});
        self._user._quit(quit_message);

        return Client.InputError.Quit;
    }

    /// Process the LIST command.
    /// RFC 1459: Parameters: [<channel>{,<channel>} [<server>]]
    /// RFC 2812: Parameters: [ <channel> *( "," <channel> ) [ <target> ] ]
    ///    IRCZT: Parameters: [ <channel> *( "," <channel> ) ]
    fn _processCommand_LIST(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const maybe_channel_list = self._acceptParam(lexer, "LIST", .Optional) catch null;
        self._acceptEndOfMessage(lexer, "LIST");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        // Send RPL_LISTSTART.
        self._sendMessage(
            &ec,
            ":{} 321 {} Channel :Users  Name",
            .{ CE(hostname, &ec), CE(nickname, &ec) },
        );

        if (maybe_channel_list) |channel_list| {
            // Send RPL_LIST for each matched channel.
            var sub_lexer = Lexer.init(channel_list);
            while (sub_lexer.readListItem()) |channel_name| {
                const channel = self._user._server.lookupChannel(channel_name) orelse continue;
                self._sendMessage(
                    &ec,
                    ":{} 322 {} {} {} :{}",
                    .{
                        CE(hostname, &ec),
                        CE(nickname, &ec),
                        CE(channel.getName(), &ec),
                        channel.getMembers().count(),
                        CE(channel.getTopic(), &ec),
                    },
                );
            }
        } else {
            // Send RPL_LIST for each channel on the server.
            const channels = self._user._server.getChannels();
            var channel_iter = channels.iterator();
            while (channel_iter.next()) |channel_node| {
                const channel = channel_node.value();
                self._sendMessage(
                    &ec,
                    ":{} 322 {} {} {} :{}",
                    .{
                        CE(hostname, &ec),
                        CE(nickname, &ec),
                        CE(channel.getName(), &ec),
                        channel.getMembers().count(),
                        CE(channel.getTopic(), &ec),
                    },
                );
            }
        }

        // Send RPL_LISTEND.
        self._sendMessage(
            &ec,
            ":{} 323 {} :End of /LIST",
            .{ CE(hostname, &ec), CE(nickname, &ec) },
        );
    }

    /// Process the JOIN command.
    /// RFC 1459: Parameters: <channel>{,<channel>} [<key>{,<key>}]
    /// RFC 2812: Parameters: ( <channel> *( "," <channel> ) [ <key> *( "," <key> ) ] ) / "0"
    ///    IRCZT: Parameters: <channel> *( "," <channel> )
    fn _processCommand_JOIN(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const channel_list = self._acceptParam(lexer, "JOIN", .Mandatory) catch return;
        self._acceptEndOfMessage(lexer, "JOIN");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        var sub_lexer = Lexer.init(channel_list);
        while (sub_lexer.readListItem()) |channel_name| {
            const channel = self._user._server.lookupChannel(channel_name) orelse {
                // Send ERR_NOSUCHCHANNEL.
                self._sendMessage(
                    &ec,
                    ":{} 403 {} {} :No such channel",
                    .{ CE(hostname, &ec), CE(nickname, &ec), CE(channel_name, &ec) },
                );
                continue;
            };

            // If the user is already in the channel then skip it as there is nothing left to do.
            const members = channel.getMembers();
            const member_iter = members.find(&self._user);
            if (member_iter.valid()) {
                continue;
            }

            self._user._joinChannel(channel) catch |err| {
                self._sendMessage(
                    null,
                    "ERROR :JOIN command failed on the server: {}",
                    .{@errorName(err)},
                );
                return err;
            };
        }
    }

    /// Process the PART command.
    /// RFC 1459: Parameters: <channel>{,<channel>}
    /// RFC 2812: Parameters: <channel> *( "," <channel> ) [ <Part Message> ]
    ///    IRCZT: Parameters: <channel> *( "," <channel> ) [ <Part Message> ]
    fn _processCommand_PART(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const channel_list = self._acceptParam(lexer, "PART", .Mandatory) catch return;
        const part_message = self._acceptParamOrDefault(lexer, "PART", self._user.getNickName());
        self._acceptEndOfMessage(lexer, "PART");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        var sub_lexer = Lexer.init(channel_list);
        while (sub_lexer.readListItem()) |channel_name| {
            const channel = self._user._server.lookupChannel(channel_name) orelse {
                // Send ERR_NOSUCHCHANNEL.
                self._sendMessage(
                    &ec,
                    ":{} 403 {} {} :No such channel",
                    .{ CE(hostname, &ec), CE(nickname, &ec), CE(channel_name, &ec) },
                );
                continue;
            };

            const channel_iter = self._user._channels.find(channel);
            if (!channel_iter.valid()) {
                // Send ERR_NOTONCHANNEL.
                self._sendMessage(
                    &ec,
                    ":{} 442 {} {} :You're not on that channel",
                    .{ CE(hostname, &ec), CE(nickname, &ec), CE(channel_name, &ec) },
                );
                continue;
            }

            self._user._partChannel(channel, part_message);
        }
    }

    /// Process the WHO command.
    /// RFC 1459: Parameters: [<name> [<o>]]
    /// RFC 2812: Parameters: [ <mask> [ "o" ] ]
    ///    IRCZT: Parameters: <channel>
    fn _processCommand_WHO(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const name = self._acceptParam(lexer, "WHO", .Mandatory) catch return;
        self._acceptEndOfMessage(lexer, "WHO");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        const maybe_channel = self._user._server.lookupChannel(name);
        if (maybe_channel) |channel| {
            // Send RPL_WHOREPLY.
            const members = channel.getMembers();
            var member_iter = members.iterator();
            while (member_iter.next()) |member_node| {
                const member = member_node.key();
                self._sendMessage(
                    &ec,
                    ":{} 352 {} {} {} hidden {} {} H :0 {}",
                    .{
                        CE(hostname, &ec),
                        CE(nickname, &ec),
                        CE(name, &ec),
                        CE(member.getUserName(), &ec),
                        CE(hostname, &ec),
                        CE(member.getNickName(), &ec),
                        CE(member.getRealName(), &ec),
                    },
                );
            }
        }

        // Send RPL_ENDOFWHO.
        self._sendMessage(
            &ec,
            ":{} 315 {} {} :End of /WHO list",
            .{ CE(hostname, &ec), CE(nickname, &ec), CE(name, &ec) },
        );
    }

    /// Process the TOPIC command.
    /// RFC 1459: Parameters: <channel> [<topic>]
    /// RFC 2812: Parameters: <channel> [ <topic> ]
    ///    IRCZT: Parameters: <channel> [ <topic> ]
    fn _processCommand_TOPIC(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const channel_name = self._acceptParam(lexer, "TOPIC", .Mandatory) catch return;
        const maybe_topic = self._acceptParam(lexer, "TOPIC", .Optional) catch null;
        self._acceptEndOfMessage(lexer, "TOPIC");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        const channel = self._user._server.lookupChannel(channel_name) orelse {
            // Send ERR_NOSUCHCHANNEL.
            self._sendMessage(
                &ec,
                ":{} 403 {} {} :No such channel",
                .{ CE(hostname, &ec), CE(nickname, &ec), CE(channel_name, &ec) },
            );
            return;
        };

        channel.topicate(&self._user, maybe_topic) catch |err| {
            self._sendMessage(
                null,
                "ERROR :TOPIC command failed on the server: {}",
                .{@errorName(err)},
            );
            return err;
        };
    }

    /// Process the PRIVMSG command.
    /// RFC 1459: Parameters: <receiver>{,<receiver>} <text to be sent>
    /// RFC 2812: Parameters: <msgtarget> <text to be sent>
    ///    IRCZT: Parameters: <msgtarget> <text to be sent>
    fn _processCommand_PRIVMSG(self: *Client, lexer: *Lexer) !void {
        self._checkRegistered() catch return;

        const msgtarget = self._acceptParam(lexer, "PRIVMSG", .Mandatory) catch return;
        const text = self._acceptParam(lexer, "PRIVMSG", .Mandatory) catch return;
        self._acceptEndOfMessage(lexer, "PRIVMSG");

        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        var sub_lexer = Lexer.init(msgtarget);
        while (sub_lexer.readListItem()) |msgto| {
            // Try matching msgto with a channel name.
            const maybe_channel = self._user._server.lookupChannel(msgto);
            if (maybe_channel) |channel| {
                channel.sendPrivMsg(&self._user, text);
                continue;
            }

            // Try matching msgto with a user nick.
            const maybe_user = self._user._server.lookupUser(msgto);
            if (maybe_user) |user| {
                user.sendPrivMsg(nickname, msgto, text);
                continue;
            }

            // Send ERR_NOSUCHNICK.
            self._sendMessage(
                &ec,
                ":{} 401 {} {} :No such nick/channel",
                .{ CE(hostname, &ec), CE(nickname, &ec), CE(msgto, &ec) },
            );
        }
    }

    /// Process a single message from the client.
    fn _processMessage(self: *Client, message: []const u8) !void {
        var lexer = Lexer.init(message);
        const hostname = self._user._server.getHostName();
        const nickname = self._user.getNickName();
        var ec: bool = undefined;

        // Parse any prefix. If it is present then check it matches the current nickname as that is
        // the only allowed prefix for clients.
        if (lexer.getCurChar() == ':') {
            const prefix = lexer.readWord() orelse unreachable;
            if (!mem.eql(u8, prefix[1..], nickname)) {
                self._sendMessage(null, "ERROR :Message prefix does not match the nickname", .{});
                return Client.InputError.MalformedMessage;
            }
        }

        // Parse the command name.
        const command = lexer.readWord() orelse {
            self._sendMessage(null, "ERROR :No command specified in the message", .{});
            return Client.InputError.MalformedMessage;
        };

        // Process the command.
        if (mem.eql(u8, command, "NICK")) {
            try self._processCommand_NICK(&lexer);
        } else if (mem.eql(u8, command, "USER")) {
            try self._processCommand_USER(&lexer);
        } else if (mem.eql(u8, command, "QUIT")) {
            try self._processCommand_QUIT(&lexer);
        } else if (mem.eql(u8, command, "LIST")) {
            try self._processCommand_LIST(&lexer);
        } else if (mem.eql(u8, command, "JOIN")) {
            try self._processCommand_JOIN(&lexer);
        } else if (mem.eql(u8, command, "PART")) {
            try self._processCommand_PART(&lexer);
        } else if (mem.eql(u8, command, "WHO")) {
            try self._processCommand_WHO(&lexer);
        } else if (mem.eql(u8, command, "TOPIC")) {
            try self._processCommand_TOPIC(&lexer);
        } else if (mem.eql(u8, command, "PRIVMSG")) {
            try self._processCommand_PRIVMSG(&lexer);
        } else {
            // Send ERR_UNKNOWNCOMMAND.
            self._sendMessage(
                &ec,
                ":{} 421 {} {} :Unknown command",
                .{ self._user._server.getHostName(), CE(nickname, &ec), CE(command, &ec) },
            );
        }
    }

    /// Read new input available on the client's socket and process it. When an error is returned,
    /// no further calls to processInput() are allowed and the client should be destroyed.
    fn processInput(self: *Client) !void {
        assert(self._input_received < self._input_buffer.len);
        var pos = self._input_received;
        const read = self._file_reader.read(self._input_buffer[pos..]) catch |err| {
            self._warn(
                "Failed to read input from the client's socket (fd '{}'): {}.\n",
                .{ self._file_reader.context.handle, @errorName(err) },
            );
            return err;
        };
        if (read == 0) {
            // End of file reached.
            self._info("Client disconnected.\n", .{});
            return Client.InputError.EndOfFile;
        }
        self._input_received += read;

        var message_begin: usize = 0;
        while (pos < self._input_received) : (pos += 1) {
            const char = self._input_buffer[pos];
            switch (self._input_state) {
                .Normal => {
                    if (char == '\r') {
                        self._input_state = .Normal_CR;
                    }
                },
                .Normal_CR => {
                    if (char == '\n') {
                        const message = self._input_buffer[message_begin .. pos - 1];
                        self._info("< {}\n", .{E(message)});
                        try self._processMessage(message);
                        self._input_state = .Normal;
                        message_begin = pos + 1;
                    } else {
                        self._info("< {}\n", .{E(self._input_buffer[message_begin .. pos + 1])});
                        self._sendMessage(
                            null,
                            "ERROR :Message is not terminated by the \\r\\n pair",
                            .{},
                        );
                        return Client.InputError.MalformedMessage;
                    }
                },
            }
        }

        if (message_begin >= self._input_received) {
            assert(message_begin == self._input_received);
            self._input_received = 0;
        } else if (message_begin == 0 and self._input_received == self._input_buffer.len) {
            self._info("< {}\n", .{E(self._input_buffer[0..])});
            self._sendMessage(null, "ERROR :Message is too long", .{});
            return Client.InputError.MalformedMessage;
        } else {
            mem.copy(
                u8,
                self._input_buffer[0..],
                self._input_buffer[message_begin..self._input_received],
            );
            self._input_received -= message_begin;
        }
    }

    /// Send a private message to the client.
    fn _sendPrivMsg(self: *Client, from: []const u8, to: []const u8, text: []const u8) void {
        var ec: bool = undefined;

        self._sendMessage(
            &ec,
            ":{} PRIVMSG {} :{}",
            .{ CE(from, &ec), CE(to, &ec), CE(text, &ec) },
        );
    }

    /// Send an IRC protocol message to the client.
    fn _sendMessage(
        self: *Client,
        maybe_escape_cond: ?*bool,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (maybe_escape_cond) |escape_cond| {
            escape_cond.* = true;
        }
        self._info("> " ++ fmt ++ "\n", args);
        if (maybe_escape_cond) |escape_cond| {
            escape_cond.* = false;
        }
        self._file_writer.print(fmt ++ "\r\n", args) catch |err| {
            self._warn(
                "Failed to write the message into the client's socket (fd '{}'): {}.\n",
                .{ self._file_writer.context.handle, @errorName(err) },
            );
        };
    }
};

const ClientSet = avl.Map(*Client, void, avl.getLessThanFn(*Client));

/// Local bot which simulates a user.
const LocalBot = struct {
    /// User definition.
    _user: User,

    /// Number of channels that the bot should try to be in.
    _channels_target: u8,

    /// Probability that the bot leaves a channel at each tick.
    _channels_leave_rate: f32,

    /// Number of sent messages per each tick in every joined channel.
    _message_rate: f32,

    /// Average message length.
    _message_length: u8,

    /// Create a new LocalBot instance.
    fn create(
        nickname: []const u8,
        channels_target: u8,
        channels_leave_rate: f32,
        message_rate: f32,
        message_length: u8,
        server: *Server,
    ) !*LocalBot {
        info("{}: Creating the local bot.\n", .{E(nickname)});

        const allocator = server.getAllocator();
        const local_bot = allocator.create(LocalBot) catch |err| {
            warn(
                "{}: Failed to allocate a local bot instance: {}.\n",
                .{ E(nickname), @errorName(err) },
            );
            return err;
        };
        local_bot.* = LocalBot{
            ._user = User.init(.LocalBot, server),
            ._channels_target = channels_target,
            ._channels_leave_rate = channels_leave_rate,
            ._message_rate = message_rate,
            ._message_length = message_length,
        };
        return local_bot;
    }

    /// Destroy the local bot.
    fn destroy(self: *LocalBot) void {
        self._info("Destroying the local bot.\n", .{});

        const allocator = self._user._server.getAllocator();
        self._user.deinit();
        allocator.destroy(self);
    }

    /// Get a LocalBot base pointer given a pointer to its embedded User member.
    fn fromUser(user: *User) *LocalBot {
        assert(user._type == .LocalBot);
        return @fieldParentPtr(LocalBot, "_user", user);
    }

    /// Get a const LocalBot base pointer given a const pointer to its embedded User member.
    fn fromConstUser(user: *const User) *const LocalBot {
        assert(user._type == .LocalBot);
        return @fieldParentPtr(LocalBot, "_user", user);
    }

    /// Format and print an info message on the standard output.
    fn _info(self: *const LocalBot, comptime fmt: []const u8, args: anytype) void {
        const nickname = E(self._user.getNickName());
        info("{}: " ++ fmt, .{nickname} ++ args);
    }

    /// Format and print a warning message on the standard error output.
    fn _warn(self: *const LocalBot, comptime fmt: []const u8, args: anytype) void {
        const nickname = E(self._user.getNickName());
        warn("{}: " ++ fmt, .{nickname} ++ args);
    }

    /// Simulate the NICK registration command.
    fn register_NICK(self: *LocalBot, nickname: []const u8) !void {
        return self._user._nick(nickname);
    }

    /// Simulate the USER registration command.
    fn register_USER(self: *LocalBot, username: []const u8, realname: []const u8) !void {
        return self._user._user(username, realname);
    }

    /// Join the bot's desired number of channels.
    fn _tick_joinChannels(self: *LocalBot) void {
        const joined = self._user._channels.count();
        if (self._channels_target <= joined) {
            return;
        }

        var needed = self._channels_target - joined;
        const server_channels = self._user._server.getChannels();
        var left = server_channels.count() - joined;
        const rng = self._user._server.getRNG();

        var server_channel_iter = server_channels.iterator();
        while (server_channel_iter.next()) |server_channel_node| {
            const server_channel = server_channel_node.value();

            // Skip this channel if the bot is already in it.
            const user_channel_iter = self._user._channels.find(server_channel);
            if (user_channel_iter.valid()) {
                continue;
            }

            const join_probability: f32 = @intToFloat(f32, needed) / @intToFloat(f32, left);
            if (rng.float(f32) < join_probability) {
                self._user._joinChannel(server_channel) catch {};
                needed -= 1;
                if (needed == 0) {
                    break;
                }
            }
            left -= 1;
        }
    }

    /// Process joined channels and leave them randomly at a specific rate.
    fn _tick_partChannels(self: *LocalBot) void {
        const rng = self._user._server.getRNG();

        var channel_iter = self._user._channels.iterator();
        while (channel_iter.valid()) {
            const channel = channel_iter.key();
            _ = channel_iter.next();

            if (rng.float(f32) < self._channels_leave_rate) {
                self._user._partChannel(channel, self._user.getNickName());
            }
        }
    }

    /// Send random messages to joined channels at a specific rate.
    fn _tick_sendMessages(self: *LocalBot) void {
        const rng = self._user._server.getRNG();
        const word_bank = self._user._server.getWordBank();

        var channel_iter = self._user._channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.key();
            if (rng.float(f32) >= self._message_rate) {
                continue;
            }

            // Generate a random message.
            var needed = rng.intRangeAtMost(u8, 1, 2 * self._message_length - 1);
            var message_buffer: [1024]u8 = undefined;
            var at: usize = 0;
            while (needed > 0) : (needed -= 1) {
                const word_index = rng.uintLessThan(usize, word_bank.len);
                const word = word_bank[word_index];

                if (message_buffer.len - at < 1 + word.len) {
                    break;
                }

                if (at != 0) {
                    message_buffer[at] = ' ';
                    at += 1;
                }
                mem.copy(u8, message_buffer[at..], word);
                at += word.len;
            }

            // Send the message to the channel.
            channel.sendPrivMsg(&self._user, message_buffer[0..at]);
        }
    }

    /// Run the bot's intelligence.
    fn tick(self: *LocalBot) void {
        self._tick_joinChannels();
        self._tick_partChannels();
        self._tick_sendMessages();
    }
};

const LocalBotSet = avl.Map(*LocalBot, void, avl.getLessThanFn(*LocalBot));

const Channel = struct {
    /// Parent server.
    _server: *Server,

    /// Channel name (owned).
    _name: []const u8,

    /// Channel topic (owned).
    _topic: ?[]const u8,

    /// Users in the channel.
    _members: UserSet,

    /// Create a new Channel instance.
    fn create(name: []const u8, server: *Server) !*Channel {
        info("{}: Creating the channel.\n", .{E(name)});

        const allocator = server.getAllocator();

        // Make a copy of the name string.
        const name_copy = allocator.alloc(u8, name.len) catch |err| {
            warn(
                "{}: Failed to allocate a channel name storage with size of '{}' bytes: {}.\n",
                .{ E(name), name.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(name_copy);
        mem.copy(u8, name_copy, name);

        // Allocate a channel instance.
        const channel = allocator.create(Channel) catch |err| {
            warn(
                "{}: Failed to allocate a channel instance: {}.\n",
                .{ E(name), @errorName(err) },
            );
            return err;
        };
        channel.* = Channel{
            ._server = server,
            ._name = name_copy,
            ._topic = null,
            ._members = UserSet.init(allocator),
        };
        return channel;
    }

    /// Destroy the channel. All members need to leave prior to calling this function.
    fn destroy(self: *Channel) void {
        self._info("Destroying the channel.\n", .{});

        const allocator = self._server.getAllocator();
        allocator.free(self._name);
        if (self._topic) |topic| {
            allocator.free(topic);
        }

        // Channels can be destroyed only after all users leave.
        assert(self._members.count() == 0);
        self._members.deinit();

        allocator.destroy(self);
    }

    /// Obtain the channel name.
    fn getName(self: *const Channel) []const u8 {
        return self._name;
    }

    /// Obtain a topic set in the channel.
    fn getTopic(self: *const Channel) []const u8 {
        return if (self._topic) |topic| topic else "";
    }

    /// Obtain a set of users currently present in the channel.
    fn getMembers(self: *const Channel) *const UserSet {
        return &self._members;
    }

    /// Format and print an info message on the standard output.
    fn _info(self: *const Channel, comptime fmt: []const u8, args: anytype) void {
        const name = E(self._name);
        info("{}: " ++ fmt, .{name} ++ args);
    }

    /// Format and print a warning message on the standard error output.
    fn _warn(self: *const Channel, comptime fmt: []const u8, args: anytype) void {
        const name = E(self._name);
        warn("{}: " ++ fmt, .{name} ++ args);
    }

    /// Send information about the current topic to a specified user.
    fn _sendTopic(self: *const Channel, user: *User) void {
        const nickname = user.getNickName();
        const hostname = self._server.getHostName();
        var ec: bool = undefined;

        if (self._topic) |topic| {
            // Send RPL_TOPIC.
            user.sendMessage(
                &ec,
                ":{} 332 {} {} :{}",
                .{
                    CE(hostname, &ec),
                    CE(nickname, &ec),
                    CE(self._name, &ec),
                    CE(topic, &ec),
                },
            );
        } else {
            // Send RPL_NOTOPIC.
            user.sendMessage(
                &ec,
                ":{} 331 {} {} :No topic is set",
                .{ CE(hostname, &ec), CE(nickname, &ec), CE(self._name, &ec) },
            );
        }
    }

    /// Process join from a user. Note that it is a caller's responsibility to make sure that the
    /// user is not already in the channel.
    fn join(self: *Channel, user: *User) !void {
        const user_iter = self._members.insert(user, {}) catch |err| {
            self._warn(
                "Failed to insert user '{}' in the channel user set: {}.\n",
                .{ E(user.getNickName()), @errorName(err) },
            );
            return err;
        };
        errdefer self._members.remove(user_iter);

        const nickname = user.getNickName();
        const hostname = self._server.getHostName();
        var ec: bool = undefined;

        self._info(
            "User '{}' joined the channel (now at '{}' users).\n",
            .{ E(nickname), self._members.count() },
        );

        // Inform all members about the join.
        var member_iter = self._members.iterator();
        while (member_iter.next()) |member_node| {
            const member = member_node.key();
            member.sendMessage(
                &ec,
                ":{} JOIN {}",
                .{ CE(nickname, &ec), CE(self._name, &ec) },
            );
        }

        // Send information about the channel topic.
        self._sendTopic(user);

        // Send RPL_NAMREPLY.
        member_iter = self._members.iterator();
        while (member_iter.next()) |member_node| {
            const member = member_node.key();
            const member_nickname = member.getNickName();
            user.sendMessage(
                &ec,
                ":{} 353 {} = {} :{}",
                .{
                    CE(hostname, &ec),
                    CE(nickname, &ec),
                    CE(self._name, &ec),
                    CE(member_nickname, &ec),
                },
            );
        }
        // Send RPL_ENDOFNAMES.
        user.sendMessage(
            &ec,
            ":{} 366 {} {} :End of /NAMES list",
            .{ CE(hostname, &ec), CE(nickname, &ec), CE(self._name, &ec) },
        );
    }

    /// Process leave from a user.
    fn part(self: *Channel, user: *User, part_message: []const u8) void {
        const nickname = user.getNickName();
        var ec: bool = undefined;

        // Inform all members about the leave.
        var member_iter = self._members.iterator();
        while (member_iter.next()) |member_node| {
            const member = member_node.key();
            member.sendMessage(
                &ec,
                ":{} PART {} :{}",
                .{ CE(nickname, &ec), CE(self._name, &ec), CE(part_message, &ec) },
            );
        }

        const user_iter = self._members.find(user);
        assert(user_iter.valid());
        self._members.remove(user_iter);

        self._info(
            "User '{}' parted the channel (now at '{}' users).\n",
            .{ E(nickname), self._members.count() },
        );
    }

    /// Process quit from a user.
    fn quit(self: *Channel, user: *User) void {
        // Note that members are not informed about the user leaving. It is a responsibility of the
        // caller to send this information to all relevant users.
        const user_iter = self._members.find(user);
        assert(user_iter.valid());
        self._members.remove(user_iter);

        self._info(
            "User '{}' quit the channel (now at '{}' users).\n",
            .{ E(user.getNickName()), self._members.count() },
        );
    }

    /// Set/query the channel topic.
    fn topicate(self: *Channel, user: *User, maybe_topic: ?[]const u8) !void {
        if (maybe_topic) |topic| {
            // The user sets a new topic.
            const allocator = self._server.getAllocator();

            var maybe_new_topic: ?[]const u8 = undefined;
            if (topic.len != 0) {
                // Make a copy of the topic string.
                const topic_copy = allocator.alloc(u8, topic.len) catch |err| {
                    self._warn(
                        "Failed to allocate a topic storage with size of '{}' bytes: {}.\n",
                        .{ topic.len, @errorName(err) },
                    );
                    return err;
                };
                errdefer allocator.free(topic_copy);
                mem.copy(u8, topic_copy, topic);

                maybe_new_topic = topic_copy;
            } else {
                maybe_new_topic = null;
            }

            if (self._topic) |old_topic| {
                allocator.free(old_topic);
            }
            self._topic = maybe_new_topic;

            // Inform all members about the new topic.
            var member_iter = self._members.iterator();
            while (member_iter.next()) |member_node| {
                const member = member_node.key();
                self._sendTopic(member);
            }
            return;
        }

        // The user queries the current topic.
        self._sendTopic(user);
    }

    /// Send a message to all users in the channel.
    fn sendPrivMsg(self: *Channel, user: *const User, text: []const u8) void {
        const from_name = user.getNickName();
        var member_iter = self._members.iterator();
        while (member_iter.next()) |member_node| {
            const member = member_node.key();
            member.sendPrivMsg(from_name, self._name, text);
        }
    }
};

const ChannelSet = avl.Map(*Channel, void, avl.getLessThanFn(*Channel));

const ChannelNameSet = avl.Map([]const u8, *Channel, avl.getLessThanFn([]const u8));

const Server = struct {
    /// Memory allocator, used by the server and related channel+user objects.
    _allocator: *mem.Allocator,

    /// Random number generator.
    _rng: *rand.Random,

    /// Word bank for use by local bots.
    _word_bank: []const []const u8,

    /// Socket address.
    _sockaddr: net.Address,

    /// Host name (owned).
    _host: []const u8,

    /// Port number (owned).
    _port: []const u8,

    /// All remote clients (owned).
    _clients: ClientSet,

    /// All local bots (owned).
    _local_bots: LocalBotSet,

    /// Users with a valid name (owned). This is a subset of _clients and _local_bots. Keys
    /// (nicknames) are owned by respective User instances.
    _users: UserNameSet,

    /// All channels (owned). Keys (names) are owned by respective Channel instances.
    _channels: ChannelNameSet,

    /// Create a new Server instance.
    fn create(
        address: []const u8,
        word_bank: []const []const u8,
        allocator: *mem.Allocator,
        rng: *rand.Random,
    ) !*Server {
        // Parse the address.
        var host_end: usize = address.len;
        var port_start: usize = address.len;
        for (address) |char, i| {
            if (char == ':') {
                host_end = i;
                port_start = i + 1;
                break;
            }
        }

        const host = address[0..host_end];
        const port = address[port_start..address.len];

        const parsed_port = std.fmt.parseUnsigned(u16, port, 10) catch |err| {
            warn("Failed to parse port number '{}': {}.\n", .{ port, @errorName(err) });
            return err;
        };

        const parsed_address = net.Address.parseIp4(host, parsed_port) catch |err| {
            warn("Failed to parse IP address '{}:{}': {}.\n", .{ host, port, @errorName(err) });
            return err;
        };

        // Make a copy of the host and port strings.
        const host_copy = allocator.alloc(u8, host.len) catch |err| {
            warn(
                "Failed to allocate a hostname storage with size of '{}' bytes: {}.\n",
                .{ host.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(host_copy);
        mem.copy(u8, host_copy, host);

        const port_copy = allocator.alloc(u8, port.len) catch |err| {
            warn(
                "Failed to allocate a port storage with size of '{}' bytes: {}.\n",
                .{ port.len, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(port_copy);
        mem.copy(u8, port_copy, port);

        // Allocate the server struct.
        const server = allocator.create(Server) catch |err| {
            warn("Failed to allocate a server instance: {}.\n", .{@errorName(err)});
            return err;
        };
        server.* = Server{
            ._allocator = allocator,
            ._rng = rng,
            ._word_bank = word_bank,
            ._sockaddr = parsed_address,
            ._host = host_copy,
            ._port = port_copy,
            ._clients = ClientSet.init(allocator),
            ._local_bots = LocalBotSet.init(allocator),
            ._users = UserNameSet.init(allocator),
            ._channels = ChannelNameSet.init(allocator),
        };
        return server;
    }

    /// Destroy the server, including all associated users and channels.
    fn destroy(self: *Server) void {
        // Destroy all clients.
        var client_iter = self._clients.iterator();
        while (client_iter.next()) |client_node| {
            const client = client_node.key();
            client.destroy();
        }
        self._clients.deinit();

        // Destroy all local bots.
        var local_bot_iter = self._local_bots.iterator();
        while (local_bot_iter.next()) |local_bot_node| {
            const local_bot = local_bot_node.key();
            local_bot.destroy();
        }
        self._local_bots.deinit();

        self._users.deinit();

        // Destroy all channels.
        var channel_iter = self._channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.value();
            channel.destroy();
        }
        self._channels.deinit();

        self._allocator.free(self._host);
        self._allocator.free(self._port);
        self._allocator.destroy(self);
    }

    /// Obtain the memory allocator.
    fn getAllocator(self: *Server) *mem.Allocator {
        return self._allocator;
    }

    /// Obtain the random number generator.
    fn getRNG(self: *Server) *rand.Random {
        return self._rng;
    }

    /// Obtain the word bank.
    fn getWordBank(self: *const Server) []const []const u8 {
        return self._word_bank;
    }

    /// Obtain the server's hostname.
    fn getHostName(self: *const Server) []const u8 {
        return self._host;
    }

    /// Obtain registered users on the server.
    fn getUsers(self: *Server) *const UserNameSet {
        return &self._users;
    }

    /// Obtain channels on the server.
    fn getChannels(self: *Server) *const ChannelNameSet {
        return &self._channels;
    }

    /// Run the server.
    fn run(self: *Server) !void {
        // Create the server socket.
        const listenfd = os.socket(
            os.AF_INET,
            os.SOCK_STREAM | os.SOCK_CLOEXEC,
            os.IPPROTO_TCP,
        ) catch |err| {
            warn("Failed to create a server socket: {}.\n", .{@errorName(err)});
            return err;
        };
        defer os.close(listenfd);

        os.bind(listenfd, &self._sockaddr.any, self._sockaddr.getOsSockLen()) catch |err| {
            warn(
                "Failed to bind to address '{}:{}': {}.\n",
                .{ self._host, self._port, @errorName(err) },
            );
            return err;
        };

        os.listen(listenfd, os.SOMAXCONN) catch |err| {
            warn(
                "Failed to listen on '{}:{}': {}.\n",
                .{ self._host, self._port, @errorName(err) },
            );
            return err;
        };

        // Create an epoll instance.
        const epfd = os.epoll_create1(os.EPOLL_CLOEXEC) catch |err| {
            warn("Failed to create an epoll instance: {}.\n", .{@errorName(err)});
            return err;
        };
        defer os.close(epfd);

        // Register the server socket with the epoll instance.
        var listenfd_event = os.epoll_event{
            .events = os.EPOLLIN,
            .data = os.epoll_data{ .ptr = 0 },
        };
        os.epoll_ctl(epfd, os.EPOLL_CTL_ADD, listenfd, &listenfd_event) catch |err| {
            warn(
                "Failed to add the server socket (fd '{}') to the epoll instance: {}.\n",
                .{ listenfd, @errorName(err) },
            );
            return err;
        };

        // Register the standard input with the epoll instance.
        var stdinfd_event = os.epoll_event{
            .events = os.EPOLLIN,
            .data = os.epoll_data{ .ptr = 1 },
        };
        os.epoll_ctl(epfd, os.EPOLL_CTL_ADD, os.STDIN_FILENO, &stdinfd_event) catch |err| {
            warn(
                "Failed to add the standard input (fd '{}') to the epoll instance: {}.\n",
                .{ os.STDIN_FILENO, @errorName(err) },
            );
            return err;
        };

        // Listen for events.
        info("Listening on '{}:{}'.\n", .{ self._host, self._port });

        var next_bot_tick = time.milliTimestamp();
        while (true) {
            var timeout = next_bot_tick - time.milliTimestamp();

            // Run the local bot ticks if it is time.
            if (timeout <= 0) {
                var local_bot_iter = self._local_bots.iterator();
                while (local_bot_iter.next()) |local_bot_node| {
                    const local_bot = local_bot_node.key();
                    local_bot.tick();
                }

                timeout = 1000;
                next_bot_tick = time.milliTimestamp() + timeout;
            }

            // Wait for a next event.
            var events: [1]os.epoll_event = undefined;
            assert(timeout <= 1000);
            const ep = os.epoll_wait(epfd, events[0..], @intCast(i32, timeout));
            if (ep == 0) {
                continue;
            }

            // Handle the event.
            switch (events[0].data.ptr) {
                0 => self._acceptClient(epfd, listenfd),
                1 => {
                    // Exit on any input on stdin.
                    info("Exit request from the standard input.\n", .{});
                    break;
                },
                else => self._processInput(epfd, @intToPtr(*Client, events[0].data.ptr)),
            }
        }
    }

    /// Accept a new client connection.
    fn _acceptClient(self: *Server, epfd: i32, listenfd: i32) void {
        var client_sockaddr: os.sockaddr align(4) = undefined;
        var client_socklen: os.socklen_t = @sizeOf(@TypeOf(client_sockaddr));
        const clientfd = os.accept(
            listenfd,
            &client_sockaddr,
            &client_socklen,
            os.SOCK_CLOEXEC,
        ) catch |err| {
            warn("Failed to accept a new client connection: {}.\n", .{@errorName(err)});
            return;
        };

        const client_addr = net.Address.initPosix(&client_sockaddr);

        // Create a new client. This transfers ownership of the clientfd to the Client
        // instance.
        const client = Client.create(clientfd, client_addr, self) catch return;
        errdefer client.destroy();

        const client_iter = self._clients.insert(client, {}) catch |err| {
            warn(
                "Failed to insert client '{}' in the main client set: {}.\n",
                .{ client_addr, @errorName(err) },
            );
            return;
        };
        errdefer self._clients.remove(client_iter);

        // Listen for the client.
        var clientfd_event = os.epoll_event{
            .events = os.EPOLLIN,
            .data = os.epoll_data{ .ptr = @ptrToInt(client) },
        };
        os.epoll_ctl(epfd, os.EPOLL_CTL_ADD, clientfd, &clientfd_event) catch |err| {
            warn(
                "Failed to add socket (fd '{}') of client '{}' to the epoll instance: {}.\n",
                .{ clientfd, client_addr, @errorName(err) },
            );
            return;
        };
    }

    /// Process input from a client.
    fn _processInput(self: *Server, epfd: i32, client: *Client) void {
        client.processInput() catch {
            // The client quit or a critical error occurred. Destroy the client now.
            const clientfd = client.getFileDescriptor();
            os.epoll_ctl(epfd, os.EPOLL_CTL_DEL, clientfd, undefined) catch unreachable;

            const user = client.toUser();
            if (user.hasNickName()) {
                const user_iter = self._users.find(user.getNickName());
                assert(user_iter.valid());
                self._users.remove(user_iter);
            }

            const client_iter = self._clients.find(client);
            assert(client_iter.valid());
            self._clients.remove(client_iter);

            client.destroy();
        };
    }

    /// Process a nickname change. Note that it is a caller's responsibility to make sure that this
    /// name does not duplicate a nickname of another user on the server.
    fn recordNickNameChange(
        self: *Server,
        user: *User,
        maybe_old_nickname: ?[]const u8,
        new_nickname: []const u8,
    ) !void {
        _ = self._users.insert(new_nickname, user) catch |err| {
            warn(
                "Failed to insert user '{}' in the named user set: {}.\n",
                .{ E(new_nickname), @errorName(err) },
            );
            return err;
        };

        if (maybe_old_nickname) |old_nickname| {
            const user_iter = self._users.find(old_nickname);
            assert(user_iter.valid());
            self._users.remove(user_iter);
        }
    }

    /// Find a user that has a specified nickname.
    fn lookupUser(self: *Server, name: []const u8) ?*User {
        const user_iter = self._users.find(name);
        return if (user_iter.valid()) user_iter.value() else null;
    }

    /// Create a new channel with a specified name.
    fn createChannel(self: *Server, name: []const u8) !void {
        const channel = try Channel.create(name, self);
        errdefer channel.destroy();

        const channel_iter = self._channels.insert(channel.getName(), channel) catch |err| {
            warn(
                "Failed to insert channel '{}' in the main channel set: {}.\n",
                .{ E(name), @errorName(err) },
            );
            return err;
        };
    }

    /// Find a channel that has a specified name.
    fn lookupChannel(self: *Server, name: []const u8) ?*Channel {
        const channel_iter = self._channels.find(name);
        return if (channel_iter.valid()) channel_iter.value() else null;
    }

    /// Create a new local bot with a specified name.
    fn createLocalBot(
        self: *Server,
        nickname: []const u8,
        channels_target: u8,
        channels_leave_rate: f32,
        message_rate: f32,
        message_length: u8,
    ) !void {
        const local_bot = try LocalBot.create(
            nickname,
            channels_target,
            channels_leave_rate,
            message_rate,
            message_length,
            self,
        );
        errdefer local_bot.destroy();

        const local_bot_iter = self._local_bots.insert(local_bot, {}) catch |err| {
            warn(
                "Failed to insert local bot '{}' in the main local bot set: {}.\n",
                .{ E(nickname), @errorName(err) },
            );
            return err;
        };
        errdefer self._local_bots.remove(local_bot_iter);

        // Perform the registration process.
        try local_bot.register_NICK(nickname);
        try local_bot.register_USER(nickname, nickname);

        // Run the initial tick.
        local_bot.tick();
    }
};

/// Select a random number from a specified range.
fn selectFromConfigRange(rng: *rand.Random, comptime T: type, range: *const config.Range(T)) T {
    switch (T) {
        u8 => {
            return rng.intRangeAtMost(u8, range.min, range.max);
        },
        f32 => {
            return range.min + (range.max - range.min) * rng.float(f32);
        },
        else => @compileError("Unhandled select type"),
    }
}

pub fn main() u8 {
    // Ignore SIGPIPE.
    const sa = os.Sigaction{
        .sigaction = os.linux.SIG_IGN,
        .mask = os.empty_sigset,
        .flags = 0,
    };
    os.sigaction(os.SIGPIPE, &sa, null);

    // Get an allocator.
    var gp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gp_allocator.deinit()) {
        warn("Memory leaks detected on exit.\n", .{});
    };

    // Initialize a random number generator.
    var rand_buffer: [8]u8 = undefined;
    std.crypto.randomBytes(rand_buffer[0..]) catch |err| {
        warn(
            "Failed to obtain random bytes to initialize a random number generator: {}.\n",
            .{@errorName(err)},
        );
        return 1;
    };
    const seed = mem.readIntLittle(u64, rand_buffer[0..8]);
    var prng = rand.DefaultPrng.init(seed);

    // Create the server.
    const server = Server.create(
        config.address,
        &config.word_bank,
        &gp_allocator.allocator,
        &prng.random,
    ) catch return 1;
    defer server.destroy();

    // Create pre-defined channels.
    for (config.channels) |channel| {
        server.createChannel(channel) catch return 1;
    }

    // Create artificial users.
    const rng = &prng.random;
    for (config.local_bots) |local_bot| {
        server.createLocalBot(
            local_bot,
            selectFromConfigRange(rng, u8, &config.bot_channels_target),
            selectFromConfigRange(rng, f32, &config.bot_channels_leave_rate),
            selectFromConfigRange(rng, f32, &config.bot_message_rate),
            selectFromConfigRange(rng, u8, &config.bot_message_length),
        ) catch return 1;
    }

    // Run the server.
    server.run() catch return 1;
    return 0;
}
