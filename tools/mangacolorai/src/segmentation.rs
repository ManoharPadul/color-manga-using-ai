//! CPU source-boundary selection assistance. A seed supplies location, never semantics.
use image::{GrayImage, Luma};
use std::collections::VecDeque;

pub fn grow(source: &GrayImage, seed: (u32, u32)) -> Result<GrayImage, String> {
    let (w, h) = source.dimensions();
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > 120_000_000 || seed.0 >= w || seed.1 >= h {
        return Err("Invalid source dimensions or seed.".into());
    }
    let (dw, dh) = super::coordinates::fit(w, h, 1024);
    let small = image::imageops::thumbnail(source, dw, dh);
    let (sw, sh) = small.dimensions();
    let sx = (u64::from(seed.0) * u64::from(sw) / u64::from(w)) as u32;
    let sy = (u64::from(seed.1) * u64::from(sh) / u64::from(h)) as u32;
    let tone = small.get_pixel(sx, sy)[0];
    if tone < 85 {
        return Err("Select inside a region rather than on black ink.".into());
    }
    let mut mask = GrayImage::new(sw, sh);
    let mut queue = VecDeque::from([(sx, sy)]);
    mask.put_pixel(sx, sy, Luma([255]));
    let cap = (u64::from(sw) * u64::from(sh) / 5).max(64);
    let mut count = 0_u64;
    while let Some((x, y)) = queue.pop_front() {
        count += 1;
        if count > cap || x == 0 || y == 0 || x + 1 == sw || y + 1 == sh {
            return Err("Selection reaches an open boundary or is too large. Use the brush to define this region.".into());
        }
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
            let value = small.get_pixel(nx, ny)[0];
            if mask.get_pixel(nx, ny)[0] == 0 && value >= 85 && value.abs_diff(tone) <= 35 && value.abs_diff(small.get_pixel(x, y)[0]) <= 24 {
                mask.put_pixel(nx, ny, Luma([255]));
                queue.push_back((nx, ny));
            }
        }
    }
    let mut full = image::imageops::resize(&mask, w, h, image::imageops::FilterType::Nearest);
    for (x, y, p) in full.enumerate_pixels_mut() {
        if source.get_pixel(x, y)[0] < 85 {
            p[0] = 0;
        }
    }
    Ok(full)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_ink_encloses_selection_and_output_keeps_dimensions() {
        let mut source = GrayImage::from_pixel(137, 193, Luma([255]));
        for y in 40..80 {
            for x in 30..70 {
                source.put_pixel(x, y, Luma([if x == 30 || x == 69 || y == 40 || y == 79 { 0 } else { 200 }]));
            }
        }
        let mask = grow(&source, (50, 60)).unwrap();
        assert_eq!(mask.dimensions(), source.dimensions());
        assert_eq!(mask.get_pixel(50, 60)[0], 255);
        assert_eq!(mask.get_pixel(30, 60)[0], 0);
        assert_eq!(mask.get_pixel(100, 100)[0], 0);
    }
    #[test]
    fn open_page_ink_and_bad_seeds_are_rejected() {
        assert!(grow(&GrayImage::from_pixel(100, 100, Luma([255])), (50, 50)).is_err());
        assert!(grow(&GrayImage::from_pixel(100, 100, Luma([0])), (50, 50)).is_err());
        assert!(grow(&GrayImage::new(10, 10), (10, 10)).is_err());
    }
}
