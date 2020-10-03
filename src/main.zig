// Copyright (C) 2018 Petr Pavlu <setup@dagobah.cz>
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

/// Convert timestamp to a string.
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
            } else
                output[i - 1] = ' ';
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

/// Print a message on the standard output.
fn info(comptime fmt: []const u8, args: anytype) void {
    var timestamp: [timestamp_str_width]u8 = undefined;
    formatTimeStamp(&timestamp, @intCast(u64, time.milliTimestamp()));
    const writer = io.getStdOut().writer();
    writer.print("{} " ++ fmt, .{timestamp} ++ args) catch return;
}

/// Print a message on the standard error output.
fn warn(comptime fmt: []const u8, args: anytype) void {
    var timestamp: [timestamp_str_width]u8 = undefined;
    formatTimeStamp(&timestamp, @intCast(u64, time.milliTimestamp()));
    const writer = io.getStdErr().writer();
    writer.print("\x1b[31m{} " ++ fmt ++ "\x1b[0m", .{timestamp} ++ args) catch return;
}

/// Thin wrapper for character slices to output non-printable characters as escaped values with
/// std.fmt.
const EscapeFormatter = struct {
    _slice: []const u8,

    fn init(slice: []const u8) EscapeFormatter {
        return EscapeFormatter{ ._slice = slice };
    }

    fn getSlice(self: *const EscapeFormatter) []const u8 {
        return self._slice;
    }

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

/// Conditional escape provider.
const ConditionalEscapeFormatter = struct {
    _escape: EscapeFormatter,
    _cond: *bool,

    fn init(slice: []const u8, cond: *bool) ConditionalEscapeFormatter {
        return ConditionalEscapeFormatter{
            ._escape = EscapeFormatter.init(slice),
            ._cond = cond,
        };
    }

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

const Lexer = struct {
    _message: []const u8,
    _pos: usize,

    /// Construct a Lexer.
    fn init(message: []const u8) Lexer {
        return Lexer{
            ._message = message,
            ._pos = 0,
        };
    }

    /// Return the current position in the input message.
    fn getCurPos(self: *const Lexer) usize {
        return self._pos;
    }

    /// Return the current character.
    fn getCurChar(self: *const Lexer) u8 {
        if (self._pos < self._message.len) {
            return self._message[self._pos];
        }
        return 0;
    }

    /// Skip to a next character in the message.
    fn nextChar(self: *Lexer) void {
        if (self._pos < self._message.len) {
            self._pos += 1;
        }
    }

    /// Read one word from the message.
    fn readWord(self: *Lexer) []const u8 {
        const begin = self._pos;

        var end = begin;
        while (self.getCurChar() != '\x00' and self.getCurChar() != ' ') : (end += 1) {
            self.nextChar();
        }

        while (self.getCurChar() == ' ') {
            self.nextChar();
        }

        return self._message[begin..end];
    }

    /// Read one parameter from the message.
    fn readParam(self: *Lexer) []const u8 {
        if (self.getCurChar() == ':') {
            const begin = self._pos + 1;
            self._pos = self._message.len;
            return self._message[begin..self._pos];
        }
        return self.readWord();
    }
};

const User = struct {
    const Type = enum {
        Client,
        LocalBot,
    };

    _type: Type,

    _server: *Server,

    /// Unique nick name (owned).
    _nickname: []u8,

    /// User name (owned).
    _username: []u8,

    /// Real name (owned).
    _realname: []u8,

    /// Joined channels.
    _channels: ChannelSet,

    fn init(
        type_: Type,
        nickname: []const u8,
        username: []const u8,
        realname: []const u8,
        server: *Server,
        init_prefix: anytype,
    ) !User {
        const allocator = server.getAllocator();

        // Make a copy of the nickname string.
        const nickname_copy = allocator.alloc(u8, nickname.len) catch |err| {
            warn(
                "{}: Failed to allocate a nickname string buffer: {}.\n",
                .{ init_prefix, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(nickname_copy);
        mem.copy(u8, nickname_copy, nickname);

        // Make a copy of the username string.
        const username_copy = allocator.alloc(u8, username.len) catch |err| {
            warn(
                "{}: Failed to allocate a username string buffer: {}.\n",
                .{ init_prefix, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(username_copy);
        mem.copy(u8, username_copy, username);

        // Make a copy of the realname string.
        const realname_copy = allocator.alloc(u8, realname.len) catch |err| {
            warn(
                "{}: Failed to allocate a realname string buffer: {}.\n",
                .{ init_prefix, @errorName(err) },
            );
            return err;
        };
        errdefer allocator.free(realname_copy);
        mem.copy(u8, realname_copy, realname);

        return User{
            ._type = type_,
            ._server = server,
            ._nickname = nickname_copy,
            ._username = username_copy,
            ._realname = realname_copy,
            ._channels = ChannelSet.init(allocator),
        };
    }

    fn deinit(self: *User) void {
        const allocator = self._server.getAllocator();
        allocator.free(self._nickname);
        allocator.free(self._username);
        allocator.free(self._realname);
        self._channels.deinit();
    }

    fn getNickName(self: *const User) []const u8 {
        return self._nickname;
    }

    fn setNickName(self: *User, nickname: []const u8) !void {
        const allocator = self._server.getAllocator();

        // Make a copy of the nickname string.
        const nickname_copy = allocator.alloc(u8, nickname.len) catch |err| {
            self._warn("Failed to allocate a nickname string buffer: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(nickname_copy);
        mem.copy(u8, nickname_copy, nickname);

        // Set the new nickname.
        allocator.free(self._nickname);
        self._nickname = nickname_copy;
    }

    fn getUserName(self: *const User) []const u8 {
        return self._username;
    }

    fn getRealName(self: *const User) []const u8 {
        return self._realname;
    }

    fn setUserAndRealName(self: *User, username: []const u8, realname: []const u8) !void {
        const allocator = self._server.getAllocator();

        // Make a copy of the username string.
        const username_copy = allocator.alloc(u8, username.len) catch |err| {
            self._warn("Failed to allocate a username string buffer: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(username_copy);
        mem.copy(u8, username_copy, username);

        // Make a copy of the realname string.
        const realname_copy = allocator.alloc(u8, realname.len) catch |err| {
            self._warn("Failed to allocate a realname string buffer: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(realname_copy);
        mem.copy(u8, realname_copy, realname);

        // Set the new username and realname.
        allocator.free(self._username);
        self._username = username_copy;

        allocator.free(self._realname);
        self._realname = realname_copy;
    }

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

    /// Join a specified channel.
    fn _joinChannel(self: *User, channel: *Channel) !void {
        const channel_iter = self._channels.insert(channel, {}) catch |err| {
            self._warn(
                "Failed to insert channel {} in the channel set: {}.\n",
                .{ E(channel.getName()), @errorName(err) },
            );
            return err;
        };
        errdefer self._channels.remove(channel_iter);

        try channel.join(self);
    }

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

    fn sendPrivMsg(self: *User, from: []const u8, to: []const u8, text: []const u8) void {
        switch (self._type) {
            .Client => {
                return Client.fromUser(self)._sendPrivMsg(from, to, text);
            },
            .LocalBot => {
                // TODO Implement.
                //unreachable;
            },
        }
    }
};

const UserSet = avl.Map(*User, void, avl.getLessThanFn(*User));

/// Remote client.
const Client = struct {
    const InputState = enum {
        Normal,
        Normal_CR,
        Invalid,
        Invalid_CR,
    };
    const RegistrationState = enum {
        Init,
        HasUSER,
        HasNICK,
        Complete,
    };

    /// User definition.
    _user: User,

    _fd: i32,
    _addr: net.Address,

    _file_writer: fs.File.Writer,
    _file_reader: fs.File.Reader,

    _input_state: InputState,
    _input_buffer: [512]u8,
    _input_received: usize,

    /// Enum indicating whether the initial USER and NICK pair was already received and the client
    /// is fully joined.
    _registration_state: RegistrationState,

    /// Create a new client instance, which takes ownership for the passed client descriptor. If
    /// constructing the client fails, the file descriptor gets closed.
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
            ._user = try User.init(
                User.Type.Client,
                "<nickname-pending>",
                "<username-pending>",
                "<realname-pending>",
                server,
                addr,
            ),
            ._fd = fd,
            ._addr = addr,
            ._file_writer = file.writer(),
            ._file_reader = file.reader(),
            ._input_state = Client.InputState.Normal,
            ._input_buffer = undefined,
            ._input_received = 0,
            ._registration_state = RegistrationState.Init,
        };
        return client;
    }

    /// Close connection to a client and destroy the client data.
    fn destroy(self: *Client) void {
        self._info("Destroying the client.\n", .{});

        os.close(self._fd);
        self._info("Closed client connection.\n", .{});

        const allocator = self._user._server.getAllocator();
        self._user.deinit();
        allocator.destroy(self);
    }

    fn fromUser(user: *User) *Client {
        assert(user._type == User.Type.Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    fn fromConstUser(user: *const User) *const Client {
        assert(user._type == User.Type.Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    /// Get the clien file descriptor.
    fn getFileDescriptor(self: *const Client) i32 {
        return self._fd;
    }

    fn _info(self: *const Client, comptime fmt: []const u8, args: anytype) void {
        info("{}: " ++ fmt, .{self._addr} ++ args);
    }

    fn _warn(self: *const Client, comptime fmt: []const u8, args: anytype) void {
        warn("{}: " ++ fmt, .{self._addr} ++ args);
    }

    fn _acceptParamMax(self: *Client, lexer: *Lexer, param: []const u8, maxlen: usize) ![]const u8 {
        const begin = lexer.getCurPos();
        const res = lexer.readParam();
        if (res.len == 0) {
            self._warn("Position {}, expected parameter {}.\n", .{ begin + 1, param });
            return error.NeedsMoreParams;
        }
        if (res.len > maxlen) {
            self._warn(
                "Position {}, parameter {} is too long (maximum: {}, actual: {}).\n",
                .{ begin + 1, param, maxlen, res.len },
            );
            // IRC has no error reply for too long parameters, so cut-off the value.
            return res[0..maxlen];
        }
        return res;
    }

    fn _acceptParam(self: *Client, lexer: *Lexer, param: []const u8) ![]const u8 {
        return self._acceptParamMax(lexer, param, math.maxInt(usize));
    }

    /// Process the USER command.
    /// Parameters: <username> <hostname> <servername> <realname>
    fn _processCommand_USER(self: *Client, lexer: *Lexer) !void {
        if (self._registration_state == .HasUSER or self._registration_state == .Complete) {
            // TODO Log an error.
            return error.AlreadyRegistred;
        }

        const username = try self._acceptParam(lexer, "<username>");
        const hostname = try self._acceptParam(lexer, "<hostname>");
        const servername = try self._acceptParam(lexer, "<servername>");
        const realname = try self._acceptParam(lexer, "<realname>");
        // TODO Check there no more unexpected parameters.

        // TODO Report an error back to the client.
        try self._user.setUserAndRealName(username, realname);

        // Progress the registration state.
        switch (self._registration_state) {
            .Init => {
                self._registration_state = .HasUSER;
            },
            .HasNICK => {
                self._registration_state = .Complete;
                // Complete the join if the initial USER and NICK pair was already received.
                try self._completeRegistration();
            },
            .HasUSER, .Complete => {
                // States .HasUSER or .Complete are rejected earlier.
                unreachable;
            },
        }
    }

    /// Process the NICK command.
    /// Parameters: <nickname>
    fn _processCommand_NICK(self: *Client, lexer: *Lexer) !void {
        const nickname = self._acceptParamMax(lexer, "<nickname>", 9) catch |err| {
            if (err == error.NeedsMoreParams) {
                return error.NoNickNameGiven;
            } else {
                return err;
            }
        };
        // TODO Report an error back to the client.
        try self._user.setNickName(nickname);

        // TODO
        // ERR_ERRONEUSNICKNAME
        // ERR_NICKNAMEINUSE

        // TODO Check there no more unexpected parameters.

        // Progress the registration state.
        switch (self._registration_state) {
            .Init => {
                self._registration_state = .HasNICK;
            },
            .HasUSER => {
                self._registration_state = .Complete;
                // Complete the join if the initial USER and NICK pair was already received.
                try self._completeRegistration();
            },
            .HasNICK, .Complete => {
                // Do nothing for .HasNICK or .Complete. The NICK command is in this case not a part
                // of the initial registration process.
            },
        }
    }

    /// Complete the client join after the initial USER and NICK pair is received.
    fn _completeRegistration(self: *Client) !void {
        assert(self._registration_state == .Complete);

        const nickname = self._user.getNickName();
        const hostname = self._user._server.getHostName();
        var ec: bool = undefined;

        // Send RPL_LUSERCLIENT.
        // TODO Fix user count.
        self._sendMessage(
            &ec,
            ":{} 251 {} :There are {} users and 0 invisible on 1 servers",
            .{ hostname, CE(nickname, &ec), 1 },
        );

        // Send motd.
        self._sendMessage(
            &ec,
            ":{} 375 {} :- {} Message of the Day -",
            .{ hostname, CE(nickname, &ec), hostname },
        );
        self._sendMessage(
            &ec,
            ":{} 372 {} :- Welcome to the {} IRC network!",
            .{ hostname, CE(nickname, &ec), hostname },
        );
        self._sendMessage(
            &ec,
            ":{} 376 {} :End of /MOTD command.",
            .{ hostname, CE(nickname, &ec) },
        );

        self._sendMessage(&ec, ":irczt-connect PRIVMSG {} :Hello", .{CE(nickname, &ec)});
    }

    /// Check whether the user has completed the initial registration and is fully joined. If not
    /// then send ERR_NOTREGISTERED to the client and return error.NotRegistered.
    fn _checkRegistered(self: *Client) !void {
        if (self._registration_state == .Complete) {
            return;
        }
        self._sendMessage(
            null,
            ":{} 451 * :You have not registered",
            .{self._user._server.getHostName()},
        );
        return error.NotRegistered;
    }

    /// Process the LIST command.
    /// Parameters: [<channel>{,<channel>} [<server>]]
    fn _processCommand_LIST(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse the parameters.

        const nickname = self._user.getNickName();
        const hostname = self._user._server.getHostName();
        var ec: bool = undefined;

        // Send RPL_LISTSTART.
        self._sendMessage(
            &ec,
            ":{} 321 {} Channel :Users  Name",
            .{ hostname, CE(nickname, &ec) },
        );

        // Send RPL_LIST for each channel.
        const channels = self._user._server.getChannels();
        var channel_iter = channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.key();
            const name = channel.getName();
            const user_count = channel.getUserCount();
            self._sendMessage(
                &ec,
                ":{} 322 {} {} {} :",
                .{ hostname, CE(nickname, &ec), CE(name, &ec), user_count },
            );
        }

        // Send RPL_LISTEND.
        self._sendMessage(
            &ec,
            ":{} 323 {} :End of /LIST",
            .{ hostname, CE(nickname, &ec) },
        );
    }

    /// Process the JOIN command.
    /// Parameters: <channel>{,<channel>} [<key>{,<key>}]
    fn _processCommand_JOIN(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse all parameters.
        const channel_name = try self._acceptParam(lexer, "<channel>");

        const nickname = self._user.getNickName();
        const hostname = self._user._server.getHostName();
        var ec: bool = undefined;

        const channel = self._user._server.lookupChannel(channel_name) orelse {
            // Send ERR_NOSUCHCHANNEL.
            self._sendMessage(
                &ec,
                ":{} 403 {} {} :No such channel",
                .{ hostname, CE(nickname, &ec), CE(channel_name, &ec) },
            );
            return;
        };
        // TODO Report any error to the client.
        try self._user._joinChannel(channel);
    }

    /// Process the WHO command.
    /// Parameters: [<name> [<o>]]
    fn _processCommand_WHO(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse all parameters.
        const name = try self._acceptParam(lexer, "<name>");

        const nickname = self._user.getNickName();
        const hostname = self._user._server.getHostName();
        var ec: bool = undefined;

        // TODO Report any error to the client.
        const channel = self._user._server.lookupChannel(name) orelse return;
        channel.who(&self._user);
    }

    /// Process the PRIVMSG command.
    /// Parameters: <receiver>{,<receiver>} <text to be sent>
    fn _processCommand_PRIVMSG(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse all parameters.
        const receiver_name = try self._acceptParam(lexer, "<receiver>");
        const text = try self._acceptParam(lexer, "<text to be sent>");

        const nickname = self._user.getNickName();
        const hostname = self._user._server.getHostName();
        var ec: bool = undefined;

        // TODO Handle messages to users too.
        const channel = self._user._server.lookupChannel(receiver_name) orelse {
            // Send ERR_NOSUCHNICK.
            self._sendMessage(
                &ec,
                ":{} 401 {} {} :No such nick/channel",
                .{ hostname, CE(nickname, &ec), CE(receiver_name, &ec) },
            );
            return;
        };
        channel.sendPrivMsg(&self._user, text);
    }

    /// Send a message to the client.
    fn _sendMessage(
        self: *Client,
        escape_cond: ?*bool,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (escape_cond != null) {
            escape_cond.?.* = true;
        }
        self._info("> " ++ fmt ++ "\n", args);
        if (escape_cond != null) {
            escape_cond.?.* = false;
        }
        self._file_writer.print(fmt ++ "\r\n", args) catch |err| {
            self._warn(
                "Failed to write the message into the client socket: {}.\n",
                .{@errorName(err)},
            );
        };
    }

    /// Process a single message from the client.
    fn _processMessage(self: *Client, message: []const u8) void {
        self._info("< {}\n", .{E(message)});

        var lexer = Lexer.init(message);

        // Parse any prefix.
        if (lexer.getCurChar() == ':') {
            // TODO Error.
        }

        // Parse the command name.
        const command = lexer.readWord();
        // TODO Error handling.
        var res: anyerror!void = {};
        if (mem.eql(u8, command, "USER")) {
            res = self._processCommand_USER(&lexer);
        } else if (mem.eql(u8, command, "NICK")) {
            res = self._processCommand_NICK(&lexer);
        } else if (mem.eql(u8, command, "LIST")) {
            res = self._processCommand_LIST(&lexer);
        } else if (mem.eql(u8, command, "JOIN")) {
            res = self._processCommand_JOIN(&lexer);
        } else if (mem.eql(u8, command, "WHO")) {
            res = self._processCommand_WHO(&lexer);
        } else if (mem.eql(u8, command, "PRIVMSG")) {
            res = self._processCommand_PRIVMSG(&lexer);
        } else
            self._warn("Unrecognized command: {}\n", .{E(command)});

        if (res) {} else |err| {
            self._warn("Error: {}!\n", .{E(command)});
            // TODO
        }
    }

    /// Read new input available on client's socket and process it. A number of bytes read is
    /// returned. Value 0 indicates end of file.
    fn processInput(self: *Client) !usize {
        assert(self._input_received < self._input_buffer.len);
        var pos = self._input_received;
        const read = self._file_reader.read(self._input_buffer[pos..]) catch |err| {
            self._warn("Failed to read input from the client socket: {}.\n", .{@errorName(err)});
            return err;
        };
        if (read == 0) {
            // End of file reached.
            self._info("Client disconnected.\n", .{});
            // TODO Report any unhandled data.
            return read;
        }
        self._input_received += read;

        var message_begin: usize = 0;
        while (pos < self._input_received) : (pos += 1) {
            const char = self._input_buffer[pos];
            switch (self._input_state) {
                Client.InputState.Normal => {
                    if (char == '\r') {
                        self._input_state = Client.InputState.Normal_CR;
                    }
                    // TODO Check for invalid chars.
                },
                Client.InputState.Normal_CR => {
                    if (char == '\n') {
                        self._processMessage(self._input_buffer[message_begin .. pos - 1]);
                        self._input_state = Client.InputState.Normal;
                        message_begin = pos + 1;
                    } else {
                        // TODO Print an error message.
                        self._input_state = Client.InputState.Invalid;
                    }
                },
                Client.InputState.Invalid => {
                    if (char == '\r') {
                        self._input_state = Client.InputState.Invalid_CR;
                    }
                },
                Client.InputState.Invalid_CR => {
                    if (char == '\n') {
                        self._input_state = Client.InputState.Normal;
                        message_begin = pos + 1;
                    } else {
                        self._input_state = Client.InputState.Invalid;
                    }
                },
            }
        }

        switch (self._input_state) {
            Client.InputState.Normal, Client.InputState.Normal_CR => {
                if (message_begin >= self._input_received) {
                    assert(message_begin == self._input_received);
                    self._input_received = 0;
                } else if (message_begin == 0) {
                    // TODO Message overflow.
                    if (self._input_state == Client.InputState.Normal) {
                        self._input_state = Client.InputState.Invalid;
                    } else {
                        self._input_state = Client.InputState.Invalid_CR;
                    }
                } else {
                    mem.copy(
                        u8,
                        self._input_buffer[0..],
                        self._input_buffer[message_begin..self._input_received],
                    );
                    self._input_received -= message_begin;
                }
            },
            Client.InputState.Invalid, Client.InputState.Invalid_CR => {
                self._input_received = 0;
            },
        }
        return read;
    }

    fn _sendPrivMsg(self: *Client, from: []const u8, to: []const u8, text: []const u8) void {
        var ec: bool = undefined;

        self._sendMessage(
            &ec,
            ":{} PRIVMSG {} :{}",
            .{ CE(from, &ec), CE(to, &ec), CE(text, &ec) },
        );
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

    /// Create a new local bot instance.
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
            ._user = try User.init(
                User.Type.LocalBot,
                nickname,
                nickname,
                nickname,
                server,
                E(nickname),
            ),
            ._channels_target = channels_target,
            ._channels_leave_rate = channels_leave_rate,
            ._message_rate = message_rate,
            ._message_length = message_length,
        };
        return local_bot;
    }

    fn destroy(self: *LocalBot) void {
        self._info("Destroying the local bot.\n", .{});

        const allocator = self._user._server.getAllocator();
        self._user.deinit();
        allocator.destroy(self);
    }

    fn fromUser(user: *User) *LocalBot {
        assert(user._type == User.Type.LocalBot);
        return @fieldParentPtr(LocalBot, "_user", user);
    }

    fn fromConstUser(user: *const User) *const LocalBot {
        assert(user._type == User.Type.LocalBot);
        return @fieldParentPtr(LocalBot, "_user", user);
    }

    fn _info(self: *const LocalBot, comptime fmt: []const u8, args: anytype) void {
        const nickname = E(self._user._nickname);
        info("{}: " ++ fmt, .{nickname} ++ args);
    }

    fn _warn(self: *const LocalBot, comptime fmt: []const u8, args: anytype) void {
        const nickname = E(self._user._nickname);
        warn("{}: " ++ fmt, .{nickname} ++ args);
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
            const server_channel = server_channel_node.key();

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

    fn _tick_leaveChannels(self: *LocalBot) void {
        // TODO Handle channels_leave_rate.
    }

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

    fn tick(self: *LocalBot) void {
        self._tick_joinChannels();
        self._tick_leaveChannels();
        self._tick_sendMessages();
    }
};

const LocalBotSet = avl.Map(*LocalBot, void, avl.getLessThanFn(*LocalBot));

const Channel = struct {
    _server: *Server,

    /// Channel name (owned).
    _name: []const u8,

    /// Channel topic (owned).
    _topic: ?[]const u8,

    /// Users in the channel.
    _users: UserSet,

    /// Create a new channel with the given name.
    fn create(name: []const u8, server: *Server) !*Channel {
        info("{}: Creating the channel.\n", .{E(name)});

        const allocator = server.getAllocator();

        // Make a copy of the name string.
        const name_copy = allocator.alloc(u8, name.len) catch |err| {
            warn(
                "{}: Failed to allocate a channel name string buffer: {}.\n",
                .{ E(name), @errorName(err) },
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
            ._users = UserSet.init(allocator),
        };
        return channel;
    }

    fn destroy(self: *Channel) void {
        self._info("Destroying the channel.\n", .{});

        const allocator = self._server.getAllocator();
        allocator.free(self._name);
        if (self._topic != null) {
            allocator.free(self._topic.?);
        }
        self._users.deinit();
        allocator.destroy(self);
    }

    fn getName(self: *const Channel) []const u8 {
        return self._name;
    }

    fn getUserCount(self: *const Channel) usize {
        return self._users.count();
    }

    fn _info(self: *const Channel, comptime fmt: []const u8, args: anytype) void {
        const name = E(self._name);
        info("{}: " ++ fmt, .{name} ++ args);
    }

    fn _warn(self: *const Channel, comptime fmt: []const u8, args: anytype) void {
        const name = E(self._name);
        warn("{}: " ++ fmt, .{name} ++ args);
    }

    /// Process join from a user.
    fn join(self: *Channel, user: *User) !void {
        // TODO Fix handling of duplicated join.
        const user_iter = self._users.insert(user, {}) catch |err| {
            self._warn(
                "Failed to insert user {} in the channel user set: {}.\n",
                .{ E(user.getNickName()), @errorName(err) },
            );
            return err;
        };
        errdefer self._users.remove(user_iter);

        const nickname = user.getNickName();
        const hostname = self._server.getHostName();
        var ec: bool = undefined;

        self._info(
            "User {} joined the channel (now at {} users).\n",
            .{ E(nickname), self._users.count() },
        );

        // Inform all clients about the join.
        var channel_user_iter = self._users.iterator();
        while (channel_user_iter.next()) |channel_user_node| {
            const channel_user = channel_user_node.key();
            channel_user.sendMessage(
                &ec,
                ":{} JOIN {}",
                .{ CE(nickname, &ec), CE(self._name, &ec) },
            );
        }

        // Send information about the channel topic.
        if (self._topic != null) {
            // Send RPL_TOPIC.
            user.sendMessage(
                &ec,
                ":{} 332 {} {} :{}",
                .{ hostname, CE(nickname, &ec), CE(self._name, &ec), CE(self._topic.?, &ec) },
            );
        } else {
            // Send RPL_NOTOPIC.
            user.sendMessage(
                &ec,
                ":{} 332 {} {} :No topic is set",
                .{ hostname, CE(nickname, &ec), CE(self._name, &ec) },
            );
        }

        // Send RPL_NAMREPLY.
        channel_user_iter = self._users.iterator();
        while (channel_user_iter.next()) |channel_user_node| {
            const channel_user = channel_user_node.key();
            const member_nickname = channel_user.getNickName();
            user.sendMessage(
                &ec,
                ":{} 353 {} = {} :{}",
                .{ hostname, CE(nickname, &ec), CE(self._name, &ec), CE(member_nickname, &ec) },
            );
        }
        // Send RPL_ENDOFNAMES.
        user.sendMessage(
            &ec,
            ":{} 366 {} {} :End of /NAMES list",
            .{ hostname, CE(nickname, &ec), CE(self._name, &ec) },
        );
    }

    /// Query "who" information about all users in the channel.
    fn who(self: *Channel, user: *User) void {
        const nickname = user.getNickName();
        const hostname = self._server.getHostName();
        var ec: bool = undefined;

        // Send RPL_WHOREPLY.
        var channel_user_iter = self._users.iterator();
        while (channel_user_iter.next()) |channel_user_node| {
            const channel_user = channel_user_node.key();
            user.sendMessage(
                &ec,
                ":{} 352 {} {} {} hidden {} {} H :0 {}",
                .{
                    hostname,
                    CE(nickname, &ec),
                    CE(self._name, &ec),
                    CE(channel_user.getUserName(), &ec),
                    self._server.getHostName(),
                    CE(channel_user.getNickName(), &ec),
                    CE(channel_user.getRealName(), &ec),
                },
            );
        }
        // Send RPL_ENDOFWHO.
        user.sendMessage(
            &ec,
            ":{} 315 {} {} :End of /WHO list",
            .{ hostname, CE(nickname, &ec), CE(self._name, &ec) },
        );
    }

    /// Send a message to all users in the channel.
    fn sendPrivMsg(self: *Channel, user: *const User, text: []const u8) void {
        const from_name = user.getNickName();
        var channel_user_iter = self._users.iterator();
        while (channel_user_iter.next()) |channel_user_node| {
            const channel_user = channel_user_node.key();
            channel_user.sendPrivMsg(from_name, self._name, text);
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

    /// Remote clients (owned).
    _clients: ClientSet,

    /// Local bots (owned).
    _local_bots: LocalBotSet,

    /// Channels (owned).
    _channels: ChannelSet,

    /// Channels organized for fast lookup by name.
    _channels_by_name: ChannelNameSet,

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
            warn("Failed to allocate a host string buffer: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(host_copy);
        mem.copy(u8, host_copy, host);

        const port_copy = allocator.alloc(u8, port.len) catch |err| {
            warn("Failed to allocate a port string buffer: {}.\n", .{@errorName(err)});
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
            ._channels = ChannelSet.init(allocator),
            ._channels_by_name = ChannelNameSet.init(allocator),
        };
        return server;
    }

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

        // Destroy all channels.
        var channel_iter = self._channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.key();
            channel.destroy();
        }
        self._channels.deinit();
        self._channels_by_name.deinit();

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

    fn getHostName(self: *const Server) []const u8 {
        return self._host;
    }

    fn getChannels(self: *Server) *const ChannelSet {
        return &self._channels;
    }

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
                "Failed to bind to address {}:{}: {}.\n",
                .{ self._host, self._port, @errorName(err) },
            );
            return err;
        };

        os.listen(listenfd, os.SOMAXCONN) catch |err| {
            warn("Failed to listen on {}:{}: {}.\n", .{ self._host, self._port, @errorName(err) });
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
                "Failed to add the server socket (fd {}) to the epoll instance: {}.\n",
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
                "Failed to add the standard input to the epoll instance: {}.\n",
                .{@errorName(err)},
            );
            return err;
        };

        // Listen for events.
        info("Listening on {}:{}.\n", .{ self._host, self._port });

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
            // TODO Handle error events.
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
                "{}: Failed to insert the client in the main client set: {}.\n",
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
                "{}: Failed to add the client socket (fd {}) to the epoll instance: {}.\n",
                .{ client_addr, clientfd, @errorName(err) },
            );
            return;
        };
    }

    /// Process input from a client.
    fn _processInput(self: *Server, epfd: i32, client: *Client) void {
        const res = client.processInput() catch 0;
        if (res != 0) {
            return;
        }

        // Destroy the client.
        const clientfd = client.getFileDescriptor();
        os.epoll_ctl(epfd, os.EPOLL_CTL_DEL, clientfd, undefined) catch unreachable;

        const client_iter = self._clients.find(client);
        assert(client_iter.valid());
        self._clients.remove(client_iter);
        client.destroy();
    }

    /// Create a new channel with the given name.
    fn createChannel(self: *Server, name: []const u8) !void {
        const channel = try Channel.create(name, self);
        errdefer channel.destroy();

        const channel_iter = self._channels.insert(channel, {}) catch |err| {
            warn(
                "{}: Failed to insert the channel in the main channel set: {}.\n",
                .{ E(name), @errorName(err) },
            );
            return err;
        };
        errdefer self._channels.remove(channel_iter);

        _ = self._channels_by_name.insert(channel.getName(), channel) catch |err| {
            warn(
                "{}: Failed to insert the channel in the by-name channel set: {}.\n",
                .{ E(name), @errorName(err) },
            );
            return err;
        };
    }

    /// Find a channel by name.
    fn lookupChannel(self: *Server, name: []const u8) ?*Channel {
        const channel_iter = self._channels_by_name.find(name);
        return if (channel_iter.valid()) channel_iter.value() else null;
    }

    /// Create a new local bot with the given name.
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
                "{}: Failed to insert the local bot in the main local bot set: {}.\n",
                .{ E(nickname), @errorName(err) },
            );
            return err;
        };
        errdefer self._local_bots.remove(local_bot_iter);

        // Run the initial tick.
        local_bot.tick();
    }
};

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

    // Create pre-defined artificial users.
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
