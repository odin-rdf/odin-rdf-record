// The README's example, compiled and asserted here so the documentation
// cannot drift from the real API — the family convention.
package readme

import "core:testing"

import rec "../../record"
import ingest "../../record/ingest"
import "rdf:rdf"

SOURCE :: `
@prefix ex: <http://example.org/> .
ex:alice a ex:Person ; ex:name "Alice"@en .
`

@(test)
readme_example :: proc(t: ^testing.T) {
	// --- the README example, verbatim from here ---
	fs: rec.Mem_FS // tests and scratch; rec.posix_file_ops() for a directory on disk
	s: rec.Store
	_, err, _, _ := rec.store_open(&s, "store", rec.mem_file_ops(&fs))
	ops, ierr := ingest.turtle(transmute([]byte)string(SOURCE), nil, context.allocator, blank_prefix = "upload-1/")
	epoch, _, aerr := rec.apply(&s, {ops = ops, actor = rdf.IRI("http://example.org/alice")})
	ingest.ops_destroy(ops, context.allocator)
	rec.store_close(&s)
	// --- to here ---
	rec.mem_fs_destroy(&fs)
	testing.expect_value(t, err, rec.Open_Error.None)
	testing.expect_value(t, ierr.kind, ingest.Error_Kind.None)
	testing.expect_value(t, aerr, rec.Apply_Error{})
	testing.expect_value(t, epoch, rec.Epoch(1))
}
