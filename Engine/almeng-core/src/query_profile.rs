//! Reproducible, opt-in release measurements and the pre-optimization query oracle.
//! No source image I/O or decoder work is included in these metadata-only fixtures.
use super::*;
use std::{hint::black_box, io::Write, time::Instant};
#[path = "query_oracle.rs"]
mod original;

fn options(sort: &str, filtered: bool) -> Options {
    Options {
        sort: sort.into(),
        formats: if filtered {
            vec!["jpeg".into()]
        } else {
            vec![]
        },
        ..Default::default()
    }
}

fn fixture(count: usize) -> Vec<Asset> {
    let mut assets: Vec<_> = (0..count)
        .map(|i| {
            let prefix = [
                "사진",
                "사진",
                "Été",
                "E\u{301}te\u{301}",
                "PHOTO",
                "photo",
                "旅行",
                "صورة",
            ][i % 8];
            let extension = ["jpg", "JPG", "jpeg", "png", "CR3", "heic", "pcx"][i % 7];
            let name = format!("{prefix}_{}_{:04}.{extension}", i % 113, i % 29);
            Asset {
                path: format!("/synthetic/query-profile/{i}/{name}"),
                name,
                size: (i % 13 != 0).then_some(((i % 37) * 1024) as u64),
                modified: (i % 9 != 0).then_some((i % 47) as f64),
                created: (i % 11 != 0).then_some((i % 41) as f64),
                latitude: (i % 5 != 0).then_some((i % 161) as f64 - 80.),
                longitude: (i % 5 != 0).then_some((i % 341) as f64 - 170.),
                pixel_width: (i % 7 != 0).then_some((i % 17 * 256) as u64),
                pixel_height: (i % 7 != 0).then_some((i % 19 * 256) as u64),
                captured: (i % 9 != 0).then_some((i % 31) as f64),
                exposure_time: (i % 11 != 0).then_some((i % 23) as f64 / 1000.),
                aperture: (i % 13 != 0).then_some((i % 11) as f64 / 2.),
                camera_make: (i % 7 != 0)
                    .then(|| ["Maker2", "Maker10", " maker2 ", " ", "メーカー1"][i % 5].into()),
                camera_model: (i % 7 != 0).then(|| format!("Model{}", i % 17)),
                color_space: (i % 7 != 0).then(|| ["P3", "sRGB", " "][i % 3].into()),
                ..Default::default()
            }
        })
        .collect();
    let mut state = 0x86_729_20000_u64;
    for i in (1..count).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        assets.swap(i, state as usize % (i + 1));
    }
    assets
}

// Deliberately preserve the original implementation as an independent oracle.
fn clone_selection(selection: &geography::Selection) -> geography::Selection {
    use geography::Selection;
    match selection {
        Selection::Radius { center, meters } => Selection::Radius {
            center: *center,
            meters: *meters,
        },
        Selection::Rectangle {
            south_west,
            north_east,
        } => Selection::Rectangle {
            south_west: *south_west,
            north_east: *north_east,
        },
        Selection::Polygon { points } => Selection::Polygon {
            points: points.clone(),
        },
        Selection::Multiple { areas } => Selection::Multiple {
            areas: areas.iter().map(clone_selection).collect(),
        },
    }
}

fn legacy_filter(assets: &[Asset], options: &Options) -> Result<Vec<usize>> {
    if assets.len() > MAX_ASSETS {
        return Err("Too many images".into());
    }
    let geographic = options
        .geographic_selection
        .as_ref()
        .map(clone_selection)
        .map(geography::PreparedSelection::new)
        .transpose()?;
    let search = original::normalized(options.search_text.trim());
    let terms: Vec<_> = search.split_whitespace().collect();
    Ok((0..assets.len())
        .filter(|&i| {
            let name = original::normalized(&assets[i].name);
            geographic
                .as_ref()
                .is_none_or(|selection| selection.contains(assets[i].latitude, assets[i].longitude))
                && terms.iter().all(|term| name.contains(term))
                && (options.formats.is_empty()
                    || options
                        .formats
                        .iter()
                        .any(|f| f == original::format_group(&assets[i].name)))
        })
        .collect())
}

fn legacy_sort(assets: &[Asset], indices: &mut [usize], sort: &str) {
    indices.sort_by(|&i, &j| {
        let (a, b) = (&assets[i], &assets[j]);
        original::sort_order(a, b, sort)
            .then_with(|| original::name_order(a, b))
            .then(i.cmp(&j))
    });
}

fn legacy_query(assets: &[Asset], options: &Options) -> Result<Vec<usize>> {
    original::query(
        assets.to_vec(),
        Options {
            search_text: options.search_text.clone(),
            sort: options.sort.clone(),
            formats: options.formats.clone(),
            geographic_selection: options.geographic_selection.as_ref().map(clone_selection),
        },
    )
}

fn digest(indices: &[usize]) -> String {
    let mut value = 0xcbf29ce484222325_u64;
    for &index in indices {
        for byte in (index as u64).to_le_bytes() {
            value = (value ^ byte as u64).wrapping_mul(0x100000001b3);
        }
    }
    format!("{value:016x}")
}

#[test]
fn query_matches_original_for_all_sort_modes_and_filters() {
    let mut assets = fixture(729);
    assets.extend(
        [
            "photo2.jpg",
            "photo02.jpg",
            "photo0002.jpg",
            "photo999999999999999999999999.jpg",
            "photo1000000000000000000000000.jpg",
            "duplicate.jpg",
            "duplicate.jpg",
            "file",
            ".hidden",
            "value. ",
        ]
        .map(|name| Asset {
            path: "/same/path".into(),
            name: name.into(),
            ..Default::default()
        }),
    );
    assets[0].modified = Some(f64::NAN);
    assets[1].exposure_time = Some(f64::INFINITY);
    assets[2].aperture = Some(-1.);
    for sort in [
        "nameAscending",
        "nameDescending",
        "modifiedNewest",
        "modifiedOldest",
        "createdNewest",
        "createdOldest",
        "sizeLargest",
        "sizeSmallest",
        "widthAscending",
        "widthDescending",
        "heightAscending",
        "heightDescending",
        "capturedOldest",
        "capturedNewest",
        "shutterFastest",
        "shutterSlowest",
        "apertureAscending",
        "apertureDescending",
        "makeAscending",
        "makeDescending",
        "modelAscending",
        "modelDescending",
        "colorSpaceAscending",
        "colorSpaceDescending",
        "typeAscending",
        "typeDescending",
        "northToSouth",
        "southToNorth",
        "eastToWest",
        "westToEast",
        "unknownFallsBackToName",
    ] {
        for filtered in [false, true] {
            for search in ["", "사진", "photo 2", "e\u{301}te\u{301}"] {
                let mut opt = options(sort, filtered);
                opt.search_text = search.into();
                let expected = legacy_query(&assets, &opt).unwrap();
                assert_eq!(
                    query(assets.clone(), opt).unwrap(),
                    expected,
                    "sort={sort}, filtered={filtered}, search={search}"
                );
            }
        }
    }
}

#[test]
fn prepared_query_keeps_geography_and_invalid_selection_results() {
    let assets = fixture(729);
    for selection in [
        json!({"kind":"rectangle","southWest":{"latitude":-20,"longitude":170},"northEast":{"latitude":40,"longitude":-170}}),
        json!({"kind":"radius","center":{"latitude":10,"longitude":20},"meters":1_000_000}),
        json!({"kind":"polygon","points":[{"latitude":-30,"longitude":-100},{"latitude":40,"longitude":-100},{"latitude":0,"longitude":100}]}),
        json!({"kind":"multiple","areas":[]}),
        json!({"kind":"radius","center":{"latitude":100,"longitude":20},"meters":1}),
    ] {
        for sort in ["nameDescending", "northToSouth", "makeAscending"] {
            let mut opt = options(sort, false);
            opt.geographic_selection = Some(serde_json::from_value(selection.clone()).unwrap());
            let expected = legacy_query(&assets, &opt);
            assert_eq!(query(assets.clone(), opt), expected);
        }
    }
}

#[test]
#[ignore = "opt-in release benchmark; writes raw samples to ALMENG_QUERY_PROFILE_DIRECTORY"]
fn profile_query_release_stages() {
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    let directory =
        std::env::var("ALMENG_QUERY_PROFILE_DIRECTORY").expect("profile output directory");
    let label = std::env::var("ALMENG_QUERY_PROFILE_LABEL").unwrap_or_else(|_| "unlabelled".into());
    fs::create_dir_all(&directory).unwrap();
    let mut output =
        fs::File::create(Path::new(&directory).join(format!("{label}.jsonl"))).unwrap();
    for count in [729, 20_000] {
        let assets = fixture(count);
        fs::write(
            Path::new(&directory).join(format!("fixture-{count}.json")),
            serde_json::to_vec(&assets).unwrap(),
        )
        .unwrap();
        for sort in ["nameAscending", "modifiedNewest", "makeAscending"] {
            for filtered in [false, true] {
                let opt = options(sort, filtered);
                let expected = legacy_query(&assets, &opt).unwrap();
                let request = serde_json::to_vec(&json!({"op":"query", "assets": assets, "options": {"sort":sort, "formats":opt.formats}})).unwrap();
                for round in 0..9 {
                    let start = Instant::now();
                    let Request::Query {
                        assets: decoded,
                        options: parsed_options,
                    } = serde_json::from_slice(black_box(&request)).unwrap()
                    else {
                        unreachable!()
                    };
                    let parse_ns = start.elapsed().as_nanos();
                    let start = Instant::now();
                    let mut staged = legacy_filter(black_box(&decoded), &parsed_options).unwrap();
                    let filter_ns = start.elapsed().as_nanos();
                    let start = Instant::now();
                    legacy_sort(&decoded, &mut staged, &parsed_options.sort);
                    let legacy_sort_ns = start.elapsed().as_nanos();
                    assert_eq!(staged, expected);
                    let start = Instant::now();
                    let mut prepared = prepare_query(&decoded, options(sort, filtered)).unwrap();
                    let prepared_ns = start.elapsed().as_nanos();
                    let start = Instant::now();
                    sort_query(&decoded, &mut prepared);
                    let prepared_sort_ns = start.elapsed().as_nanos();
                    assert_eq!(
                        prepared
                            .items
                            .iter()
                            .map(|item| item.index)
                            .collect::<Vec<_>>(),
                        expected
                    );
                    let start = Instant::now();
                    let result = query(decoded, parsed_options).unwrap();
                    let query_ns = start.elapsed().as_nanos();
                    assert_eq!(result, expected);
                    let start = Instant::now();
                    let encoded = serde_json::to_vec(&json!({"ok":true,"data":result})).unwrap();
                    let encode_ns = start.elapsed().as_nanos();
                    black_box(encoded);
                    let start = Instant::now();
                    let buffer = unsafe { am_engine_json(request.as_ptr(), request.len()) };
                    let ffi_ns = start.elapsed().as_nanos();
                    let reply: Value = serde_json::from_slice(unsafe {
                        std::slice::from_raw_parts(buffer.ptr, buffer.len)
                    })
                    .unwrap();
                    unsafe { am_buffer_free(buffer) };
                    assert_eq!(
                        serde_json::from_value::<Vec<usize>>(reply["data"].clone()).unwrap(),
                        expected
                    );
                    if round >= 2 {
                        writeln!(output, "{}", json!({"label":label,"count":count,"sort":sort,"filtered":filtered,"sample":round-2,"requestBytes":request.len(),"matched":expected.len(),"orderedIndexDigest":digest(&expected),"jsonParseNs":parse_ns,"legacyFilterNs":filter_ns,"legacySortNs":legacy_sort_ns,"preparedFilterAndKeysNs":prepared_ns,"preparedSortNs":prepared_sort_ns,"queryNs":query_ns,"jsonResponseEncodeNs":encode_ns,"ffiTotalNs":ffi_ns})).unwrap();
                    }
                }
            }
        }
    }
}
