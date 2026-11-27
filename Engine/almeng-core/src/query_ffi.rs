//! A bounded, call-scoped ABI for metadata queries. No global collection or
//! cached pointers: tiny libraries pay no index initialization cost.
use super::*;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AmQueryString {
    pub offset: usize,
    pub len: usize,
}
#[repr(C)]
pub struct AmQueryRecord {
    pub path: AmQueryString,
    pub name: AmQueryString,
    pub camera_make: AmQueryString,
    pub camera_model: AmQueryString,
    pub color_space: AmQueryString,
    pub size: i64,
    pub pixel_width: i64,
    pub pixel_height: i64,
    pub modified: f64,
    pub created: f64,
    pub latitude: f64,
    pub longitude: f64,
    pub captured: f64,
    pub exposure_time: f64,
    pub aperture: f64,
    pub present: u32,
}
#[repr(C)]
pub struct AmQueryIndices {
    pub ptr: *mut usize,
    pub len: usize,
    pub error: AmBuffer,
}

fn text(arena: &[u8], span: AmQueryString) -> Result<Option<String>> {
    if span.offset == usize::MAX && span.len == 0 {
        return Ok(None);
    }
    let end = span
        .offset
        .checked_add(span.len)
        .ok_or("Invalid string span")?;
    let bytes = arena.get(span.offset..end).ok_or("Invalid string span")?;
    Ok(Some(
        std::str::from_utf8(bytes)
            .map_err(|_| "Invalid query UTF-8")?
            .to_owned(),
    ))
}
fn integer(value: i64, present: bool) -> Result<Option<u64>> {
    if !present {
        return Ok(None);
    }
    Ok(Some(
        u64::try_from(value).map_err(|_| "Invalid unsigned query value")?,
    ))
}
fn number(value: f64, present: bool) -> Result<Option<f64>> {
    if !present {
        return Ok(None);
    }
    if !value.is_finite() {
        return Err("Invalid query number".into());
    }
    Ok(Some(value))
}
fn records(input: &[AmQueryRecord], arena: &[u8]) -> Result<Vec<Asset>> {
    input
        .iter()
        .map(|r| {
            let has = |bit| r.present & bit != 0;
            if r.present & !1023 != 0 {
                return Err("Invalid query fields".into());
            }
            Ok(Asset {
                path: text(arena, r.path)?.ok_or("Missing query path")?,
                name: text(arena, r.name)?.ok_or("Missing query name")?,
                camera_make: text(arena, r.camera_make)?,
                camera_model: text(arena, r.camera_model)?,
                color_space: text(arena, r.color_space)?,
                size: integer(r.size, has(1))?,
                pixel_width: integer(r.pixel_width, has(32))?,
                pixel_height: integer(r.pixel_height, has(64))?,
                modified: number(r.modified, has(2))?,
                created: number(r.created, has(4))?,
                latitude: number(r.latitude, has(8))?,
                longitude: number(r.longitude, has(16))?,
                captured: number(r.captured, has(128))?,
                exposure_time: number(r.exposure_time, has(256))?,
                aperture: number(r.aperture, has(512))?,
                entry_path: None,
            })
        })
        .collect()
}

/// # Safety
/// All nonempty inputs must point to valid, aligned memory for the whole call.
/// Exactly one matching free is required for each returned result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn am_query_records(
    input: *const AmQueryRecord,
    count: usize,
    strings: *const u8,
    strings_len: usize,
    options: *const u8,
    options_len: usize,
) -> AmQueryIndices {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let total = count
            .checked_mul(std::mem::size_of::<AmQueryRecord>())
            .and_then(|n| n.checked_add(strings_len))
            .and_then(|n| n.checked_add(options_len));
        if count > MAX_ASSETS
            || total.is_none_or(|n| n > MAX_REQUEST)
            || (count > 0 && input.is_null())
            || (strings_len > 0 && strings.is_null())
            || options.is_null()
            || options_len == 0
        {
            return Err("Invalid query request".into());
        }
        let input = if count == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(input, count) }
        };
        let arena = if strings_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(strings, strings_len) }
        };
        let options: Options =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(options, options_len) })
                .map_err(|e| e.to_string())?;
        query(records(input, arena)?, options)
    }))
    .unwrap_or_else(|_| Err("Query failed safely".into()));
    match result {
        Ok(indices) if indices.is_empty() => AmQueryIndices {
            ptr: std::ptr::null_mut(),
            len: 0,
            error: AmBuffer::empty(),
        },
        Ok(indices) => {
            let indices = indices.into_boxed_slice();
            let len = indices.len();
            AmQueryIndices {
                ptr: Box::into_raw(indices) as *mut usize,
                len,
                error: AmBuffer::empty(),
            }
        }
        Err(error) => AmQueryIndices {
            ptr: std::ptr::null_mut(),
            len: 0,
            error: AmBuffer::new(error.into_bytes()),
        },
    }
}

/// # Safety
/// The result must originate from am_query_records and be freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn am_query_indices_free(result: AmQueryIndices) {
    if !result.ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(result.ptr, result.len)) });
    }
    unsafe { super::am_buffer_free(result.error) };
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Vec<u8>, AmQueryRecord) {
        let arena = b"photo2.dng".to_vec();
        // All fields are plain C integers/floats/spans, with no references.
        let mut record: AmQueryRecord = unsafe { std::mem::zeroed() };
        record.path = AmQueryString {
            offset: 0,
            len: arena.len(),
        };
        record.name = record.path;
        let absent = AmQueryString {
            offset: usize::MAX,
            len: 0,
        };
        record.camera_make = absent;
        record.camera_model = absent;
        record.color_space = absent;
        (arena, record)
    }
    fn run(input: &[AmQueryRecord], arena: &[u8], options: &[u8]) -> Result<Vec<usize>> {
        let result = unsafe {
            am_query_records(
                input.as_ptr(),
                input.len(),
                arena.as_ptr(),
                arena.len(),
                options.as_ptr(),
                options.len(),
            )
        };
        let output = if !result.error.ptr.is_null() {
            Err(String::from_utf8_lossy(unsafe {
                std::slice::from_raw_parts(result.error.ptr, result.error.len)
            })
            .into())
        } else if result.len == 0 {
            Ok(vec![])
        } else {
            Ok(unsafe { std::slice::from_raw_parts(result.ptr, result.len) }.to_vec())
        };
        unsafe { am_query_indices_free(result) };
        output
    }
    #[test]
    fn empty_and_single_requests_release_owned_results() {
        let (arena, r) = fixture();
        assert_eq!(run(&[], &[], b"{}"), Ok(vec![]));
        assert_eq!(run(&[r], &arena, b"{}"), Ok(vec![0]));
    }
    #[test]
    fn malformed_records_are_errors_and_do_not_escape_the_abi() {
        for variant in 0..7 {
            let (mut arena, mut r) = fixture();
            match variant {
                0 => r.name.offset = usize::MAX - 1,
                1 => r.name.len = usize::MAX,
                2 => arena[0] = 255,
                3 => {
                    r.present = 1;
                    r.size = -1;
                }
                4 => {
                    r.present = 2;
                    r.modified = f64::NAN;
                }
                5 => r.present = 1024,
                _ => {
                    r.path = AmQueryString {
                        offset: usize::MAX,
                        len: 0,
                    }
                }
            }
            assert!(run(&[r], &arena, b"{}").is_err());
        }
        let result = unsafe {
            am_query_records(
                std::ptr::null(),
                MAX_ASSETS + 1,
                std::ptr::null(),
                0,
                b"{}".as_ptr(),
                2,
            )
        };
        assert!(!result.error.ptr.is_null());
        unsafe { am_query_indices_free(result) };
        let (arena, r) = fixture();
        assert!(run(&[r], &arena, b"{").is_err());
    }
}
