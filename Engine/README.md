# 알맹Re Rust engine

`almeng-core` is the platform-independent engine, statically linked through the small
`CAlmaengCore` C ABI. Rust owns directory enumeration, Unicode-normalized natural
ordering, name matching, filename search, format filtering, all library sort modes,
ZIP validation/extraction, QOI/PCX parsing, pixel/decode/cache budget calculations,
and the adaptive policy reacting to CPU, memory, thermal, power, and storage state.

## Native platform boundary

SwiftUI/AppKit retain windows, interaction, accessibility, and security-scoped grants.
ImageIO remains the decoder/metadata backend for macOS formats and RAW. CoreImage
retains color-managed adjustments and HDR rendering. CoreGraphics owns displayed
images; CoreML owns Apple-accelerated inference. Swift actors retain cancellable
work scheduling, continuations, native decoder lifetimes, and the byte-accounted
CGImage cache. These are platform bindings and native object ownership, not duplicate
implementations of the migrated parsers and library policy.

Rust does not guarantee that an entire application cannot leak or that every workload
will be faster. Bounded buffers, explicit ownership, existing cancellation rules,
resource budgets, and regression tests remain necessary across native framework/FFI
boundaries.

## Build

Install stable Rust and both `aarch64-apple-darwin` / `x86_64-apple-darwin` targets.
The implementation is validated with Rust 1.94.0. Cargo.lock is committed; build
scripts use `--locked`. Dependencies use permissive licenses, preserved in
`THIRD_PARTY_NOTICES.txt` and copied into the built app bundle.

```sh
./scripts/build-rust-engine.sh native
swift test --disable-sandbox
cargo test --manifest-path Engine/almeng-core/Cargo.toml --locked
./scripts/build-app.sh release universal
```

The app build automatically builds and combines matching Rust architecture slices
before Swift linking. Plain `swift build`/`swift test` require the first command on a
fresh clone. `.build/rust/lib/libalmeng_core.a` is generated and not committed.
No separate Rust runtime or dynamic library is required on the user's Mac.

## Boundary safety and compatibility

JSON requests contain metadata, not pixels. Returned buffers have exactly one Rust
allocation, copied and freed by Swift with `am_buffer_free`; no borrowed pointer is
retained. JSON/parser entry points contain panics within Rust. Raster data uses a
binary buffer. QOI and PCX allocations validate dimensions, strides, and run lengths
before indexing. Decoded images are limited to 100 million pixels; inputs are capped
at 512 MiB. Pixel data is premultiplied RGBA, preserving QOI linear/sRGB meaning.

Name matching compares NFC-normalized, lowercase stems, consuming duplicate members
one-to-one. The union retains missing counterparts. Natural digit ordering does not
parse bounded integers. Optional date/size/GPS values sort after known values in both
directions, and filename/path tie-breakers make results deterministic. Search uses
case-insensitive whitespace-separated filename terms. This release does not provide
semantic image-content search.

ZIP files support stored/deflate entries, including ZIP64 handled by the ZIP crate.
Encrypted and unsupported compression methods fail explicitly. Archives are bounded
to 2 GiB compressed input, 16 MiB of directory metadata, 10,000 entries (checked
before directory allocation), 256 MiB per entry, 1 GiB total declared expansion, and a 1,000:1
ratio (with a 1 MiB allowance for small entries). Every member is checked for unsafe
paths and symbolic links before extraction. Generated flat filenames in a new 0700
private directory prevent archive-controlled output paths; declared and actual byte
counts are checked while streaming. Image members are materialized once per open,
not lazily. Asset copies retain the directory lease; releasing the last copy deletes
it. Archive URL + member path provide stable session identity; materialized URLs are
not persisted as the source. Archive images are read-only, with export to copies.

References: Rustonomicon FFI documentation, the local pinned zip 2.4.2 API/source,
and the official QOI specification. FFI safety depends on trusted callers honoring
the documented pointer/length/free contract; it is not a security boundary for
arbitrary native code in the same process.
