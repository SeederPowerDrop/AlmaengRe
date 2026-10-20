//! Frozen query implementation from before the query-profile86 optimization.
//! Test-only oracle; never linked into the app.
use super::*;

pub(super) fn normalized(s: &str) -> String {
    s.nfc().flat_map(char::to_lowercase).collect()
}
pub(super) fn natural(a: &str, b: &str) -> Ordering {
    let a = normalized(a);
    let b = normalized(b);
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
pub(super) fn name_order(a: &Asset, b: &Asset) -> Ordering {
    natural(&a.name, &b.name).then_with(|| a.path.cmp(&b.path))
}
pub(super) fn number_order(a: Option<f64>, b: Option<f64>, descending: bool) -> Ordering {
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
pub(super) fn text_order(a: Option<&str>, b: Option<&str>, descending: bool) -> Ordering {
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
pub(super) fn file_type(name: &str) -> Option<String> {
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
pub(super) fn positive(value: Option<f64>) -> Option<f64> {
    value.filter(|n| n.is_finite() && *n > 0.)
}
pub(super) fn format_group(name: &str) -> &'static str {
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
pub(super) fn sort_order(a: &Asset, b: &Asset, sort: &str) -> Ordering {
    match sort {
        "nameDescending" => name_order(b, a),
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
        "makeAscending" => text_order(a.camera_make.as_deref(), b.camera_make.as_deref(), false),
        "makeDescending" => text_order(a.camera_make.as_deref(), b.camera_make.as_deref(), true),
        "modelAscending" => text_order(a.camera_model.as_deref(), b.camera_model.as_deref(), false),
        "modelDescending" => text_order(a.camera_model.as_deref(), b.camera_model.as_deref(), true),
        "colorSpaceAscending" => {
            text_order(a.color_space.as_deref(), b.color_space.as_deref(), false)
        }
        "colorSpaceDescending" => {
            text_order(a.color_space.as_deref(), b.color_space.as_deref(), true)
        }
        "typeAscending" => text_order(
            file_type(&a.name).as_deref(),
            file_type(&b.name).as_deref(),
            false,
        ),
        "typeDescending" => text_order(
            file_type(&a.name).as_deref(),
            file_type(&b.name).as_deref(),
            true,
        ),
        "northToSouth" => number_order(a.latitude, b.latitude, true),
        "southToNorth" => number_order(a.latitude, b.latitude, false),
        "eastToWest" => number_order(a.longitude, b.longitude, true),
        "westToEast" => number_order(a.longitude, b.longitude, false),
        _ => name_order(a, b),
    }
}
pub(super) fn query(assets: Vec<Asset>, options: Options) -> Result<Vec<usize>> {
    if assets.len() > MAX_ASSETS {
        return Err("Too many images".into());
    }
    let geographic = options
        .geographic_selection
        .map(geography::PreparedSelection::new)
        .transpose()?;
    let search = normalized(options.search_text.trim());
    let terms: Vec<_> = search.split_whitespace().collect();
    let mut indices: Vec<_> = (0..assets.len())
        .filter(|&i| {
            let name = normalized(&assets[i].name);
            geographic
                .as_ref()
                .is_none_or(|selection| selection.contains(assets[i].latitude, assets[i].longitude))
                && terms.iter().all(|term| name.contains(term))
                && (options.formats.is_empty()
                    || options
                        .formats
                        .iter()
                        .any(|f| f == format_group(&assets[i].name)))
        })
        .collect();
    indices.sort_by(|&i, &j| {
        let (a, b) = (&assets[i], &assets[j]);
        let order = sort_order(a, b, &options.sort);
        order.then_with(|| name_order(a, b)).then(i.cmp(&j))
    });
    Ok(indices)
}
