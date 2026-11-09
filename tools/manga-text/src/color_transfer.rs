//! Source-boundary-aware approved chroma transfer at existing output luminance.
//! Unsupported edges require review; propagation never grows the selection.
use anyhow::{Result, ensure};
use image::{GrayImage, Luma, Rgb, RgbImage};
use std::collections::VecDeque;
fn neighbors(x: u32, y: u32, w: u32, h: u32) -> impl Iterator<Item = (u32, u32)> {
    [
        x.checked_sub(1).map(|xx| (xx, y)),
        x.checked_add(1).filter(|xx| *xx < w).map(|xx| (xx, y)),
        y.checked_sub(1).map(|yy| (x, yy)),
        y.checked_add(1).filter(|yy| *yy < h).map(|yy| (x, yy)),
    ]
    .into_iter()
    .flatten()
}
#[cfg(test)]
pub fn candidate(base: &RgbImage, mask: &GrayImage, protect: Option<&GrayImage>, color: [u8; 3]) -> Result<RgbImage> {
    let (w, h) = base.dimensions();
    ensure!(mask.dimensions() == (w, h) && protect.is_none_or(|p| p.dimensions() == (w, h)), "Color transfer dimensions differ");
    let radius = w.max(h).div_ceil(256).clamp(4, 12) as u8;
    let mut distance = GrayImage::new(w, h);
    let mut queue = VecDeque::new();
    // 180 marks an edge without trusted matching surrounding chroma. Edges
    // already backed by the approved surrounding color can retain full color.
    for (x, y, p) in mask.enumerate_pixels() {
        if p[0] > 0 && p[0] < 255 {
            distance.put_pixel(x, y, Luma([1]));
            queue.push_back((x, y));
        }
    }
    while let Some((x, y)) = queue.pop_front() {
        let d = distance.get_pixel(x, y)[0];
        if d >= radius {
            continue;
        }
        for (nx, ny) in neighbors(x, y, w, h) {
            if mask.get_pixel(nx, ny)[0] > 0 && distance.get_pixel(nx, ny)[0] == 0 {
                distance.put_pixel(nx, ny, Luma([d + 1]));
                queue.push_back((nx, ny));
            }
        }
    }
    let mut output = base.clone();
    for (x, y, p) in output.enumerate_pixels_mut() {
        if mask.get_pixel(x, y)[0] == 0 || protect.is_some_and(|m| m.get_pixel(x, y)[0] > 0) {
            continue;
        }
        let d = distance.get_pixel(x, y)[0];
        let alpha = if d == 0 { 1. } else { (f64::from(d) / f64::from(radius)).powi(2) };
        let target = super::detail::with_y(Rgb(color), super::detail::y(*p));
        for (channel, target) in p.0.iter_mut().zip(target.0) {
            *channel = (f64::from(*channel) * (1. - alpha) + f64::from(target) * alpha).round().clamp(0., 255.) as u8;
        }
    }
    Ok(output)
}

pub struct Transfer {
    pub image: RgbImage,
    pub evidence: serde_json::Value,
}
fn compatible(pixel: Rgb<u8>, target: Rgb<u8>, lut: &[f64; 256]) -> bool {
    let a = super::fidelity::lab(pixel, lut);
    let b = super::fidelity::lab(target, lut);
    let ca = super::fidelity::chroma(a);
    let cb = super::fidelity::chroma(b);
    if ca < 3. || cb < 3. {
        return false;
    }
    let ratio = ca / cb;
    let cosine = (a[1] * b[1] + a[2] * b[2]) / (ca * cb);
    (0.35..=2.5).contains(&ratio) && cosine >= 0.96
}
pub fn boundary_candidate(source: &RgbImage, base: &RgbImage, mask: &GrayImage, protect: Option<&GrayImage>, color: [u8; 3]) -> Result<Transfer> {
    let (w, h) = base.dimensions();
    ensure!(
        w > 0
            && h > 0
            && u64::from(w) * u64::from(h) <= 120_000_000
            && source.dimensions() == (w, h)
            && mask.dimensions() == (w, h)
            && protect.is_none_or(|p| p.dimensions() == (w, h)),
        "Boundary transfer dimensions differ or exceed 120MP"
    );
    let radius = w.max(h).div_ceil(256).clamp(4, 12) as u8;
    let mut unsupported = GrayImage::new(w, h);
    let mut support = GrayImage::new(w, h);
    let mut anchors = RgbImage::new(w, h);
    let mut fade_queue = VecDeque::new();
    let mut color_queue = VecDeque::new();
    let lut = super::fidelity::linear_table();
    let (mut boundaries, mut contours, mut matches, mut guarded, mut uncertain) = (0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
    for (x, y, p) in mask.enumerate_pixels() {
        if p[0] == 0 || protect.is_some_and(|m| m.get_pixel(x, y)[0] > 0) {
            continue;
        }
        let outside: Vec<_> =
            neighbors(x, y, w, h).filter(|(nx, ny)| mask.get_pixel(*nx, *ny)[0] == 0 || protect.is_some_and(|m| m.get_pixel(*nx, *ny)[0] > 0)).collect();
        if outside.is_empty() {
            continue;
        }
        boundaries += 1;
        let tone = super::detail::y(*source.get_pixel(x, y));
        let contour = (x.saturating_sub(2)..=x.saturating_add(2).min(w - 1)).any(|xx| {
            (y.saturating_sub(2)..=y.saturating_add(2).min(h - 1)).any(|yy| {
                let nearby = super::detail::y(*source.get_pixel(xx, yy));
                nearby < 32. || (tone - nearby).abs() > 45.
            })
        }) || outside.iter().any(|(nx, ny)| (tone - super::detail::y(*source.get_pixel(*nx, *ny))).abs() > 40.);
        if contour {
            contours += 1;
            continue;
        }
        let mut sum = [0_u32; 3];
        let mut count = 0_u32;
        for (nx, ny) in &outside {
            if protect.is_some_and(|m| m.get_pixel(*nx, *ny)[0] > 0) {
                continue;
            }
            let pixel = *base.get_pixel(*nx, *ny);
            if (tone - super::detail::y(*source.get_pixel(*nx, *ny))).abs() < 30. && compatible(pixel, Rgb(color), &lut) {
                for (s, v) in sum.iter_mut().zip(pixel.0) {
                    *s += u32::from(v);
                }
                count += 1;
            }
        }
        if count > 0 {
            matches += 1;
            support.put_pixel(x, y, Luma([1]));
            anchors.put_pixel(x, y, Rgb(sum.map(|v| (v / count) as u8)));
            color_queue.push_back((x, y));
        } else if outside.iter().all(|(nx, ny)| protect.is_some_and(|m| m.get_pixel(*nx, *ny)[0] > 0)) {
            guarded += 1;
        } else {
            uncertain += 1;
            unsupported.put_pixel(x, y, Luma([1]));
            fade_queue.push_back((x, y));
        }
    }
    while let Some((x, y)) = fade_queue.pop_front() {
        let d = unsupported.get_pixel(x, y)[0];
        if d >= radius {
            continue;
        }
        for (nx, ny) in neighbors(x, y, w, h) {
            if mask.get_pixel(nx, ny)[0] > 0
                && unsupported.get_pixel(nx, ny)[0] == 0
                && !protect.is_some_and(|m| m.get_pixel(nx, ny)[0] > 0)
                && (super::detail::y(*source.get_pixel(x, y)) - super::detail::y(*source.get_pixel(nx, ny))).abs() < 30.
            {
                unsupported.put_pixel(nx, ny, Luma([d + 1]));
                fade_queue.push_back((nx, ny));
            }
        }
    }
    while let Some((x, y)) = color_queue.pop_front() {
        let d = support.get_pixel(x, y)[0];
        if d >= radius {
            continue;
        }
        for (nx, ny) in neighbors(x, y, w, h) {
            if mask.get_pixel(nx, ny)[0] > 0
                && support.get_pixel(nx, ny)[0] == 0
                && !protect.is_some_and(|m| m.get_pixel(nx, ny)[0] > 0)
                && (super::detail::y(*source.get_pixel(x, y)) - super::detail::y(*source.get_pixel(nx, ny))).abs() < 30.
            {
                support.put_pixel(nx, ny, Luma([d + 1]));
                anchors.put_pixel(nx, ny, *anchors.get_pixel(x, y));
                color_queue.push_back((nx, ny));
            }
        }
    }
    let mut output = base.clone();
    let (mut max_y, mut sum_y, mut source_delta, mut count_y, mut highlights) = (0_f64, 0_f64, 0_f64, 0_u64, 0_u64);
    let target_y = super::detail::y(Rgb(color));
    for (x, y, p) in output.enumerate_pixels_mut() {
        if mask.get_pixel(x, y)[0] == 0 || protect.is_some_and(|m| m.get_pixel(x, y)[0] > 0) {
            continue;
        }
        let before = *p;
        let current_y = super::detail::y(before);
        source_delta += (super::detail::y(*source.get_pixel(x, y)) - current_y).abs();
        let d = unsupported.get_pixel(x, y)[0];
        let alpha = if d == 0 { 1. } else { (f64::from(d) / f64::from(radius)).powi(2) };
        let sd = support.get_pixel(x, y)[0];
        let mut target = Rgb(color);
        if sd > 0 {
            let anchor = *anchors.get_pixel(x, y);
            let ay = super::detail::y(anchor);
            let weight = 0.2 * (1. - f64::from(sd) / f64::from(radius + 1));
            target = Rgb(std::array::from_fn(|i| {
                (target_y + (1. - weight) * (f64::from(color[i]) - target_y) + weight * (f64::from(anchor[i]) - ay)).round().clamp(0., 255.) as u8
            }));
        }
        let colored = super::detail::with_y(target, current_y);
        for (channel, target) in p.0.iter_mut().zip(colored.0) {
            *channel = (f64::from(*channel) * (1. - alpha) + f64::from(target) * alpha).round().clamp(0., 255.) as u8;
        }
        let delta = (super::detail::y(*p) - current_y).abs();
        max_y = max_y.max(delta);
        sum_y += delta;
        count_y += 1;
        if current_y >= 248. && *p == before {
            highlights += 1;
        }
    }
    let review = boundaries == 0 || (uncertain >= 8 && uncertain as f64 / boundaries.max(1) as f64 > 0.25);
    Ok(Transfer {
        image: output,
        evidence: serde_json::json!({"boundary_pixels":boundaries,"source_contour_supported":contours,"palette_context_supported":matches,"protected_boundaries":guarded,"uncertain_boundaries":uncertain,"requires_boundary_review":review,"propagation_radius":radius,"max_luminance_change":max_y,"mean_luminance_change":sum_y/count_y.max(1) as f64,"mean_source_vs_generated_luminance_difference":source_delta/count_y.max(1) as f64,"approved_palette_chroma":super::fidelity::chroma(super::fidelity::lab(Rgb(color),&lut)),"luminance_preserved":max_y<=1.1,"unchanged_highlight_pixels":highlights,"method":"source-boundary and approved-chroma constrained propagation; no mask growth"}),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_contours_receive_color_without_a_gray_rim_and_keep_ink() {
        let mut source = RgbImage::from_pixel(96, 96, Rgb([255, 255, 255]));
        let mut base = RgbImage::from_pixel(96, 96, Rgb([200, 200, 200]));
        let mut mask = GrayImage::new(96, 96);
        for y in 20..76 {
            for x in 20..76 {
                if x == 20 || x == 75 || y == 20 || y == 75 {
                    source.put_pixel(x, y, Rgb([0, 0, 0]));
                    base.put_pixel(x, y, Rgb([0, 0, 0]));
                } else {
                    mask.put_pixel(x, y, Luma([180]));
                }
            }
        }
        let mut protected = GrayImage::new(96, 96);
        protected.put_pixel(40, 40, Luma([255]));
        let result = boundary_candidate(&source, &base, &mask, Some(&protected), [255, 228, 213]).unwrap();
        assert_eq!(result.evidence["requires_boundary_review"], false);
        assert_eq!(result.evidence["luminance_preserved"], true);
        assert!(super::super::fidelity::chroma(super::super::fidelity::lab(*result.image.get_pixel(21, 45), &super::super::fidelity::linear_table())) > 8.);
        assert_eq!(result.image.get_pixel(20, 45), base.get_pixel(20, 45));
        assert_eq!(result.image.get_pixel(40, 40), base.get_pixel(40, 40));
    }
    #[test]
    fn matching_surrounding_chroma_repairs_a_small_hole_to_the_edge() {
        let source = RgbImage::from_pixel(64, 64, Rgb([255, 255, 255]));
        let reference = super::super::detail::with_y(Rgb([255, 228, 213]), 180.);
        let mut base = RgbImage::from_pixel(64, 64, reference);
        let mut mask = GrayImage::new(64, 64);
        for y in 24..40 {
            for x in 24..40 {
                base.put_pixel(x, y, Rgb([180, 180, 180]));
                mask.put_pixel(x, y, Luma([180]));
            }
        }
        let result = boundary_candidate(&source, &base, &mask, None, [255, 228, 213]).unwrap();
        assert_eq!(result.evidence["requires_boundary_review"], false);
        assert!(result.evidence["palette_context_supported"].as_u64().unwrap() > 0);
        for (a, b) in result.image.get_pixel(24, 30).0.iter().zip(reference.0) {
            assert!(a.abs_diff(b) <= 3);
        }
        assert_eq!(result.image.get_pixel(23, 30), base.get_pixel(23, 30));
    }
    #[test]
    fn unsupported_rectangular_selection_is_not_automatic_authority() {
        let source = RgbImage::from_pixel(64, 64, Rgb([255, 255, 255]));
        let base = RgbImage::from_pixel(64, 64, Rgb([180, 180, 180]));
        let mut mask = GrayImage::new(64, 64);
        for y in 16..48 {
            for x in 16..48 {
                mask.put_pixel(x, y, Luma([255]));
            }
        }
        assert_eq!(boundary_candidate(&source, &base, &mask, None, [255, 228, 213]).unwrap().evidence["requires_boundary_review"], true);
    }
    #[test]
    fn preserves_existing_shading_and_exact_outside_and_protected_pixels() {
        let mut base = RgbImage::new(96, 96);
        for (x, _, p) in base.enumerate_pixels_mut() {
            let v = 140 + x as u8;
            *p = Rgb([v, v, v]);
        }
        let mut mask = GrayImage::new(96, 96);
        for y in 20..76 {
            for x in 20..76 {
                mask.put_pixel(x, y, Luma([if x == 20 || x == 75 || y == 20 || y == 75 { 180 } else { 255 }]));
            }
        }
        let mut protect = GrayImage::new(96, 96);
        protect.put_pixel(40, 40, Luma([255]));
        let output = candidate(&base, &mask, Some(&protect), [255, 228, 213]).unwrap();
        for (x, y, p) in output.enumerate_pixels() {
            if mask.get_pixel(x, y)[0] == 0 || protect.get_pixel(x, y)[0] > 0 {
                assert_eq!(*p, *base.get_pixel(x, y));
            }
            assert!((super::super::detail::y(*p) - super::super::detail::y(*base.get_pixel(x, y))).abs() < 1.1);
        }
        assert_ne!(output.get_pixel(50, 50), base.get_pixel(50, 50));
        assert!(candidate(&base, &GrayImage::new(1, 1), None, [255, 228, 213]).is_err());
    }
}
