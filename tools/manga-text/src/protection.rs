//! CPU union of cached text/bubble masks and uninterrupted blank page margins.
use anyhow::Result;
use image::{GrayImage, Luma, RgbImage};
use std::path::{Path, PathBuf};
pub fn unified(source: &RgbImage, source_path: &Path, explicit: Option<&Path>) -> Result<GrayImage> {
    let (w, h) = source.dimensions();
    let mut union = GrayImage::new(w, h);
    let mut paths: Vec<PathBuf> = Vec::new();
    if let Some(path) = explicit {
        paths.push(path.to_owned());
        if let Some(parent) = path.parent() {
            for name in ["bubble-protect-mask.png", "original.protect-mask.png", "removal-mask.png"] {
                let sibling = parent.join(name);
                if sibling.exists() && !paths.contains(&sibling) {
                    paths.push(sibling);
                }
            }
        }
    }
    if let (Some(parent), Some(stem)) = (source_path.parent(), source_path.file_stem()) {
        for suffix in [".protect-mask.png", ".text-mask.png"] {
            let path = parent.join(format!("{}{suffix}", stem.to_string_lossy()));
            if path.exists() && !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    for path in paths {
        let mask = super::fidelity::mask(&path, (w, h))?;
        for (x, y, p) in mask.enumerate_pixels() {
            if p[0] > 0 {
                union.put_pixel(x, y, Luma([255]));
            }
        }
    }
    let radius = w.max(h).div_ceil(1600).clamp(1, 8);
    let original = union.clone();
    let mut horizontal = GrayImage::new(w, h);
    for (x, y, p) in horizontal.enumerate_pixels_mut() {
        if (x.saturating_sub(radius)..=x.saturating_add(radius).min(w - 1)).any(|xx| original.get_pixel(xx, y)[0] > 0) {
            p[0] = 255;
        }
    }
    for (x, y, p) in union.enumerate_pixels_mut() {
        if (y.saturating_sub(radius)..=y.saturating_add(radius).min(h - 1)).any(|yy| horizontal.get_pixel(x, yy)[0] > 0) {
            p[0] = 255;
        }
    }
    // Only uninterrupted blank edge bands count as known paper margins.
    let white = |p: &image::Rgb<u8>| p.0.iter().all(|v| *v >= 250);
    for reverse in [false, true] {
        for offset in 0..h / 8 {
            let y = if reverse { h - 1 - offset } else { offset };
            if !(0..w).all(|x| white(source.get_pixel(x, y))) {
                break;
            }
            for x in 0..w {
                union.put_pixel(x, y, Luma([255]));
            }
        }
        for offset in 0..w / 8 {
            let x = if reverse { w - 1 - offset } else { offset };
            if !(0..h).all(|y| white(source.get_pixel(x, y))) {
                break;
            }
            for y in 0..h {
                union.put_pixel(x, y, Luma([255]));
            }
        }
    }
    Ok(union)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn margins_do_not_protect_internal_white_regions() {
        let mut source = RgbImage::from_pixel(137, 193, image::Rgb([255, 255, 255]));
        for y in 12..181 {
            for x in 10..127 {
                source.put_pixel(x, y, image::Rgb([200, 200, 200]));
            }
        }
        source.put_pixel(60, 60, image::Rgb([255, 255, 255]));
        let mask = unified(&source, Path::new("absent-source.png"), None).unwrap();
        assert_eq!(mask.dimensions(), source.dimensions());
        assert_eq!(mask.get_pixel(0, 0)[0], 255);
        assert_eq!(mask.get_pixel(60, 60)[0], 0);
    }
    #[test]
    fn antialiased_mask_edges_are_expanded_and_bad_dimensions_fail() {
        let dir = std::env::temp_dir().join(format!("manga-protect-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("text.png");
        let source = RgbImage::from_pixel(64, 64, image::Rgb([200, 200, 200]));
        let mut text = GrayImage::new(64, 64);
        text.put_pixel(30, 30, Luma([1]));
        text.save(&path).unwrap();
        let mask = unified(&source, &dir.join("source.png"), Some(&path)).unwrap();
        assert_eq!(mask.get_pixel(29, 29)[0], 255);
        assert_eq!(mask.get_pixel(28, 28)[0], 0);
        GrayImage::new(12, 12).save(&path).unwrap();
        assert!(unified(&source, &dir.join("source.png"), Some(&path)).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
