package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Unix-domain-socket IPC between the `wm daemon` process (which holds the strip
// state) and one-shot `wm <command>` clients (yabai's model). One command per
// connection: client connects, sends the command, reads the reply until EOF.
SOCKET_PATH :: "/tmp/niri-mac.sock"

@(private = "file")
fill_addr :: proc(a: ^posix.sockaddr_un) {
	a.sun_family = .UNIX
	a.sun_len = c.uchar(size_of(posix.sockaddr_un))
	path := SOCKET_PATH
	n := min(len(path), len(a.sun_path) - 1)
	for i in 0 ..< n do a.sun_path[i] = c.char(path[i])
	a.sun_path[n] = 0
}

@(private = "file")
as_sockaddr :: proc(a: ^posix.sockaddr_un) -> ^posix.sockaddr {
	return (^posix.sockaddr)(rawptr(a))
}

// Create, bind, and listen on the IPC socket. Returns the listening fd.
ipc_listen :: proc() -> (posix.FD, bool) {
	os.remove(SOCKET_PATH)

	fd := posix.socket(.UNIX, .STREAM)
	if i32(fd) < 0 {
		fmt.eprintln("socket() failed")
		return fd, false
	}

	addr: posix.sockaddr_un
	fill_addr(&addr)
	if posix.bind(fd, as_sockaddr(&addr), posix.socklen_t(size_of(addr))) != .OK {
		fmt.eprintfln("bind(%s) failed — is a daemon already running?", SOCKET_PATH)
		posix.close(fd)
		return fd, false
	}
	if posix.listen(fd, 16) != .OK {
		fmt.eprintln("listen() failed")
		posix.close(fd)
		return fd, false
	}
	return fd, true
}

// Accept a single pending connection, read its command, run `handle`, send the
// reply. Returns whether the handler signalled stop.
ipc_accept_once :: proc(listen_fd: posix.FD, handle: proc(cmd: string) -> (reply: string, stop: bool)) -> (stop: bool) {
	conn := posix.accept(listen_fd, nil, nil)
	if i32(conn) < 0 do return false
	defer posix.close(conn)

	buf: [8192]u8
	n := posix.recv(conn, &buf[0], len(buf), {})
	if n <= 0 do return false

	cmd := strings.trim_space(string(buf[:int(n)]))
	reply: string
	reply, stop = handle(cmd)
	if len(reply) > 0 {
		posix.send(conn, rawptr(raw_data(reply)), c.size_t(len(reply)), {})
	}
	delete(reply)
	return stop
}

ipc_cleanup :: proc() {
	os.remove(SOCKET_PATH)
}

// Connect to the daemon, send `cmd`, and return the full reply.
ipc_send :: proc(cmd: string) -> (reply: string, ok: bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if i32(fd) < 0 do return "", false
	defer posix.close(fd)

	addr: posix.sockaddr_un
	fill_addr(&addr)
	if posix.connect(fd, as_sockaddr(&addr), posix.socklen_t(size_of(addr))) != .OK {
		return "", false
	}

	posix.send(fd, rawptr(raw_data(cmd)), c.size_t(len(cmd)), {})

	b := strings.builder_make()
	buf: [16384]u8
	for {
		n := posix.recv(fd, &buf[0], len(buf), {})
		if n <= 0 do break
		strings.write_bytes(&b, buf[:int(n)])
	}
	return strings.to_string(b), true
}
