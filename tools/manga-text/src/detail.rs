//! Explicitly selected source-guided geometry/texture correction. No detection or ML.
use anyhow::{Result, ensure};
use image::{GrayImage, Rgb, RgbImage};
use serde_json::{Value, json};
use std::{fs, path::Path};
pub(super) fn y(p: Rgb<u8>) -> f64 {
    0.2126 * f64::from(p[0]) + 0.7152 * f64::from(p[1]) + 0.0722 * f64::from(p[2])
}
pub(super) fn with_y(p: Rgb<u8>, target: f64) -> Rgb<u8> {
    let old = y(p);
    let mut scale = 1.0_f64;
    for value in p.0 {
        let delta = f64::from(value) - old;
        if delta > 0. {
            scale = scale.min((255. - target) / delta);
        } else if delta < 0. {
            scale = scale.min(-target / delta);
        }
    }
    let scale = scale.clamp(0., 1.);
    Rgb(p.0.map(|v| (target + (f64::from(v) - old) * scale).round().clamp(0., 255.) as u8))
}
pub fn correct(source: &RgbImage, base: &RgbImage, mask: &GrayImage, protect: Option<&GrayImage>, mode: &str, strength: f64) -> Result<RgbImage> {
    ensure!(matches!(mode, "geometry" | "texture"), "Use geometry or texture mode");
    ensure!(strength.is_finite() && (0.0..=1.0).contains(&strength), "Detail strength must be 0..1");
    ensure!(
        source.dimensions() == base.dimensions() && source.dimensions() == mask.dimensions() && protect.is_none_or(|m| m.dimensions() == source.dimensions()),
        "Detail dimensions differ"
    );
    let blurred = if mode == "texture" { Some(image::imageops::blur(&image::DynamicImage::ImageRgb8(source.clone()).to_luma8(), 1.2)) } else { None };
    let generated_blur = if mode == "texture" { Some(image::imageops::blur(&image::DynamicImage::ImageRgb8(base.clone()).to_luma8(), 1.2)) } else { None };
    let mut output = base.clone();
    for (x, yy, p) in output.enumerate_pixels_mut() {
        let alpha = f64::from(mask.get_pixel(x, yy)[0]) / 255. * strength;
        if alpha == 0. || protect.is_some_and(|m| m.get_pixel(x, yy)[0] > 0) {
            continue;
        }
        let original = y(*source.get_pixel(x, yy));
        let current = y(*p);
        let target = if let (Some(blur), Some(generated)) = (&blurred, &generated_blur) {
            let source_detail = original - f64::from(blur.get_pixel(x, yy)[0]);
            let existing_detail = current - f64::from(generated.get_pixel(x, yy)[0]);
            (current + (source_detail - existing_detail).clamp(-24., 24.)).clamp(0., 255.)
        } else {
            original
        };
        *p = with_y(*p, current + (target - current) * alpha);
    }
    Ok(output)
}
pub fn metrics(source: &RgbImage, image: &RgbImage, mask: &GrayImage, protect: Option<&GrayImage>) -> Result<Value> {
    ensure!(
        source.dimensions() == image.dimensions() && source.dimensions() == mask.dimensions() && protect.is_none_or(|m| m.dimensions() == source.dimensions()),
        "Detail metric dimensions differ"
    );
    let (mut error, mut edges, mut n) = (0., 0., 0_u64);
    for (x, yy, p) in source.enumerate_pixels() {
        if mask.get_pixel(x, yy)[0] < 128 || protect.is_some_and(|m| m.get_pixel(x, yy)[0] > 0) {
            continue;
        }
        let a = y(*p);
        let b = y(*image.get_pixel(x, yy));
        error += (a - b).abs();
        n += 1;
        for (nx, ny) in [(x.checked_add(1), Some(yy)), (Some(x), yy.checked_add(1))] {
            if let (Some(nx), Some(ny)) = (nx, ny)
                && let (Some(s), Some(c), Some(m)) = (source.get_pixel_checked(nx, ny), image.get_pixel_checked(nx, ny), mask.get_pixel_checked(nx, ny))
                && m[0] >= 128
                && !protect.is_some_and(|p| p.get_pixel(nx, ny)[0] > 0)
            {
                edges += ((a - y(*s)) - (b - y(*c))).abs();
            }
        }
    }
    Ok(
        json!({"pixels":n,"mean_source_luminance_error":if n>0{Some(error/n as f64)}else{None},"mean_source_gradient_error":if n>0{Some(edges/n as f64)}else{None},"semantic_eye_state_verified":false}),
    )
}
pub struct Files<'a> {
    pub source: &'a Path,
    pub base: &'a Path,
    pub mask: &'a Path,
    pub protect: Option<&'a Path>,
    pub mode: &'a str,
    pub strength: f64,
    pub directory: &'a Path,
}
pub fn run(files: Files<'_>) -> Result<Value> {
    ensure!(!files.directory.exists(), "Use a fresh detail directory");
    let source = super::open_image(files.source)?.to_rgb8();
    let base = super::open_image(files.base)?.to_rgb8();
    let mask = super::open_image(files.mask)?.to_luma8();
    let protect = files.protect.map(|p| super::open_image(p).map(|v| v.to_luma8())).transpose()?;
    let candidate = correct(&source, &base, &mask, protect.as_ref(), files.mode, files.strength)?;
    let before = metrics(&source, &base, &mask, protect.as_ref())?;
    let after = metrics(&source, &candidate, &mask, protect.as_ref())?;
    let (mut outside, mut protected) = (0_u64, 0_u64);
    for (x, y, p) in base.enumerate_pixels() {
        if *p != *candidate.get_pixel(x, y) {
            if mask.get_pixel(x, y)[0] == 0 {
                outside += 1;
            }
            if protect.as_ref().is_some_and(|m| m.get_pixel(x, y)[0] > 0) {
                protected += 1;
            }
        }
    }
    let improved = after["mean_source_gradient_error"].as_f64().zip(before["mean_source_gradient_error"].as_f64()).is_some_and(|(a, b)| a + 0.1 < b);
    let accepted = outside == 0 && protected == 0 && improved;
    fs::create_dir_all(files.directory)?;
    candidate.save(files.directory.join("candidate.png"))?;
    if accepted {
        candidate.save(files.directory.join("corrected.png"))?;
    }
    source.save(files.directory.join("source.png"))?;
    mask.save(files.directory.join("selection.png"))?;
    let report = json!({"version":1,"mode":files.mode,"strength":files.strength,"accepted":accepted,"changed_outside_mask":outside,"changed_protected_pixels":protected,"before":before,"after":after,"requires_visual_review":true,"semantic_geometry_verified":false,"reason":if accepted{"Source-gradient agreement improved inside approved mask"}else{"No measured source-gradient improvement; current image retained"},"limitations":"Geometry mode uses source luminance and generated chroma with gamut compression. White source areas can become white; restrict eye masks carefully. Texture mode restores local source contrast, not semantic eye state, and can retain invented model detail."});
    fs::write(files.directory.join("detail-report.json"), serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}
#[cfg(test)]
mod tests {
    use super::*;
    use image::Luma;
    #[test]
    fn geometry_removes_invented_opening_and_preserves_narrow_source_slit() {
        let mut s = RgbImage::from_pixel(32, 32, Rgb([255, 255, 255]));
        let mut b = RgbImage::from_pixel(32, 32, Rgb([238, 195, 162]));
        let mut m = GrayImage::new(32, 32);
        for yy in 10..20 {
            for x in 8..24 {
                m.put_pixel(x, yy, Luma([255]));
                b.put_pixel(x, yy, Rgb([40, 80, 200]));
            }
        }
        for x in 9..23 {
            s.put_pixel(x, 14, Rgb([0, 0, 0]));
        }
        s.put_pixel(15, 15, Rgb([80, 80, 80]));
        let c = correct(&s, &b, &m, None, "geometry", 1.).unwrap();
        assert_eq!(c.get_pixel(15, 13).0, [255, 255, 255]);
        assert_eq!(c.get_pixel(15, 14).0, [0, 0, 0]);
        assert!((y(*c.get_pixel(15, 15)) - 80.).abs() < 1.);
        for (x, yy, p) in b.enumerate_pixels() {
            if m.get_pixel(x, yy)[0] == 0 {
                assert_eq!(p, c.get_pixel(x, yy));
            }
        }
        assert!(metrics(&s, &c, &m, None).unwrap()["mean_source_gradient_error"].as_f64().unwrap() < 1.);
    }
    #[test]
    fn source_texture_is_recovered_without_grayscale_replacement() {
        let s = RgbImage::from_fn(32, 32, |x, y| if (x + y) % 2 == 0 { Rgb([110, 110, 110]) } else { Rgb([240, 240, 240]) });
        let b = RgbImage::from_pixel(32, 32, Rgb([200, 140, 100]));
        let m = GrayImage::from_pixel(32, 32, Luma([255]));
        let c = correct(&s, &b, &m, None, "texture", 1.).unwrap();
        assert_ne!(c.get_pixel(10, 10), c.get_pixel(11, 10));
        assert!(c.get_pixel(10, 10)[0] > c.get_pixel(10, 10)[2]);
        let before = metrics(&s, &b, &m, None).unwrap();
        let after = metrics(&s, &c, &m, None).unwrap();
        assert!(after["mean_source_gradient_error"].as_f64() < before["mean_source_gradient_error"].as_f64());
        assert_eq!(correct(&s, &b, &m, Some(&m), "texture", 1.).unwrap(), b);
        assert!(correct(&s, &b, &m, None, "texture", f64::NAN).is_err());
    }
}
