//! Non-explicit CPU integration fixtures. These provide known chroma-loss
//! ground truth, not evidence of new diffusion or automatic semantic quality.
use super::{automatic, detail, fidelity};
use anyhow::{Result, ensure};
use image::{GrayImage, Luma, Rgb, RgbImage};
use imageproc::{
    drawing::{draw_filled_ellipse_mut, draw_hollow_ellipse_mut, draw_line_segment_mut, draw_polygon_mut},
    point::Point,
};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
struct Region {
    id: &'static str,
    category: &'static str,
    color: [u8; 3],
    mask: GrayImage,
    neutral: bool,
}
fn polygon(w: u32, h: u32, points: &[(i32, i32)]) -> GrayImage {
    let mut mask = GrayImage::new(w, h);
    draw_polygon_mut(&mut mask, &points.iter().map(|(x, y)| Point::new(*x, *y)).collect::<Vec<_>>(), Luma([255]));
    mask
}
fn ellipse(w: u32, h: u32, c: (i32, i32), r: (i32, i32)) -> GrayImage {
    let mut mask = GrayImage::new(w, h);
    draw_filled_ellipse_mut(&mut mask, c, r.0, r.1, Luma([255]));
    mask
}
fn paint(image: &mut RgbImage, mask: &GrayImage, color: [u8; 3], base: f64, pattern: bool) {
    for (x, y, p) in image.enumerate_pixels_mut() {
        if mask.get_pixel(x, y)[0] > 0 {
            let fold = 18. * (f64::from(y) * 0.12).sin() + 10. * (f64::from(x) * 0.06).cos();
            let texture = if pattern && (x + y) % 7 == 0 { -25. } else { 0. };
            *p = detail::with_y(Rgb(color), (base + fold + texture).clamp(45., 255.));
        }
    }
}
fn outline(image: &mut RgbImage, mask: &GrayImage) {
    let (w, h) = image.dimensions();
    for (x, y, p) in mask.enumerate_pixels() {
        if p[0] > 0
            && [(x.saturating_sub(1), y), ((x + 1).min(w - 1), y), (x, y.saturating_sub(1)), (x, (y + 1).min(h - 1))]
                .iter()
                .any(|(xx, yy)| mask.get_pixel(*xx, *yy)[0] == 0)
        {
            image.put_pixel(x, y, Rgb([0, 0, 0]));
        }
    }
}
fn glyphs(image: &mut RgbImage, x: u32, y: u32, text: &str) {
    for (i, c) in text.chars().enumerate() {
        let rows = match c {
            'C' => [14, 17, 16, 16, 16, 17, 14],
            'O' => [14, 17, 17, 17, 17, 17, 14],
            'L' => [16, 16, 16, 16, 16, 16, 31],
            'R' => [30, 17, 17, 30, 20, 18, 17],
            'T' => [31, 4, 4, 4, 4, 4, 4],
            'E' => [31, 16, 16, 30, 16, 16, 31],
            'S' => [15, 16, 16, 14, 1, 1, 30],
            _ => [0; 7],
        };
        for (yy, row) in rows.iter().enumerate() {
            for xx in 0..5 {
                if row & (1 << (4 - xx)) != 0 {
                    for sy in 0..2 {
                        for sx in 0..2 {
                            image.put_pixel(x + i as u32 * 12 + xx * 2 + sx, y + yy as u32 * 2 + sy, Rgb([0, 0, 0]));
                        }
                    }
                }
            }
        }
    }
}
fn run(source: &RgbImage, base: &RgbImage, reference: &RgbImage, regions: &[Region], protect: &GrayImage, dir: &Path) -> Result<Value> {
    fs::create_dir_all(dir)?;
    source.save(dir.join("source.png"))?;
    base.save(dir.join("before.png"))?;
    reference.save(dir.join("reference.png"))?;
    protect.save(dir.join("protect.png"))?;
    let mut annotations = Vec::new();
    for r in regions {
        let mask = dir.join(format!("{}.png", r.id));
        r.mask.save(&mask)?;
        annotations.push(json!({"id":r.id,"mask":mask,"category":r.category,"intent":if r.neutral{"neutral"}else{"color"},"color":format!("#{:02X}{:02X}{:02X}",r.color[0],r.color[1],r.color[2]),"palette_key":format!("fixture/{}",r.id),"confidence":1}));
    }
    let annotation = dir.join("regions.json");
    fs::write(&annotation, serde_json::to_vec_pretty(&json!({"version":1,"regions":annotations}))?)?;
    let report = automatic::run(automatic::Files {
        source: &dir.join("source.png"),
        colored: &dir.join("before.png"),
        raw: Some(&dir.join("before.png")),
        regions: Some(&annotation),
        profiles: None,
        protect: Some(&dir.join("protect.png")),
        output: &dir.join("pass-2"),
        apply: true,
        sensitivity: 1.,
        attempts: 8,
        debug: true,
    })?;
    let after = if let Some(path) = report["result"].as_str() { image::open(path)?.to_rgb8() } else { base.clone() };
    ensure!(after.dimensions() == source.dimensions(), "Fixture dimensions changed");
    let union = super::open_image(&dir.join("pass-2/unified-protection.png"))?.to_luma8();
    let (mut out, mut protected, mut y_error, mut count, mut before_error, mut after_error) = (0_u64, 0_u64, 0_f64, 0_u64, 0_f64, 0_f64);
    let lut = fidelity::linear_table();
    for (x, y, p) in after.enumerate_pixels() {
        let a = *base.get_pixel(x, y);
        let expected = *reference.get_pixel(x, y);
        let allowed = regions.iter().any(|r| !r.neutral && r.mask.get_pixel(x, y)[0] >= 128);
        if *p != a && !allowed {
            out += 1;
        }
        if *p != a && union.get_pixel(x, y)[0] > 0 {
            protected += 1;
        }
        if allowed && a != expected {
            let b = fidelity::lab(a, &lut);
            let c = fidelity::lab(*p, &lut);
            let e = fidelity::lab(expected, &lut);
            before_error += (b[1] - e[1]).hypot(b[2] - e[2]);
            after_error += (c[1] - e[1]).hypot(c[2] - e[2]);
            y_error = y_error.max((detail::y(a) - detail::y(*p)).abs());
            count += 1;
        }
    }
    ensure!(out == 0 && protected == 0, "Fixture mask/protection invariant failed");
    ensure!(image::open(dir.join("source.png"))?.to_rgb8() == *source && image::open(dir.join("before.png"))?.to_rgb8() == *base, "Fixture input changed");
    let mut montage = RgbImage::new(base.width() * 3, base.height());
    image::imageops::replace(&mut montage, base, 0, 0);
    image::imageops::replace(&mut montage, &after, i64::from(base.width()), 0);
    image::imageops::replace(&mut montage, reference, i64::from(base.width()) * 2, 0);
    montage.save(dir.join("comparison.png"))?;
    let metrics = json!({"outside_mask_changes":out,"protected_changes":protected,"max_luminance_change":y_error,"controlled_missing_pixels":count,"reference_ab_error_before":before_error/count.max(1) as f64,"reference_ab_error_after":after_error/count.max(1) as f64,"accepted":report["repairs_accepted"],"rejected":report["repairs_rejected"],"elapsed_seconds":report["elapsed_seconds"],"comparison_columns":["damaged existing output","accepted result","controlled reference"],"limitation":"Controlled chroma-loss validation, not a new diffusion-quality or semantic-recognition test"});
    fs::write(dir.join("metrics.json"), serde_json::to_vec_pretty(&metrics)?)?;
    Ok(metrics)
}
#[test]
fn complete_cpu_pipeline_on_clothed_synthetic_and_real_source_structures() -> Result<()> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.local-ai/repair-validation-037")
        .join(format!("native-{}", SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()));
    let (w, h) = (640, 900);
    let mut reference = RgbImage::from_pixel(w, h, Rgb([245, 242, 235]));
    let mut regions = vec![
        Region {
            id: "person-a-shirt",
            category: "clothing",
            color: [116, 139, 188],
            mask: polygon(w, h, &[(90, 200), (170, 200), (200, 290), (169, 320), (166, 430), (94, 430), (92, 320), (62, 290)]),
            neutral: false,
        },
        Region { id: "person-a-face", category: "skin", color: [255, 228, 213], mask: ellipse(w, h, (130, 143), (39, 51)), neutral: false },
        Region { id: "person-a-hair", category: "hair", color: [105, 68, 55], mask: ellipse(w, h, (130, 94), (53, 33)), neutral: false },
        Region {
            id: "person-a-trousers",
            category: "clothing",
            color: [48, 61, 85],
            mask: polygon(w, h, &[(95, 432), (165, 432), (178, 600), (143, 600), (130, 486), (118, 600), (82, 600)]),
            neutral: false,
        },
        Region {
            id: "person-b-white-shirt",
            category: "clothing",
            color: [255, 255, 255],
            mask: polygon(w, h, &[(385, 202), (455, 202), (478, 320), (368, 320)]),
            neutral: true,
        },
        Region {
            id: "person-b-gray-trousers",
            category: "clothing",
            color: [128, 128, 128],
            mask: polygon(w, h, &[(385, 323), (455, 323), (465, 520), (430, 520), (420, 380), (410, 520), (375, 520)]),
            neutral: true,
        },
        Region { id: "person-b-black-hair", category: "hair", color: [8, 8, 8], mask: ellipse(w, h, (420, 107), (51, 35)), neutral: true },
    ];
    for y in 0..h {
        for x in 0..w {
            if regions[2].mask.get_pixel(x, y)[0] > 0 {
                regions[1].mask.put_pixel(x, y, Luma([0]));
            }
        }
    }
    let second_face = ellipse(w, h, (420, 157), (38, 45));
    paint(&mut reference, &second_face, [226, 190, 158], 205., false);
    outline(&mut reference, &second_face);
    for r in &regions {
        let y = match r.id {
            "person-a-face" => 223.,
            "person-a-hair" => 115.,
            "person-a-trousers" => 100.,
            "person-b-white-shirt" => 237.,
            "person-b-gray-trousers" => 140.,
            "person-b-black-hair" => 32.,
            _ => 165.,
        };
        paint(&mut reference, &r.mask, r.color, y, r.category == "clothing");
        outline(&mut reference, &r.mask);
    }
    // Closed eyelids, strands, fabric folds and fine neutral screentone marks.
    for (x1, y1, x2, y2) in [
        (105., 143., 118., 147.),
        (118., 147., 124., 142.),
        (140., 143., 152., 147.),
        (152., 147., 158., 142.),
        (118., 167., 143., 168.),
        (115., 220., 132., 400.),
        (145., 230., 153., 390.),
        (105., 80., 113., 115.),
        (123., 75., 133., 110.),
    ] {
        draw_line_segment_mut(&mut reference, (x1, y1), (x2, y2), Rgb([0, 0, 0]));
    }
    for y in (320..408).step_by(4) {
        for x in (103..155).step_by(4) {
            reference.put_pixel(x, y, Rgb([35, 35, 35]));
        }
    }
    // White sclera and teeth remain outside all repair masks.
    for c in [(405, 153), (435, 153), (420, 177)] {
        draw_filled_ellipse_mut(&mut reference, c, 8, 4, Rgb([255, 255, 255]));
    }
    let mut protect = ellipse(w, h, (510, 65), (108, 36));
    draw_filled_ellipse_mut(&mut reference, (510, 65), 108, 36, Rgb([255, 255, 255]));
    draw_hollow_ellipse_mut(&mut reference, (510, 65), 108, 36, Rgb([0, 0, 0]));
    glyphs(&mut reference, 467, 58, "COLOR");
    for (a, b) in [((510., 600.), (530., 580.)), ((520., 580.), (535., 610.)), ((540., 580.), (545., 610.))] {
        draw_line_segment_mut(&mut reference, a, b, Rgb([0, 0, 0]));
    }
    for y in 575..615 {
        for x in 500..550 {
            protect.put_pixel(x, y, Luma([255]));
        }
    }
    for y in [8., 630., 645., 890.] {
        draw_line_segment_mut(&mut reference, (8., y), (632., y), Rgb([0, 0, 0]));
    }
    glyphs(&mut reference, 30, 660, "TEST");
    for y in 650..685 {
        for x in 20..90 {
            protect.put_pixel(x, y, Luma([255]));
        }
    }
    let source = RgbImage::from_fn(w, h, |x, y| {
        let v = detail::y(*reference.get_pixel(x, y)).round() as u8;
        Rgb([v, v, v])
    });
    let mut damaged = reference.clone();
    for (x, y, p) in damaged.enumerate_pixels_mut() {
        let missing = regions.iter().take(4).enumerate().any(|(i, r)| {
            r.mask.get_pixel(x, y)[0] > 0
                && (i == 0 || i == 2 || (i == 1 && x > 110 && x < 148 && y > 130 && y < 164) || (i == 3 && x > 100 && x < 150 && y > 445 && y < 490))
        });
        if missing {
            let v = detail::y(*p).round() as u8;
            *p = Rgb([v, v, v]);
        }
    }
    let synthetic = run(&source, &damaged, &reference, &regions, &protect, &root.join("clothed-synthetic"))?;
    ensure!(synthetic["accepted"].as_u64().unwrap_or(0) >= 3, "Too few verified fixture repairs: {synthetic}");
    ensure!(synthetic["reference_ab_error_after"].as_f64() < synthetic["reference_ab_error_before"].as_f64(), "No measured fixture chroma improvement");
    ensure!(synthetic["max_luminance_change"].as_f64().unwrap_or(10.) <= 1.1, "Fixture shading flattened");
    // Existing fully clothed source artwork, with a deliberately constructed
    // color reference for one jacket area. This is not an AI output benchmark.
    let preview = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.local-ai/repair-validation-037/clothed-source-preview.png");
    if preview.exists() {
        let src = super::open_image(&preview)?.to_rgb8();
        let (w, h) = src.dimensions();
        let mut expected = src.clone();
        let mask = polygon(w, h, &[(43, 384), (118, 377), (147, 434), (135, 531), (43, 537), (25, 480)]);
        for (x, y, p) in expected.enumerate_pixels_mut() {
            if mask.get_pixel(x, y)[0] > 0 {
                *p = detail::with_y(Rgb([48, 61, 85]), detail::y(*src.get_pixel(x, y)));
            }
        }
        let mut before = expected.clone();
        for (x, y, p) in before.enumerate_pixels_mut() {
            if (i64::from(x) - 78).pow(2) + (i64::from(y) - 465).pow(2) < 24 * 24 {
                let v = detail::y(*p).round() as u8;
                *p = Rgb([v, v, v]);
            }
        }
        let r = Region { id: "real-source-jacket", category: "clothing", color: [48, 61, 85], mask, neutral: false };
        let real = run(&src, &before, &expected, &[r], &GrayImage::new(w, h), &root.join("real-clothed-source-controlled"))?;
        ensure!(
            real["accepted"] == 1 && real["reference_ab_error_after"].as_f64() < real["reference_ab_error_before"].as_f64(),
            "Real-source controlled repair not accepted: {real}"
        );
    }
    // Deliberately unsupported mask boundary: the export must remain unchanged.
    regions.truncate(1);
    regions[0].mask = polygon(128, 128, &[(32, 32), (95, 32), (95, 95), (32, 95)]);
    let gray = RgbImage::from_pixel(128, 128, Rgb([180, 180, 180]));
    let blank = RgbImage::from_pixel(128, 128, Rgb([255, 255, 255]));
    let rejected = run(&blank, &gray, &gray, &regions, &GrayImage::new(128, 128), &root.join("unsupported-boundary"))?;
    ensure!(rejected["accepted"] == 0 && rejected["rejected"] == 1, "Unsupported boundary was silently accepted");
    println!("CPU integration evidence: {}", root.display());
    Ok(())
}
