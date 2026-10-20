mod archive;
mod geography;
mod policy;
#[cfg(test)]
mod query_profile;
mod raster;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, HashSet},
    fs,
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    time::UNIX_EPOCH,
};
use unicode_normalization::UnicodeNormalization;

const MAX_REQUEST: usize = 64 * 1024 * 1024;
const MAX_ASSETS: usize = 100_000;
type Result<T> = std::result::Result<T, String>;
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub path: String,
    pub name: String,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub modified: Option<f64>,
    #[serde(default)]
    pub created: Option<f64>,
    #[serde(default)]
    pub latitude: Option<f64>,
    #[serde(default)]
    pub longitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixel_width: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixel_height: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub captured: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure_time: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera_make: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aperture: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_space: Option<String>,
}
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Options {
    #[serde(default)]
    search_text: String,
    #[serde(default = "default_sort")]
    sort: String,
    #[serde(default)]
    formats: Vec<String>,
    #[serde(default)]
    geographic_selection: Option<geography::Selection>,
}
fn default_sort() -> String {
    "nameAscending".into()
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Request {
    Limits {
        mode: String,
        snapshot: policy::Snapshot,
        storage: String,
    },
    Scan {
        path: String,
    },
    Query {
        assets: Vec<Asset>,
        options: Options,
    },
    Match {
        first: Vec<Asset>,
        second: Vec<Asset>,
        #[serde(default = "default_sort")]
        sort: String,
    },
    Zip {
        path: String,
        destination: String,
        extensions: Vec<String>,
    },
}
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Pair {
    first_index: Option<usize>,
    second_index: Option<usize>,
}
fn normalized(s: &str) -> String {
    s.nfc().flat_map(char::to_lowercase).collect()
}
fn natural(a: &str, b: &str) -> Ordering {
    natural_normalized(&normalized(a), &normalized(b))
}
fn natural_normalized(a: &str, b: &str) -> Ordering {
    let aa = a.as_bytes();
    let bb = b.as_bytes();
    let (mut i, mut j) = (0, 0);
    while i < aa.len() && j < bb.len() {
        if aa[i].is_ascii_digit() && bb[j].is_ascii_digit() {
            let (start_i, start_j) = (i, j);
            while i < aa.len() && aa[i].is_ascii_digit() {
                i += 1;
            }
            while j < bb.len() && bb[j].is_ascii_digit() {
                j += 1;
            }
            let an = aa[start_i..i]
                .iter()
                .position(|x| *x != b'0')
                .map(|p| &aa[start_i + p..i])
                .unwrap_or(&[]);
            let bn = bb[start_j..j]
                .iter()
                .position(|x| *x != b'0')
                .map(|p| &bb[start_j + p..j])
                .unwrap_or(&[]);
            let order = an.len().cmp(&bn.len()).then_with(|| an.cmp(bn));
            if order != Ordering::Equal {
                return order;
            }
        } else {
            let order = aa[i].cmp(&bb[j]);
            if order != Ordering::Equal {
                return order;
            }
            i += 1;
            j += 1;
        }
    }
    aa.len().saturating_sub(i).cmp(&bb.len().saturating_sub(j))
}
fn name_order(a: &Asset, b: &Asset) -> Ordering {
    natural(&a.name, &b.name).then_with(|| a.path.cmp(&b.path))
}
fn number_order(a: Option<f64>, b: Option<f64>, descending: bool) -> Ordering {
    match (a.filter(|n| n.is_finite()), b.filter(|n| n.is_finite())) {
        (Some(a), Some(b)) => {
            if descending {
                b.total_cmp(&a)
            } else {
                a.total_cmp(&b)
            }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        _ => Ordering::Equal,
    }
}
fn text_order(a: Option<&str>, b: Option<&str>, descending: bool) -> Ordering {
    let a = a.map(str::trim).filter(|s| !s.is_empty());
    let b = b.map(str::trim).filter(|s| !s.is_empty());
    match (a, b) {
        (Some(a), Some(b)) => {
            if descending {
                natural(b, a)
            } else {
                natural(a, b)
            }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        _ => Ordering::Equal,
    }
}
fn file_type(name: &str) -> Option<String> {
    let extension = Path::new(name).extension()?.to_str()?.trim().to_lowercase();
    if extension.is_empty() {
        return None;
    }
    Some(match extension.as_str() {
        "jpg" | "jpe" | "jfif" | "jif" | "jfi" => "jpeg".into(),
        "tif" => "tiff".into(),
        _ => extension,
    })
}
fn positive(value: Option<f64>) -> Option<f64> {
    value.filter(|n| n.is_finite() && *n > 0.)
}
fn format_group(name: &str) -> &'static str {
    match Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "jpg" | "jpeg" | "jpe" | "jfif" | "jif" | "jfi" => "jpeg",
        "png" | "apng" => "png",
        "heic" | "heif" | "hif" | "heics" => "heic",
        "gif" => "gif",
        "webp" => "webp",
        "tif" | "tiff" => "tiff",
        "raw" | "dng" | "cr2" | "cr3" | "crw" | "nef" | "nefx" | "nrw" | "arw" | "sr2" | "srf"
        | "orf" | "rw2" | "raf" | "pef" | "iiq" | "3fr" | "fff" | "rwl" | "x3f" | "erf" | "mrw"
        | "mos" | "kdc" | "dcr" | "mef" | "bay" | "cap" => "raw",
        _ => "other",
    }
}
fn sort_order(a: &Asset, b: &Asset, sort: &str) -> Ordering {
    sort_order_with_keys(a, b, sort, None)
}
struct QuerySortKey {
    name: String,
    text: Option<String>,
}
fn query_name_order(a: &Asset, b: &Asset, ka: &QuerySortKey, kb: &QuerySortKey) -> Ordering {
    natural_normalized(&ka.name, &kb.name).then_with(|| a.path.cmp(&b.path))
}
fn sort_order_with_keys(
    a: &Asset,
    b: &Asset,
    sort: &str,
    keys: Option<(&QuerySortKey, &QuerySortKey)>,
) -> Ordering {
    let names = || match keys {
        Some((ka, kb)) => query_name_order(a, b, ka, kb),
        None => name_order(a, b),
    };
    let text = |a, b, descending| match keys {
        Some((ka, kb)) => match (ka.text.as_deref(), kb.text.as_deref()) {
            (Some(a), Some(b)) if descending => natural_normalized(b, a),
            (Some(a), Some(b)) => natural_normalized(a, b),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            _ => Ordering::Equal,
        },
        None => text_order(a, b, descending),
    };
    match sort {
        "nameDescending" => names().reverse(),
        "modifiedNewest" => number_order(a.modified, b.modified, true),
        "modifiedOldest" => number_order(a.modified, b.modified, false),
        "createdNewest" => number_order(a.created, b.created, true),
        "createdOldest" => number_order(a.created, b.created, false),
        "sizeLargest" => number_order(a.size.map(|x| x as f64), b.size.map(|x| x as f64), true),
        "sizeSmallest" => number_order(a.size.map(|x| x as f64), b.size.map(|x| x as f64), false),
        "widthAscending" => number_order(
            positive(a.pixel_width.map(|v| v as f64)),
            positive(b.pixel_width.map(|v| v as f64)),
            false,
        ),
        "widthDescending" => number_order(
            positive(a.pixel_width.map(|v| v as f64)),
            positive(b.pixel_width.map(|v| v as f64)),
            true,
        ),
        "heightAscending" => number_order(
            positive(a.pixel_height.map(|v| v as f64)),
            positive(b.pixel_height.map(|v| v as f64)),
            false,
        ),
        "heightDescending" => number_order(
            positive(a.pixel_height.map(|v| v as f64)),
            positive(b.pixel_height.map(|v| v as f64)),
            true,
        ),
        "capturedOldest" => number_order(a.captured, b.captured, false),
        "capturedNewest" => number_order(a.captured, b.captured, true),
        "shutterFastest" => {
            number_order(positive(a.exposure_time), positive(b.exposure_time), false)
        }
        "shutterSlowest" => {
            number_order(positive(a.exposure_time), positive(b.exposure_time), true)
        }
        "apertureAscending" => number_order(positive(a.aperture), positive(b.aperture), false),
        "apertureDescending" => number_order(positive(a.aperture), positive(b.aperture), true),
        "makeAscending" => text(a.camera_make.as_deref(), b.camera_make.as_deref(), false),
        "makeDescending" => text(a.camera_make.as_deref(), b.camera_make.as_deref(), true),
        "modelAscending" => text(a.camera_model.as_deref(), b.camera_model.as_deref(), false),
        "modelDescending" => text(a.camera_model.as_deref(), b.camera_model.as_deref(), true),
        "colorSpaceAscending" => text(a.color_space.as_deref(), b.color_space.as_deref(), false),
        "colorSpaceDescending" => text(a.color_space.as_deref(), b.color_space.as_deref(), true),
        "typeAscending" | "typeDescending" => {
            let descending = sort == "typeDescending";
            if keys.is_some() {
                text(None, None, descending)
            } else {
                text(
                    file_type(&a.name).as_deref(),
                    file_type(&b.name).as_deref(),
                    descending,
                )
            }
        }
        "northToSouth" => number_order(a.latitude, b.latitude, true),
        "southToNorth" => number_order(a.latitude, b.latitude, false),
        "eastToWest" => number_order(a.longitude, b.longitude, true),
        "westToEast" => number_order(a.longitude, b.longitude, false),
        _ => names(),
    }
}
struct QueryItem {
    index: usize,
    key: QuerySortKey,
}
struct PreparedQuery {
    items: Vec<QueryItem>,
    sort: String,
}
fn query_text_key(asset: &Asset, sort: &str) -> Option<String> {
    let value = match sort {
        "makeAscending" | "makeDescending" => asset.camera_make.as_deref(),
        "modelAscending" | "modelDescending" => asset.camera_model.as_deref(),
        "colorSpaceAscending" | "colorSpaceDescending" => asset.color_space.as_deref(),
        "typeAscending" | "typeDescending" => {
            return file_type(&asset.name).map(|value| normalized(&value));
        }
        _ => None,
    };
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(normalized)
}
fn prepare_query(assets: &[Asset], options: Options) -> Result<PreparedQuery> {
    if assets.len() > MAX_ASSETS {
        return Err("Too many images".into());
    }
    let geographic = options
        .geographic_selection
        .map(geography::PreparedSelection::new)
        .transpose()?;
    let search = normalized(options.search_text.trim());
    let terms: Vec<_> = search.split_whitespace().collect();
    let mut items = Vec::with_capacity(assets.len());
    for (index, asset) in assets.iter().enumerate() {
        if geographic
            .as_ref()
            .is_some_and(|selection| !selection.contains(asset.latitude, asset.longitude))
            || (!options.formats.is_empty()
                && !options
                    .formats
                    .iter()
                    .any(|format| format == format_group(&asset.name)))
        {
            continue;
        }
        // A query owns only short-lived sort keys. Reuse each normalized name for
        // search, every comparison and every metadata tie instead of allocating
        // two Unicode buffers on each O(n log n) comparator invocation.
        let name = normalized(&asset.name);
        if terms.iter().all(|term| name.contains(term)) {
            items.push(QueryItem {
                index,
                key: QuerySortKey {
                    name,
                    text: query_text_key(asset, &options.sort),
                },
            });
        }
    }
    Ok(PreparedQuery {
        items,
        sort: options.sort,
    })
}
fn sort_query(assets: &[Asset], prepared: &mut PreparedQuery) {
    prepared.items.sort_by(|left, right| {
        let (a, b) = (&assets[left.index], &assets[right.index]);
        let order = sort_order_with_keys(a, b, &prepared.sort, Some((&left.key, &right.key)));
        order
            .then_with(|| query_name_order(a, b, &left.key, &right.key))
            .then(left.index.cmp(&right.index))
    });
}
fn query(assets: Vec<Asset>, options: Options) -> Result<Vec<usize>> {
    let mut prepared = prepare_query(&assets, options)?;
    sort_query(&assets, &mut prepared);
    Ok(prepared.items.into_iter().map(|item| item.index).collect())
}
fn stem(name: &str) -> String {
    normalized(
        Path::new(name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(name),
    )
}
fn match_assets(first: Vec<Asset>, second: Vec<Asset>, sort: &str) -> Result<Vec<Pair>> {
    if first.len() + second.len() > MAX_ASSETS {
        return Err("Too many images".into());
    }
    let mut groups: BTreeMap<String, (Vec<usize>, Vec<usize>)> = BTreeMap::new();
    for (i, a) in first.iter().enumerate() {
        groups.entry(stem(&a.name)).or_default().0.push(i);
    }
    for (i, a) in second.iter().enumerate() {
        groups.entry(stem(&a.name)).or_default().1.push(i);
    }
    let mut groups: Vec<_> = groups.into_iter().collect();
    groups.sort_by(|a, b| natural(&a.0, &b.0).then(a.0.cmp(&b.0)));
    let mut pairs = Vec::new();
    for (_, (mut a, mut b)) in groups {
        a.sort_by(|&x, &y| name_order(&first[x], &first[y]));
        b.sort_by(|&x, &y| name_order(&second[x], &second[y]));
        for i in 0..a.len().max(b.len()) {
            pairs.push(Pair {
                first_index: a.get(i).copied(),
                second_index: b.get(i).copied(),
            });
        }
    }
    // A row uses A metadata when present, otherwise B. This keeps paired files
    // together while making the selected date/size/GPS direction affect navigation.
    let representative = |pair: &Pair| -> &Asset {
        pair.first_index
            .map(|index| &first[index])
            .unwrap_or_else(|| &second[pair.second_index.expect("A comparison row has a member")])
    };
    pairs.sort_by(|a, b| {
        let (left, right) = (representative(a), representative(b));
        let name = natural(&stem(&left.name), &stem(&right.name));
        let primary = match sort {
            "nameAscending" => name,
            "nameDescending" => name.reverse(),
            _ => sort_order(left, right, sort),
        };
        primary.then(name).then_with(|| name_order(left, right))
    });
    Ok(pairs)
}
fn scan(path: &str) -> Result<Vec<Asset>> {
    let mut assets = Vec::new();
    for entry in fs::read_dir(path).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let Ok(meta) = entry.path().metadata() else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let Some(path) = entry.path().to_str().map(str::to_owned) else {
            continue;
        };
        assets.push(Asset {
            path,
            name,
            size: Some(meta.len()),
            modified: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64()),
            created: meta
                .created()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64()),
            latitude: None,
            longitude: None,
            entry_path: None,
            ..Default::default()
        });
        if assets.len() > MAX_ASSETS {
            return Err("Too many files".into());
        }
    }
    assets.sort_by(name_order);
    Ok(assets)
}
fn execute(input: &[u8]) -> Result<Value> {
    let request: Request = serde_json::from_slice(input).map_err(|e| e.to_string())?;
    match request {
        Request::Limits {
            mode,
            snapshot,
            storage,
        } => Ok(json!(policy::adaptive(&mode, &snapshot, &storage))),
        Request::Scan { path } => Ok(json!(scan(&path)?)),
        Request::Query { assets, options } => Ok(json!(query(assets, options)?)),
        Request::Match {
            first,
            second,
            sort,
        } => Ok(json!(match_assets(first, second, &sort)?)),
        Request::Zip {
            path,
            destination,
            extensions,
        } => Ok(json!(archive::extract(
            &path,
            &destination,
            &extensions.into_iter().collect::<HashSet<_>>()
        )?)),
    }
}
#[repr(C)]
pub struct AmBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}
impl AmBuffer {
    fn empty() -> Self {
        Self {
            ptr: std::ptr::null_mut(),
            len: 0,
        }
    }
    fn new(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        Self {
            ptr: Box::into_raw(bytes) as *mut u8,
            len,
        }
    }
}
#[repr(C)]
pub struct AmRaster {
    pub pixels: AmBuffer,
    pub error: AmBuffer,
    pub width: u32,
    pub height: u32,
    pub linear: u32,
}
/// The caller keeps input alive during this call; returned bytes have one Rust-owned allocation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn am_engine_json(input: *const u8, len: usize) -> AmBuffer {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if input.is_null() || len > MAX_REQUEST {
            return Err("Invalid engine request".into());
        }
        execute(unsafe { std::slice::from_raw_parts(input, len) })
    }))
    .unwrap_or_else(|_| Err("Engine request failed safely".into()));
    let value = match result {
        Ok(data) => json!({"ok":true,"data":data}),
        Err(error) => json!({"ok":false,"error":error}),
    };
    AmBuffer::new(
        serde_json::to_vec(&value)
            .unwrap_or_else(|_| b"{\"ok\":false,\"error\":\"Encoding failed\"}".to_vec()),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn am_decode(input: *const u8, len: usize, format: u32) -> AmRaster {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if input.is_null() || len > 512 * 1024 * 1024 {
            return Err("Invalid or oversized image".into());
        }
        let bytes = unsafe { std::slice::from_raw_parts(input, len) };
        match format {
            1 => raster::qoi(bytes),
            2 => raster::pcx(bytes),
            _ => Err("Unsupported decoder".into()),
        }
    }))
    .unwrap_or_else(|_| Err("Decoder failed safely".into()));
    match result {
        Ok(r) => AmRaster {
            pixels: AmBuffer::new(r.pixels),
            error: AmBuffer::empty(),
            width: r.width,
            height: r.height,
            linear: r.linear as u32,
        },
        Err(e) => AmRaster {
            pixels: AmBuffer::empty(),
            error: AmBuffer::new(e.into_bytes()),
            width: 0,
            height: 0,
            linear: 0,
        },
    }
}
/// Only the pointer and exact length returned by this library may be supplied, once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn am_buffer_free(buffer: AmBuffer) {
    if !buffer.ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn a(name: &str) -> Asset {
        Asset {
            path: name.into(),
            name: name.into(),
            size: None,
            modified: None,
            created: None,
            latitude: None,
            longitude: None,
            entry_path: None,
            ..Default::default()
        }
    }
    #[test]
    fn natural_numeric_unicode() {
        assert_eq!(natural("사진2.jpg", "사진10.jpg"), Ordering::Less);
        assert_eq!(normalized("사진"), normalized("사진"));
        assert_eq!(
            natural("a99999999999999999999999", "a100000000000000000000000"),
            Ordering::Less
        );
    }
    #[test]
    fn pairs_preserve_duplicates_and_missing() {
        let r = match_assets(
            vec![a("001.jpg"), a("001.png"), a("3.jpg")],
            vec![a("001.webp"), a("2.png")],
            "nameAscending",
        )
        .unwrap();
        assert_eq!(
            r,
            vec![
                Pair {
                    first_index: Some(0),
                    second_index: Some(0)
                },
                Pair {
                    first_index: Some(1),
                    second_index: None
                },
                Pair {
                    first_index: None,
                    second_index: Some(1)
                },
                Pair {
                    first_index: Some(2),
                    second_index: None
                }
            ]
        );
    }
    #[test]
    fn comparison_rows_follow_sort_and_fallback_to_b_metadata() {
        let mut first = vec![a("001.jpg"), a("002.jpg"), a("004.jpg")];
        first[0].modified = Some(10.);
        first[1].modified = Some(30.);
        first[0].size = Some(100);
        first[1].size = Some(300);
        first[0].latitude = Some(-20.);
        first[1].latitude = Some(50.);
        let mut second = vec![a("001.png"), a("003.png")];
        second[0].modified = Some(999.);
        second[1].modified = Some(20.);
        second[0].size = Some(999);
        second[1].size = Some(200);
        second[0].latitude = Some(90.);
        second[1].latitude = Some(10.);
        for sort in ["modifiedNewest", "sizeLargest", "northToSouth"] {
            let rows = match_assets(first.clone(), second.clone(), sort).unwrap();
            assert_eq!(
                rows.iter().map(|p| p.first_index).collect::<Vec<_>>(),
                vec![Some(1), None, Some(0), Some(2)]
            );
        }
        let rows = match_assets(first.clone(), second.clone(), "nameDescending").unwrap();
        assert_eq!(
            rows.iter().map(|p| p.first_index).collect::<Vec<_>>(),
            vec![Some(2), None, Some(1), Some(0)]
        );
        let rows = match_assets(first, second, "southToNorth").unwrap();
        assert_eq!(
            rows.iter().map(|p| p.first_index).collect::<Vec<_>>(),
            vec![Some(0), None, Some(1), Some(2)]
        );
    }
    #[test]
    fn gps_missing_always_last() {
        let mut v = vec![a("a"), a("b"), a("c")];
        v[1].latitude = Some(-20.);
        v[2].latitude = Some(60.);
        let o = Options {
            sort: "northToSouth".into(),
            ..Default::default()
        };
        assert_eq!(query(v, o).unwrap(), vec![2, 1, 0]);
    }
    #[test]
    fn search_filter_and_natural_order() {
        let v = vec![a("Cat10.png"), a("CAT2.jpg"), a("dog1.jpg"), a("cat1.jpg")];
        let o = Options {
            search_text: " cat ".into(),
            formats: vec!["jpeg".into()],
            ..Default::default()
        };
        assert_eq!(query(v, o).unwrap(), vec![3, 1]);
    }
    #[test]
    fn metadata_numbers_missing_last_and_names_break_ties() {
        let mut assets = vec![a("a.jpg"), a("photo10.jpg"), a("z.jpg"), a("photo2.jpg")];
        for (index, value) in [(1, 20), (2, 100), (3, 20)] {
            assets[index].pixel_width = Some(value);
            assets[index].pixel_height = Some(value);
            assets[index].captured = Some(value as f64);
            assets[index].exposure_time = Some(value as f64 / 1000.);
            assets[index].aperture = Some(value as f64 / 10.);
        }
        for sort in [
            "widthAscending",
            "heightAscending",
            "capturedOldest",
            "shutterFastest",
            "apertureAscending",
        ] {
            assert_eq!(
                query(
                    assets.clone(),
                    Options {
                        sort: sort.into(),
                        ..Default::default()
                    }
                )
                .unwrap(),
                vec![3, 1, 2, 0]
            );
        }
        for sort in [
            "widthDescending",
            "heightDescending",
            "capturedNewest",
            "shutterSlowest",
            "apertureDescending",
        ] {
            assert_eq!(
                query(
                    assets.clone(),
                    Options {
                        sort: sort.into(),
                        ..Default::default()
                    }
                )
                .unwrap(),
                vec![2, 3, 1, 0]
            );
        }
        assets[0].pixel_width = Some(0);
        assets[0].exposure_time = Some(f64::NAN);
        assets[0].aperture = Some(-1.);
        for sort in ["widthDescending", "shutterSlowest", "apertureDescending"] {
            assert_eq!(
                query(
                    assets.clone(),
                    Options {
                        sort: sort.into(),
                        ..Default::default()
                    }
                )
                .unwrap()
                .last(),
                Some(&0)
            );
        }
    }
    #[test]
    fn metadata_text_and_extension_ordering() {
        let mut assets = vec![a("a.jpg"), a("photo10.jpg"), a("z.jpg"), a("photo2.jpg")];
        for (index, value) in [(0, " "), (1, "Maker2"), (2, "Maker10"), (3, " maker2 ")] {
            assets[index].camera_make = Some(value.into());
            assets[index].camera_model = Some(value.into());
            assets[index].color_space = Some(value.into());
        }
        for sort in ["makeAscending", "modelAscending", "colorSpaceAscending"] {
            assert_eq!(
                query(
                    assets.clone(),
                    Options {
                        sort: sort.into(),
                        ..Default::default()
                    }
                )
                .unwrap(),
                vec![3, 1, 2, 0]
            );
        }
        for sort in ["makeDescending", "modelDescending", "colorSpaceDescending"] {
            assert_eq!(
                query(
                    assets.clone(),
                    Options {
                        sort: sort.into(),
                        ..Default::default()
                    }
                )
                .unwrap(),
                vec![2, 3, 1, 0]
            );
        }
        let types = vec![
            a("a"),
            a("photo10.JPG"),
            a("video.MOV"),
            a("z.png"),
            a("photo2.jpeg"),
        ];
        assert_eq!(
            query(
                types.clone(),
                Options {
                    sort: "typeAscending".into(),
                    ..Default::default()
                }
            )
            .unwrap(),
            vec![4, 1, 2, 3, 0]
        );
        assert_eq!(
            query(
                types,
                Options {
                    sort: "typeDescending".into(),
                    ..Default::default()
                }
            )
            .unwrap(),
            vec![3, 2, 4, 1, 0]
        );
    }
    #[test]
    fn metadata_comparison_and_legacy_record() {
        let legacy: Asset =
            serde_json::from_str(r#"{"path":"old.jpg","name":"old.jpg","size":42}"#).unwrap();
        assert!(legacy.pixel_width.is_none() && legacy.camera_make.is_none());
        let mut first = vec![a("01.jpg"), a("03.jpg"), a("04.jpg")];
        first[0].pixel_width = Some(200);
        first[1].pixel_width = Some(100);
        let mut second = vec![a("01.png"), a("02.png")];
        second[0].pixel_width = Some(999);
        second[1].pixel_width = Some(150);
        let rows = match_assets(first, second, "widthDescending").unwrap();
        assert_eq!(
            rows.iter().map(|p| p.first_index).collect::<Vec<_>>(),
            vec![Some(0), None, Some(1), Some(2)]
        );
    }
    #[test]
    fn invalid_json_is_an_error() {
        let b = unsafe { am_engine_json(b"{".as_ptr(), 1) };
        let v: Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(b.ptr, b.len) }).unwrap();
        assert_eq!(v["ok"], false);
        unsafe { am_buffer_free(b) };
    }
}
