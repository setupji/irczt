// Copyright (C) 2018 Petr Pavlu <setup@dagobah.cz>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const net = std.net;
const os = std.os;
const time = std.time;

const Allocator = std.mem.Allocator;
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

    pub fn format(self: EscapeFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
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
fn Protect(slice: []const u8) EscapeFormatter {
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

    pub fn format(self: ConditionalEscapeFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
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
fn CProtect(slice: []const u8, cond: *bool) ConditionalEscapeFormatter {
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

    type_: Type,

    /// Get the preferred user name.
    fn getName(self: *const User) []const u8 {
        switch (self.type_) {
            User.Type.Client => {
                return Client.fromConstUser(self).getNickName();
            },
            User.Type.LocalBot => {
                // TODO Implement.
                unreachable;
            },
        }
    }

    fn sendPrivMsg(self: *User, from: []const u8, to: []const u8, text: []const u8) void {
        switch (self.type_) {
            User.Type.Client => {
                return Client.fromUser(self).sendPrivMsg(from, to, text);
            },
            User.Type.LocalBot => {
                // TODO Implement.
                unreachable;
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

    _server: *Server,
    _allocator: *Allocator,

    /// User definition.
    _user: User,

    _fd: i32,
    _addr: net.Address,

    _file_writer: fs.File.Writer,
    _file_reader: fs.File.Reader,

    _input_state: InputState,
    _input_buffer: [512]u8,
    _input_received: usize,

    /// Flag indicating whether the initial USER and NICK pair was already received and the client
    /// is fully joined.
    _registered: bool,

    _realname: [512]u8,
    _realname_end: usize,
    _nickname: [9]u8,
    _nickname_end: usize,

    /// Create a new client instance, which takes ownership for the passed client descriptor. If
    /// constructing the client fails, the file descriptor gets closed.
    fn create(fd: i32, addr: net.Address, server: *Server, allocator: *Allocator) !*Client {
        errdefer os.close(fd);

        info("{}: Accepted a new client.\n", .{addr});

        const client = allocator.create(Client) catch |err| {
            warn("{}: Failed to allocate a client instance: {}.\n", .{ addr, @errorName(err) });
            return err;
        };
        const file = fs.File{ .handle = fd };
        client.* = Client{
            ._server = server,
            ._allocator = allocator,
            ._user = User{ .type_ = User.Type.Client },
            ._fd = fd,
            ._addr = addr,
            ._file_writer = file.writer(),
            ._file_reader = file.reader(),
            ._input_state = Client.InputState.Normal,
            ._input_buffer = undefined,
            ._input_received = 0,
            ._registered = false,
            ._realname = [_]u8{0} ** @typeInfo(@TypeOf(client._realname)).Array.len,
            ._realname_end = 0,
            ._nickname = [_]u8{0} ** @typeInfo(@TypeOf(client._nickname)).Array.len,
            ._nickname_end = 0,
        };
        return client;
    }

    /// Close connection to a client and destroy the client data.
    fn destroy(self: *Client) void {
        os.close(self._fd);
        self._info("Closed client connection.\n", .{});
        self._allocator.destroy(self);
    }

    fn fromUser(user: *User) *Client {
        assert(user.type_ == User.Type.Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    fn fromConstUser(user: *const User) *const Client {
        assert(user.type_ == User.Type.Client);
        return @fieldParentPtr(Client, "_user", user);
    }

    /// Get the clien file descriptor.
    fn getFileDescriptor(self: *const Client) i32 {
        return self._fd;
    }

    /// Get a slice with the client's real name.
    fn getRealName(self: *const Client) []const u8 {
        return self._realname[0..self._realname_end];
    }

    /// Get a slice with the client's nick name.
    fn getNickName(self: *const Client) []const u8 {
        return self._nickname[0..self._nickname_end];
    }

    fn _info(self: *Client, comptime fmt: []const u8, args: anytype) void {
        info("{}: " ++ fmt, .{self._addr} ++ args);
    }

    fn _warn(self: *Client, comptime fmt: []const u8, args: anytype) void {
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
            self._warn("Position {}, parameter {} is too long (maximum: {}, actual: {}).\n", .{ begin + 1, param, maxlen, res.len });
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
        if (self._realname_end != 0) {
            // TODO Log an error.
            return error.AlreadyRegistred;
        }

        const username = try self._acceptParam(lexer, "<username>");
        const hostname = try self._acceptParam(lexer, "<hostname>");
        const servername = try self._acceptParam(lexer, "<servername>");

        const realname = try self._acceptParamMax(lexer, "<realname>", self._realname.len);
        mem.copy(u8, self._realname[0..], realname);
        self._realname_end = realname.len;

        // TODO Check there no more unexpected parameters.

        // Complete the join if the initial USER and NICK pair was already received.
        if (!self._registered and self._nickname_end != 0) {
            try self._completeRegistration();
        }
    }

    /// Process the NICK command.
    /// Parameters: <nickname>
    fn _processCommand_NICK(self: *Client, lexer: *Lexer) !void {
        const nickname = self._acceptParamMax(lexer, "<nickname>", self._nickname.len) catch |err| {
            if (err == error.NeedsMoreParams) {
                return error.NoNickNameGiven;
            } else {
                return err;
            }
        };
        mem.copy(u8, self._nickname[0..], nickname);
        self._nickname_end = nickname.len;

        // TODO
        // ERR_ERRONEUSNICKNAME
        // ERR_NICKNAMEINUSE

        // TODO Check there no more unexpected parameters.

        // Complete the join if the initial USER and NICK pair was already received.
        if (!self._registered and self._realname_end != 0) {
            try self._completeRegistration();
        }
    }

    /// Complete the client join after the initial USER and NICK pair is received.
    fn _completeRegistration(self: *Client) !void {
        assert(!self._registered);
        assert(self._realname_end != 0);
        assert(self._nickname_end != 0);

        const nickname = self.getNickName();
        const hostname = self._server.getHostName();
        var ec: bool = undefined;

        // Send RPL_LUSERCLIENT.
        // TODO Fix user count.
        try self._sendMessage(&ec, ":{} 251 {} :There are {} users and 0 invisible on 1 servers", .{ hostname, CProtect(nickname, &ec), 1 });

        // Send motd.
        try self._sendMessage(&ec, ":{} 375 {} :- {} Message of the Day -", .{ hostname, CProtect(nickname, &ec), hostname });
        try self._sendMessage(&ec, ":{} 372 {} :- Welcome to the {} IRC network!", .{ hostname, CProtect(nickname, &ec), hostname });
        try self._sendMessage(&ec, ":{} 376 {} :End of /MOTD command.", .{ hostname, CProtect(nickname, &ec) });

        try self._sendMessage(&ec, ":irczt-connect PRIVMSG {} :Hello", .{CProtect(nickname, &ec)});

        self._registered = true;
    }

    /// Check whether the user has completed the initial registration and is fully joined. If not
    /// then send ERR_NOTREGISTERED to the client and return error.NotRegistered.
    fn _checkRegistered(self: *Client) !void {
        if (self._registered) {
            return;
        }
        try self._sendMessage(null, ":{} 451 * :You have not registered", .{self._server.getHostName()});
        return error.NotRegistered;
    }

    /// Process the LIST command.
    /// Parameters: [<channel>{,<channel>} [<server>]]
    fn _processCommand_LIST(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse the parameters.

        const nickname = self.getNickName();
        var ec: bool = undefined;

        // Send RPL_LISTSTART.
        try self._sendMessage(&ec, ":{} 321 {} Channel :Users  Name", .{ self._server.getHostName(), CProtect(nickname, &ec) });

        // Send RPL_LIST for each channel.
        const channels = self._server.getChannels();
        var channel_iter = channels.iterator();
        while (channel_iter.next()) |channel_node| {
            const channel = channel_node.key();
            try self._sendMessage(&ec, ":{} 322 {} {} {} :", .{ self._server.getHostName(), CProtect(nickname, &ec), CProtect(channel.getName(), &ec), channel.getUserCount() });
        }

        // Send RPL_LISTEND.
        try self._sendMessage(&ec, ":{} 323 {} :End of /LIST", .{ self._server.getHostName(), CProtect(nickname, &ec) });
    }

    /// Process the JOIN command.
    /// Parameters: <channel>{,<channel>} [<key>{,<key>}]
    fn _processCommand_JOIN(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse all parameters.
        const channel_name = try self._acceptParam(lexer, "<channel>");

        const nickname = self.getNickName();
        var ec: bool = undefined;

        const channel = self._server.lookupChannel(channel_name) orelse {
            // Send ERR_NOSUCHCHANNEL.
            try self._sendMessage(&ec, ":{} 403 {} {} :No such channel", .{ self._server.getHostName(), CProtect(nickname, &ec), CProtect(channel_name, &ec) });
            return;
        };
        // TODO Record joined channels.
        // TODO Report any error to the client.
        try channel.join(&self._user);

        try self._sendMessage(&ec, ":{} JOIN {}", .{ CProtect(nickname, &ec), CProtect(channel_name, &ec) });

        // TODO Sink in the client?
        //const hostname = self._server.getHostName();
        // Send RPL_TOPIC.
        //try self._sendMessage(&ec, ":{} 332 {} {} :Topic", .{self._server.getHostName(), CProtect(nickname, &ec), CProtect(channel_name, &ec)});
        // Send RPL_NAMREPLY.
        //try self._sendMessage(&ec, ":{} 353 {} {} :+setupji", .{self._server.getHostName(), CProtect(nickname, &ec), CProtect(channel_name, &ec)});
        // Send RPL_ENDOFNAMES.
        //try self._sendMessage(&ec, ":{} 366 {} {} :End of /NAMES list", .{self._server.getHostName(), CProtect(nickname, &ec), CProtect(channel_name, &ec)});
    }

    /// Process the PRIVMSG command.
    /// Parameters: <receiver>{,<receiver>} <text to be sent>
    fn _processCommand_PRIVMSG(self: *Client, lexer: *Lexer) !void {
        try self._checkRegistered();

        // TODO Parse all parameters.
        const receiver_name = try self._acceptParam(lexer, "<receiver>");
        const text = try self._acceptParam(lexer, "<text to be sent>");

        const nickname = self.getNickName();
        var ec: bool = undefined;

        // TODO Handle messages to users too.
        const channel = self._server.lookupChannel(receiver_name) orelse {
            // Send ERR_NOSUCHNICK.
            try self._sendMessage(&ec, ":{} 401 {} {} :No such nick/channel", .{ self._server.getHostName(), CProtect(nickname, &ec), CProtect(receiver_name, &ec) });
            return;
        };
        channel.sendPrivMsg(&self._user, text);
    }

    /// Send a message to the client.
    fn _sendMessage(self: *Client, escape_cond: ?*bool, comptime fmt: []const u8, args: anytype) !void {
        if (escape_cond != null) {
            escape_cond.?.* = true;
        }
        self._info("> " ++ fmt ++ "\n", args);
        if (escape_cond != null) {
            escape_cond.?.* = false;
        }
        self._file_writer.print(fmt ++ "\r\n", args) catch |err| {
            self._warn("Failed to write message into the client socket: {}.\n", .{@errorName(err)});
            return err;
        };
    }

    /// Process a single message from the client.
    fn _processMessage(self: *Client, message: []const u8) void {
        self._info("< {}\n", .{Protect(message)});

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
        } else if (mem.eql(u8, command, "PRIVMSG")) {
            res = self._processCommand_PRIVMSG(&lexer);
        } else
            self._warn("Unrecognized command: {}\n", .{Protect(command)});

        if (res) {} else |err| {
            self._warn("Error: {}!\n", .{Protect(command)});
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
                    if (char == '\r')
                        self._input_state = Client.InputState.Normal_CR;
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
                    if (char == '\r')
                        self._input_state = Client.InputState.Invalid_CR;
                },
                Client.InputState.Invalid_CR => {
                    if (char == '\n') {
                        self._input_state = Client.InputState.Normal;
                        message_begin = pos + 1;
                    } else
                        self._input_state = Client.InputState.Invalid;
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
                    if (self._input_state == Client.InputState.Normal) { // TODO Remove braces.
                        self._input_state = Client.InputState.Invalid;
                    } else
                        self._input_state = Client.InputState.Invalid_CR;
                } else {
                    mem.copy(u8, self._input_buffer[0..], self._input_buffer[message_begin..self._input_received]);
                    self._input_received -= message_begin;
                }
            },
            Client.InputState.Invalid, Client.InputState.Invalid_CR => {
                self._input_received = 0;
            },
        }
        return read;
    }

    fn sendPrivMsg(self: *Client, from: []const u8, to: []const u8, text: []const u8) void {
        var ec: bool = undefined;

        // TODO Error handling.
        self._sendMessage(&ec, ":{} PRIVMSG {} :{}", .{ CProtect(from, &ec), CProtect(to, &ec), CProtect(text, &ec) }) catch {};
    }
};

const ClientSet = avl.Map(*Client, void, avl.getLessThanFn(*Client));

const Channel = struct {
    _server: *Server,
    _allocator: *Allocator,

    /// Channel name (owned).
    _name: []const u8,

    /// Users in the channel.
    _users: UserSet,

    /// Create a new channel with the given name.
    fn create(name: []const u8, server: *Server, allocator: *Allocator) !*Channel {
        // Make a copy of the name string.
        const name_copy = allocator.alloc(u8, name.len) catch |err| {
            warn("Failed to allocate a channel name string buffer: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(name_copy);
        mem.copy(u8, name_copy, name);

        // Allocate a channel instance.
        const channel = allocator.create(Channel) catch |err| {
            warn("Failed to allocate a channel instance: {}.\n", .{@errorName(err)});
            return err;
        };
        channel.* = Channel{
            ._server = server,
            ._allocator = allocator,
            ._name = name_copy,
            ._users = UserSet.init(allocator),
        };
        return channel;
    }

    fn destroy(self: *Channel) void {
        // TODO Process _users.
        self._allocator.free(self._name);
        self._allocator.destroy(self);
    }

    fn getName(self: *const Channel) []const u8 {
        return self._name;
    }

    fn getUserCount(self: *const Channel) usize {
        return self._users.count();
    }

    fn _info(self: *Channel, comptime fmt: []const u8, args: anytype) void {
        const name = Protect(self._name);
        info("{}: " ++ fmt, .{name} ++ args);
    }

    fn _warn(self: *Channel, comptime fmt: []const u8, args: anytype) void {
        const name = Protect(self._name);
        warn("{}: " ++ fmt, .{name} ++ args);
    }

    /// Process join from a user.
    fn join(self: *Channel, user: *User) !void {
        // TODO Fix handling of duplicated join.
        _ = self._users.insert(user, {}) catch |err| {
            self._warn("Failed to insert user {} in the channel user set: {}.\n", .{ Protect(user.getName()), @errorName(err) });
            return err;
        };
        // TODO Inform other clients about the join.
        self._info("User {} joined the channel.\n", .{Protect(user.getName())});
    }

    /// Send a message to all users in the channel.
    fn sendPrivMsg(self: *Channel, user: *const User, text: []const u8) void {
        const from_name = user.getName();
        self._info("Received message (PRIVMSG) from {}: {}.\n", .{ Protect(from_name), Protect(text) });

        var channel_user_iter = self._users.iterator();
        while (channel_user_iter.next()) |channel_user| {
            channel_user.key().sendPrivMsg(from_name, self._name, text);
        }
    }
};

const ChannelSet = avl.Map(*Channel, void, avl.getLessThanFn(*Channel));

const ChannelNameSet = avl.Map([]const u8, *Channel, avl.getLessThanFn([]const u8));

const Server = struct {
    _allocator: *Allocator,

    /// Socket address.
    _sockaddr: net.Address,

    /// Host name (owned).
    _host: []const u8,

    /// Port number (owned).
    _port: []const u8,

    /// Remote clients (owned).
    _clients: ClientSet,

    /// Channels (owned).
    _channels: ChannelSet,

    /// Channels organized for fast lookup by name.
    _channels_by_name: ChannelNameSet,

    fn create(address: []const u8, allocator: *Allocator) !*Server {
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
            ._sockaddr = parsed_address,
            ._host = host_copy,
            ._port = port_copy,
            ._clients = ClientSet.init(allocator),
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

    fn getHostName(self: *const Server) []const u8 {
        return self._host;
    }

    fn getChannels(self: *Server) *ChannelSet {
        return &self._channels;
    }

    fn run(self: *Server) !void {
        // Create the server socket.
        const listenfd = os.socket(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP) catch |err| {
            warn("Failed to create a server socket: {}.\n", .{@errorName(err)});
            return err;
        };
        defer os.close(listenfd);

        os.bind(listenfd, &self._sockaddr.any, self._sockaddr.getOsSockLen()) catch |err| {
            warn("Failed to bind to address {}:{}: {}.\n", .{ self._host, self._port, @errorName(err) });
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
            warn("Failed to add the server socket (file descriptor {}) to the epoll instance: {}.\n", .{ listenfd, @errorName(err) });
            return err;
        };

        // Register the standard input with the epoll instance.
        var stdinfd_event = os.epoll_event{
            .events = os.EPOLLIN,
            .data = os.epoll_data{ .ptr = 1 },
        };
        os.epoll_ctl(epfd, os.EPOLL_CTL_ADD, os.STDIN_FILENO, &stdinfd_event) catch |err| {
            warn("Failed to add the standard input to the epoll instance: {}.\n", .{@errorName(err)});
            return err;
        };

        // Listen for events.
        info("Listening on {}:{}.\n", .{ self._host, self._port });
        while (true) {
            var events: [1]os.epoll_event = undefined;
            const ep = os.epoll_wait(epfd, events[0..], -1);
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
        const clientfd = os.accept(listenfd, &client_sockaddr, &client_socklen, os.SOCK_CLOEXEC) catch |err| {
            warn("Failed to accept a new client connection: {}.\n", .{@errorName(err)});
            return;
        };

        const client_addr = net.Address.initPosix(&client_sockaddr);

        // Create a new client. This transfers ownership of the clientfd to the Client
        // instance.
        const client = Client.create(clientfd, client_addr, self, self._allocator) catch return;
        errdefer client.destroy();

        const client_iter = self._clients.insert(client, {}) catch |err| {
            warn("{}: Failed to insert a client in the main client set: {}.\n", .{ client_addr, @errorName(err) });
            return;
        };
        errdefer self._clients.remove(client_iter);

        // Listen for the client.
        var clientfd_event = os.epoll_event{
            .events = os.EPOLLIN,
            .data = os.epoll_data{ .ptr = @ptrToInt(client) },
        };
        os.epoll_ctl(epfd, os.EPOLL_CTL_ADD, clientfd, &clientfd_event) catch |err| {
            warn("{}: Failed to add a client socket (file descriptor {}) to the epoll instance: {}.\n", .{ client_addr, clientfd, @errorName(err) });
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
        const channel = try Channel.create(name, self, self._allocator);
        errdefer channel.destroy();

        const channel_iter = self._channels.insert(channel, {}) catch |err| {
            warn("Failed to insert a channel in the main channel set: {}.\n", .{@errorName(err)});
            return err;
        };
        errdefer self._channels.remove(channel_iter);

        _ = self._channels_by_name.insert(channel.getName(), channel) catch |err| {
            warn("Failed to insert a channel in the by-name channel set: {}.\n", .{@errorName(err)});
            return err;
        };
    }

    /// Find a channel by name.
    fn lookupChannel(self: *Server, name: []const u8) ?*Channel {
        const channel_iter = self._channels_by_name.find(name);
        return if (channel_iter.valid()) channel_iter.value() else null;
    }

    fn createLocalBot(self: *Server, name: []const u8) void {
        // TODO
    }
};

pub fn main() u8 {
    // Get an allocator.
    var gp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gp_allocator.deinit()) {
        warn("Memory leaks detected on exit.\n", .{});
    };

    // Create the server.
    const server = Server.create(config.address, &gp_allocator.allocator) catch return 1;
    defer server.destroy();

    // Create pre-defined channels and automatic users.
    for (config.channels) |channel| {
        server.createChannel(channel) catch return 1;
    }
    for (config.local_bots) |local_bot| {
        server.createLocalBot(local_bot);
    }

    // Run the server.
    server.run() catch return 1;
    return 0;
}
