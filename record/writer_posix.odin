#+build linux, darwin
// The OS-backed File_Ops (RECORD-T-0002), POSIX only: Linux is the
// production environment and darwin is development. Windows has no
// implementation here — a consumer that wants one supplies its own
// File_Ops; nothing else in the package is platform-aware.
//
// # Durability, per platform
//
// On Linux, fsync(2) is the durability guarantee, and it is what
// production relies on. On darwin, fsync only pushes data to the
// drive, not through its cache, so posix_sync issues F_FULLFSYNC first —
// core:sys/posix does not expose the constant, so it is defined here
// from <sys/fcntl.h> — and falls back to fsync where the filesystem
// refuses it (network mounts, notably), the same posture SQLite
// takes. Development machines must not silently hold weaker
// guarantees than production. sync(2) is never used.
package record

import "base:runtime"
import "core:sys/posix"

// posix_file_ops returns File_Ops over the host filesystem. Stateless:
// the data pointer is nil and every handle is a file descriptor.
posix_file_ops :: proc() -> File_Ops {
	return {
		create      = posix_create,
		open_append = posix_open_append,
		append      = posix_append,
		sync     = posix_sync,
		close    = posix_close,
		sync_dir = posix_sync_dir,
		put_file = posix_put_file,
		read     = posix_read,
		truncate = posix_truncate,
		remove   = posix_remove,
	}
}

// F_FULLFSYNC from darwin's <sys/fcntl.h>; absent from core:sys/posix.
@(private)
DARWIN_F_FULLFSYNC :: 51

@(private)
posix_create :: proc(_: rawptr, path: string) -> (File_Handle, bool) {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], path), {.WRONLY, .CREAT, .EXCL}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {
		return 0, false
	}
	return File_Handle(uintptr(fd)), true
}

// posix_open_append opens an existing file for appending — no O_CREAT,
// so an absent path is refused, create's mirror image.
@(private)
posix_open_append :: proc(_: rawptr, path: string) -> (File_Handle, bool) {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], path), {.WRONLY, .APPEND})
	if fd < 0 {
		return 0, false
	}
	return File_Handle(uintptr(fd)), true
}

@(private)
posix_append :: proc(_: rawptr, f: File_Handle, bytes: []byte) -> bool {
	fd := posix.FD(f)
	rest := bytes
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n <= 0 {
			return false
		}
		rest = rest[n:]
	}
	return true
}

@(private)
posix_sync :: proc(_: rawptr, f: File_Handle) -> bool {
	fd := posix.FD(f)
	when ODIN_OS == .Darwin {
		if posix.fcntl(fd, posix.FCNTL_Cmd(DARWIN_F_FULLFSYNC)) != -1 {
			return true
		}
		// The filesystem refused F_FULLFSYNC; fsync is what remains.
	}
	return posix.fsync(fd) == .OK
}

@(private)
posix_close :: proc(_: rawptr, f: File_Handle) -> bool {
	return posix.close(posix.FD(f)) == .OK
}

@(private)
posix_sync_dir :: proc(_: rawptr, dir: string) -> bool {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], dir), {})
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	return posix.fsync(fd) == .OK
}

@(private)
posix_put_file :: proc(_: rawptr, path: string, content: []byte) -> bool {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], path), {.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	rest := content
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n <= 0 {
			return false
		}
		rest = rest[n:]
	}
	return true
}

@(private)
posix_read :: proc(_: rawptr, path: string, allocator: runtime.Allocator) -> (contents: []byte, status: Read_Status) {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], path), {})
	if fd < 0 {
		if posix.errno() == .ENOENT {
			return nil, .Absent
		}
		return nil, .Error
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return nil, .Error
	}
	size := int(st.st_size)
	contents = make([]byte, size, allocator)
	rest := contents
	for len(rest) > 0 {
		n := posix.read(fd, raw_data(rest), len(rest))
		if n <= 0 {
			delete(contents, allocator)
			return nil, .Error
		}
		rest = rest[n:]
	}
	return contents, .Ok
}

// posix_truncate cuts the file and makes the cut durable with the same
// primitive posix_sync uses — F_FULLFSYNC where darwin allows it,
// fsync everywhere else.
@(private)
posix_truncate :: proc(_: rawptr, path: string, size: int) -> bool {
	buf: [1024]u8
	fd := posix.open(cpath(buf[:], path), {.WRONLY})
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	if posix.ftruncate(fd, posix.off_t(size)) != .OK {
		return false
	}
	return posix_sync(nil, File_Handle(uintptr(fd)))
}

@(private)
posix_remove :: proc(_: rawptr, path: string) -> bool {
	buf: [1024]u8
	return posix.unlink(cpath(buf[:], path)) == .OK
}

// cpath NUL-terminates a borrowed path into the caller's buffer. The
// 1023-byte bound is asserted: store directories are configuration,
// not user input.
@(private)
cpath :: proc(buf: []byte, path: string) -> cstring {
	assert(len(path) < len(buf), "path too long")
	copy(buf, path)
	buf[len(path)] = 0
	return cstring(raw_data(buf))
}
