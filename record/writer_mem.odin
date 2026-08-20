// The in-memory File_Ops (RECORD-T-0015, promoted from tests/scale):
// the seam's second implementation, beside the POSIX one. It models a
// disk that never fails and never loses anything — every operation
// succeeds, sync is a no-op — and it exists for tests and scratch
// stores: every consumer's suite opens throwaway stores by the
// hundred, and a real fsync costs 5–20 ms per epoch on a development
// machine. What odin-rdf-store said of open_ephemeral holds here word
// for word: never for data anyone keeps. A store written through it
// is real bytes, though — flush the files to a directory and the
// verifiers read them like any other log (tests/scale does exactly
// that). The test-private OFS fake is the other kind of fake: it
// models a disk that fails, with an operation budget and a durability
// model; this one models a disk that works.
package record

import "base:runtime"
import "core:strings"

// Mem_File is one file: its path as the writer named it, and its
// bytes. Public so a caller can flush or inspect a store's files.
Mem_File :: struct {
	name: string, // cloned; owned by the Mem_FS
	data: [dynamic]u8,
}

// Mem_FS is the filesystem: a flat list of files — paths are opaque
// names, directories do not exist — with handles being 1-based
// indices into it. Zero value ready; release with mem_fs_destroy.
Mem_FS :: struct {
	files: [dynamic]Mem_File,
}

// mem_file_ops returns File_Ops over `fs`, which must outlive every
// store opened through them.
mem_file_ops :: proc(fs: ^Mem_FS) -> File_Ops {
	return {
		data        = fs,
		create      = mem_create,
		open_append = mem_open_append,
		append      = mem_append,
		sync        = mem_sync,
		close       = mem_close,
		sync_dir    = mem_sync_dir,
		put_file    = mem_put_file,
		read        = mem_read,
		truncate    = mem_truncate,
		remove      = mem_remove,
	}
}

// mem_fs_destroy frees every file. Stores opened through the
// filesystem must be closed first.
mem_fs_destroy :: proc(fs: ^Mem_FS) {
	for &f in fs.files {
		delete(f.name)
		delete(f.data)
	}
	delete(fs.files)
	fs^ = {}
}

@(private = "file")
mem_find :: proc(fs: ^Mem_FS, path: string) -> int {
	for f, i in fs.files {
		if f.name == path {
			return i
		}
	}
	return -1
}

@(private = "file")
mem_create :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^Mem_FS)(data)
	if mem_find(fs, path) >= 0 {
		return 0, false // create refuses an existing path
	}
	append(&fs.files, Mem_File{name = strings.clone(path)})
	return File_Handle(len(fs.files)), true
}

@(private = "file")
mem_open_append :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^Mem_FS)(data)
	i := mem_find(fs, path)
	if i < 0 {
		return 0, false // open_append refuses an absent path
	}
	return File_Handle(i + 1), true
}

@(private = "file")
mem_append :: proc(data: rawptr, f: File_Handle, bytes: []byte) -> bool {
	fs := (^Mem_FS)(data)
	append(&fs.files[int(f)-1].data, ..bytes)
	return true
}

@(private = "file")
mem_sync :: proc(data: rawptr, f: File_Handle) -> bool {
	return true
}

@(private = "file")
mem_close :: proc(data: rawptr, f: File_Handle) -> bool {
	return true
}

@(private = "file")
mem_sync_dir :: proc(data: rawptr, dir: string) -> bool {
	return true
}

@(private = "file")
mem_put_file :: proc(data: rawptr, path: string, content: []byte) -> bool {
	fs := (^Mem_FS)(data)
	i := mem_find(fs, path)
	if i < 0 {
		append(&fs.files, Mem_File{name = strings.clone(path)})
		i = len(fs.files) - 1
	}
	clear(&fs.files[i].data)
	append(&fs.files[i].data, ..content)
	return true
}

@(private = "file")
mem_read :: proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (contents: []byte, status: Read_Status) {
	fs := (^Mem_FS)(data)
	i := mem_find(fs, path)
	if i < 0 {
		return nil, .Absent
	}
	contents = make([]byte, len(fs.files[i].data), allocator)
	copy(contents, fs.files[i].data[:])
	return contents, .Ok
}

@(private = "file")
mem_truncate :: proc(data: rawptr, path: string, size: int) -> bool {
	fs := (^Mem_FS)(data)
	i := mem_find(fs, path)
	if i < 0 || size > len(fs.files[i].data) {
		return false
	}
	resize(&fs.files[i].data, size)
	return true
}

// mem_remove empties the file and blanks its name — the slot stays,
// because handles are slot indices and must not shift under an open
// file; a blank name matches no path, so the file is gone to every
// other operation.
@(private = "file")
mem_remove :: proc(data: rawptr, path: string) -> bool {
	fs := (^Mem_FS)(data)
	i := mem_find(fs, path)
	if i < 0 {
		return false
	}
	delete(fs.files[i].name)
	delete(fs.files[i].data)
	fs.files[i] = {}
	return true
}
