//! Canonical source pixels with explicit crop, scale and padding transforms.
pub fn fit(width: u32, height: u32, limit: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest == 0 || limit == 0 {
        return (0, 0);
    }
    if longest <= limit {
        return (width, height);
    }
    let scale = |v: u32| ((u64::from(v) * u64::from(limit) + u64::from(longest) / 2) / u64::from(longest)).max(1) as u32;
    (scale(width), scale(height))
}
#[allow(dead_code)]
#[derive(Clone, Copy)]
pub struct Transform {
    pub origin: [f64; 2],
    pub extent: [f64; 2],
    pub preview: [f64; 2],
    pub padding: [f64; 2],
}
#[allow(dead_code)]
impl Transform {
    fn valid(self) -> bool {
        self.origin.into_iter().chain(self.extent).chain(self.preview).chain(self.padding).all(f64::is_finite)
            && self.extent.into_iter().chain(self.preview).all(|v| v > 0.)
    }
    pub fn source_to_preview(self, point: [f64; 2]) -> Option<[f64; 2]> {
        if !self.valid() || !point.into_iter().all(f64::is_finite) {
            return None;
        }
        Some(std::array::from_fn(|i| (point[i] - self.origin[i]) * self.preview[i] / self.extent[i] + self.padding[i]))
    }
    pub fn preview_to_source(self, point: [f64; 2]) -> Option<[f64; 2]> {
        if !self.valid() || !point.into_iter().all(f64::is_finite) {
            return None;
        }
        Some(std::array::from_fn(|i| (point[i] - self.padding[i]) * self.extent[i] / self.preview[i] + self.origin[i]))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn portrait_is_never_stretched_to_square() {
        assert_eq!(fit(1280, 1813, 768), (542, 768));
        assert_eq!(fit(1280, 1813, 1024), (723, 1024));
        assert_eq!(fit(193, 137, 1024), (193, 137));
    }
    #[test]
    fn cropped_padded_zoomed_noninteger_mapping_round_trips() {
        let t = Transform { origin: [37., 129.], extent: [811., 1337.], preview: [471.3, 777.8], padding: [16., 31.] };
        for p in [[37., 129.], [321.25, 771.35], [848., 1466.]] {
            let r = t.preview_to_source(t.source_to_preview(p).unwrap()).unwrap();
            assert!((r[0] - p[0]).abs() < 1e-9 && (r[1] - p[1]).abs() < 1e-9);
        }
        assert!(Transform { extent: [0., 1.], ..t }.preview_to_source([0., 0.]).is_none());
        assert!(t.preview_to_source([f64::NAN, 0.]).is_none());
    }
}
