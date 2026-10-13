use serde::Deserialize;

#[derive(Clone, Copy, Debug, Deserialize)]
pub struct Coordinate {
    latitude: f64,
    longitude: f64,
}
impl Coordinate {
    fn valid(self) -> bool {
        self.latitude.is_finite()
            && self.longitude.is_finite()
            && (-90.0..=90.0).contains(&self.latitude)
            && (-180.0..=180.0).contains(&self.longitude)
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Selection {
    Radius {
        center: Coordinate,
        meters: f64,
    },
    Rectangle {
        #[serde(rename = "southWest")]
        south_west: Coordinate,
        #[serde(rename = "northEast")]
        north_east: Coordinate,
    },
    Polygon {
        points: Vec<Coordinate>,
    },
    Multiple {
        areas: Vec<Selection>,
    },
}

/// Prepare polygon geometry once for a collection, not once per photo. Longitudes
/// are unwrapped across the date line; map drawing uses Web Mercator latitude.
pub enum PreparedSelection {
    Radius(Coordinate, f64),
    Rectangle(Coordinate, Coordinate),
    Polygon(Vec<(f64, f64)>, f64),
    Multiple(Vec<PreparedSelection>),
}
const EARTH_RADIUS: f64 = 6_371_008.8;
const MAXIMUM_AREA_COUNT: usize = 3;
fn unwrap_near(value: f64, reference: f64) -> f64 {
    reference + (value - reference + 180.0).rem_euclid(360.0) - 180.0
}
fn mercator(latitude: f64) -> f64 {
    let radians = latitude.clamp(-85.051_128_78, 85.051_128_78).to_radians();
    (std::f64::consts::FRAC_PI_4 + radians / 2.0)
        .tan()
        .ln()
        .to_degrees()
}
impl PreparedSelection {
    pub fn new(selection: Selection) -> Result<Self, String> {
        match selection {
            Selection::Radius { center, meters } => {
                if !center.valid()
                    || !meters.is_finite()
                    || meters <= 0.0
                    || meters > EARTH_RADIUS * std::f64::consts::PI
                {
                    return Err("Invalid map radius".into());
                }
                Ok(Self::Radius(center, meters))
            }
            Selection::Rectangle {
                south_west,
                north_east,
            } => {
                if !south_west.valid()
                    || !north_east.valid()
                    || south_west.latitude >= north_east.latitude
                    || south_west.longitude == north_east.longitude
                {
                    return Err("Invalid map rectangle".into());
                }
                Ok(Self::Rectangle(south_west, north_east))
            }
            Selection::Polygon { points } => {
                if !(3..=512).contains(&points.len()) || points.iter().any(|p| !p.valid()) {
                    return Err("Invalid drawn map area".into());
                }
                let mut previous = points[0].longitude;
                let mut vertices = Vec::with_capacity(points.len());
                for point in points {
                    let x = unwrap_near(point.longitude, previous);
                    vertices.push((x, mercator(point.latitude)));
                    previous = x;
                }
                let (ax, ay) = vertices[0];
                let Some(&(bx, by)) = vertices
                    .iter()
                    .find(|&&(x, y)| (x - ax).abs() + (y - ay).abs() > 1e-12)
                else {
                    return Err("Drawn map area is empty".into());
                };
                if !vertices
                    .iter()
                    .any(|&(x, y)| ((x - ax) * (by - ay) - (y - ay) * (bx - ax)).abs() > 1e-12)
                {
                    return Err("Drawn map area has no width".into());
                }
                let min = vertices.iter().map(|p| p.0).fold(f64::INFINITY, f64::min);
                let max = vertices
                    .iter()
                    .map(|p| p.0)
                    .fold(f64::NEG_INFINITY, f64::max);
                if max - min >= 360.0 {
                    return Err("Drawn area wraps the world".into());
                }
                Ok(Self::Polygon(vertices, (min + max) / 2.0))
            }
            Selection::Multiple { areas } => {
                if !(1..=MAXIMUM_AREA_COUNT).contains(&areas.len())
                    || areas
                        .iter()
                        .any(|area| matches!(area, Selection::Multiple { .. }))
                {
                    return Err("A map selection needs 1...3 individual areas".into());
                }
                areas
                    .into_iter()
                    .map(Self::new)
                    .collect::<Result<Vec<_>, _>>()
                    .map(Self::Multiple)
            }
        }
    }

    pub fn contains(&self, latitude: Option<f64>, longitude: Option<f64>) -> bool {
        let (Some(latitude), Some(longitude)) = (latitude, longitude) else {
            return false;
        };
        let point = Coordinate {
            latitude,
            longitude,
        };
        if !point.valid() {
            return false;
        }
        match self {
            Self::Radius(center, meters) => {
                let lat_delta = (latitude - center.latitude).to_radians();
                let lon_delta = (longitude - center.longitude).to_radians();
                let a = (lat_delta / 2.0).sin().powi(2)
                    + latitude.to_radians().cos()
                        * center.latitude.to_radians().cos()
                        * (lon_delta / 2.0).sin().powi(2);
                2.0 * EARTH_RADIUS * a.clamp(0.0, 1.0).sqrt().asin() <= *meters + 1e-6
            }
            Self::Rectangle(sw, ne) => {
                let inside_longitude = if sw.longitude <= ne.longitude {
                    longitude >= sw.longitude && longitude <= ne.longitude
                } else {
                    longitude >= sw.longitude || longitude <= ne.longitude
                };
                latitude >= sw.latitude && latitude <= ne.latitude && inside_longitude
            }
            Self::Polygon(vertices, center) => {
                let x = unwrap_near(longitude, *center);
                let y = mercator(latitude);
                let mut inside = false;
                let mut previous = vertices[vertices.len() - 1];
                for &(bx, by) in vertices {
                    let (ax, ay) = previous;
                    // Edges are included, including vertices and horizontal edges.
                    let cross = (x - ax) * (by - ay) - (y - ay) * (bx - ax);
                    let tolerance = 1e-9 * ((bx - ax).abs() + (by - ay).abs()).max(1.0);
                    if cross.abs() <= tolerance
                        && x >= ax.min(bx) - 1e-9
                        && x <= ax.max(bx) + 1e-9
                        && y >= ay.min(by) - 1e-9
                        && y <= ay.max(by) + 1e-9
                    {
                        return true;
                    }
                    if (ay > y) != (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax {
                        inside = !inside;
                    }
                    previous = (bx, by);
                }
                inside
            }
            Self::Multiple(areas) => areas
                .iter()
                .any(|area| area.contains(Some(latitude), Some(longitude))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn p(latitude: f64, longitude: f64) -> Coordinate {
        Coordinate {
            latitude,
            longitude,
        }
    }
    #[test]
    fn radius_uses_distance_not_a_bounding_square() {
        let selection = PreparedSelection::new(Selection::Radius {
            center: p(0.0, 0.0),
            meters: 112_000.0,
        })
        .unwrap();
        assert!(selection.contains(Some(1.0), Some(0.0)));
        assert!(!selection.contains(Some(1.0), Some(1.0)));
        assert!(!selection.contains(None, Some(0.0)));
        assert!(!selection.contains(Some(f64::NAN), Some(0.0)));
    }
    #[test]
    fn radius_wraps_date_line_and_handles_poles() {
        let selection = PreparedSelection::new(Selection::Radius {
            center: p(0.0, 179.9),
            meters: 30_000.0,
        })
        .unwrap();
        assert!(selection.contains(Some(0.0), Some(-179.9)));
        assert!(!selection.contains(Some(0.0), Some(0.0)));
        let pole = PreparedSelection::new(Selection::Radius {
            center: p(90.0, 0.0),
            meters: 120_000.0,
        })
        .unwrap();
        assert!(pole.contains(Some(89.0), Some(170.0)));
    }
    #[test]
    fn rectangle_wraps_and_includes_boundaries() {
        let selection = PreparedSelection::new(Selection::Rectangle {
            south_west: p(-10.0, 170.0),
            north_east: p(10.0, -170.0),
        })
        .unwrap();
        assert!(selection.contains(Some(-10.0), Some(170.0)));
        assert!(selection.contains(Some(0.0), Some(-179.0)));
        assert!(!selection.contains(Some(0.0), Some(0.0)));
    }
    #[test]
    fn polygon_tests_shape_edges_and_date_line() {
        let selection = PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 179.0), p(0.0, -179.0), p(2.0, -179.0), p(2.0, 179.0)],
        })
        .unwrap();
        assert!(selection.contains(Some(1.0), Some(180.0)));
        assert!(selection.contains(Some(0.0), Some(179.0)));
        assert!(!selection.contains(Some(1.0), Some(0.0)));
        assert!(!selection.contains(Some(3.0), Some(180.0)));
        let triangle = PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 0.0), p(0.0, 2.0), p(2.0, 0.0)],
        })
        .unwrap();
        assert!(triangle.contains(Some(0.5), Some(0.5)));
        assert!(!triangle.contains(Some(1.8), Some(1.8)));
    }
    #[test]
    fn multiple_areas_include_any_match_without_accepting_missing_coordinates() {
        let selection = PreparedSelection::new(Selection::Multiple {
            areas: vec![
                Selection::Radius {
                    center: p(0.0, 0.0),
                    meters: 150_000.0,
                },
                Selection::Rectangle {
                    south_west: p(0.0, 0.0),
                    north_east: p(2.0, 2.0),
                },
                Selection::Polygon {
                    points: vec![p(10.0, 10.0), p(10.0, 12.0), p(12.0, 10.0)],
                },
            ],
        })
        .unwrap();
        assert!(selection.contains(Some(-1.0), Some(0.0)));
        assert!(selection.contains(Some(0.5), Some(0.5)));
        assert!(selection.contains(Some(1.8), Some(1.8)));
        assert!(selection.contains(Some(10.2), Some(10.2)));
        assert!(!selection.contains(Some(5.0), Some(5.0)));
        assert!(!selection.contains(None, Some(0.0)));
        assert!(!selection.contains(Some(0.0), None));
        assert!(!selection.contains(Some(f64::NAN), Some(0.0)));
        assert!(!selection.contains(Some(91.0), Some(0.0)));
    }

    #[test]
    fn reject_malformed_multiple_areas_and_invalid_members() {
        fn radius() -> Selection {
            Selection::Radius {
                center: p(0.0, 0.0),
                meters: 100.0,
            }
        }
        assert!(PreparedSelection::new(Selection::Multiple { areas: vec![] }).is_err());
        assert!(PreparedSelection::new(Selection::Multiple {
            areas: vec![radius(), radius(), radius(), radius()],
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Multiple {
            areas: vec![Selection::Multiple {
                areas: vec![radius()],
            }],
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Multiple {
            areas: vec![
                radius(),
                Selection::Radius {
                    center: p(0.0, 0.0),
                    meters: -1.0,
                },
            ],
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Multiple {
            areas: vec![radius()],
        })
        .is_ok());
    }

    #[test]
    fn multiple_json_keeps_existing_shape_keys() {
        let selection: Selection = serde_json::from_str(
            r#"{"kind":"multiple","areas":[
                {"kind":"radius","center":{"latitude":0,"longitude":0},"meters":1000},
                {"kind":"rectangle","southWest":{"latitude":1,"longitude":1},
                 "northEast":{"latitude":2,"longitude":2}}
            ]}"#,
        )
        .unwrap();
        let prepared = PreparedSelection::new(selection).unwrap();
        assert!(prepared.contains(Some(0.0), Some(0.0)));
        assert!(prepared.contains(Some(1.5), Some(1.5)));
        assert!(!prepared.contains(Some(3.0), Some(3.0)));
    }
    #[test]
    fn reject_invalid_and_unbounded_selections() {
        assert!(PreparedSelection::new(Selection::Radius {
            center: p(91.0, 0.0),
            meters: 10.0
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Radius {
            center: p(0.0, 0.0),
            meters: -1.0
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 0.0); 513]
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 0.0); 2]
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 0.0); 3]
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Polygon {
            points: vec![p(0.0, 0.0), p(0.0, 1.0), p(0.0, 2.0)]
        })
        .is_err());
        assert!(PreparedSelection::new(Selection::Rectangle {
            south_west: p(0.0, 0.0),
            north_east: p(0.0, 2.0)
        })
        .is_err());
    }
}
