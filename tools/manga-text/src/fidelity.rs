//! CPU-only diagnostics and explicitly masked palette corrections at the normalized RGB boundary.
use anyhow::{Context, Result, ensure};
use image::{GrayImage, Luma, Rgb, RgbImage};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs,
    path::{Path, PathBuf},
};

#[derive(Deserialize, Serialize, Clone)]
pub struct Region {
    pub id: String,
    pub mask: PathBuf,
    #[serde(default)]
    pub category: String,
    #[serde(default = "color_intent")]
    pub intent: String,
    #[serde(default, alias = "expected_color")]
    pub color: Option<String>,
    #[serde(default)]
    pub palette_key: Option<String>,
    #[serde(default = "manual_confidence")]
    pub confidence: f64,
}
fn color_intent() -> String {
    "color".into()
}
fn manual_confidence() -> f64 {
    1.
}
#[derive(Deserialize, Serialize)]
struct Annotations {
    version: u32,
    regions: Vec<Region>,
}
pub struct QualityFiles<'a> {
    pub source: &'a Path,
    pub raw: Option<&'a Path>,
    pub final_image: &'a Path,
    pub annotations: Option<&'a Path>,
    pub stages: Option<&'a Path>,
    pub protect: Option<&'a Path>,
    pub directory: &'a Path,
}
pub fn hex(value: &str) -> Result<[u8; 3]> {
    ensure!(value.len() == 7 && value.starts_with('#') && value.as_bytes().iter().skip(1).all(u8::is_ascii_hexdigit), "Use a six-digit hex color #RRGGBB");
    let mut rgb = [0; 3];
    for (i, c) in rgb.iter_mut().enumerate() {
        *c = u8::from_str_radix(value.get(1 + i * 2..3 + i * 2).context("Invalid color")?, 16)?;
    }
    Ok(rgb)
}
pub(super) fn luma(p: Rgb<u8>) -> u8 {
    ((u32::from(p.0[0]) * 54 + u32::from(p.0[1]) * 183 + u32::from(p.0[2]) * 19) / 256) as u8
}
pub(super) fn linear_table() -> [f64; 256] {
    std::array::from_fn(|i| {
        let v = i as f64 / 255.;
        if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
    })
}
// Same normalized sRGB/D65 Lab boundary as the existing coverage analyzer.
pub(super) fn lab(p: Rgb<u8>, lut: &[f64; 256]) -> [f64; 3] {
    let channel = |i: usize| p.0.get(i).and_then(|v| lut.get(usize::from(*v))).copied().unwrap_or(0.);
    let (r, g, b) = (channel(0), channel(1), channel(2));
    let f = |v: f64| if v > 0.008856451679 { v.cbrt() } else { 7.787037037 * v + 16. / 116. };
    let x = f((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047);
    let y = f(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
    let z = f((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883);
    [116. * y - 16., 500. * (x - y), 200. * (y - z)]
}
pub(super) fn chroma(l: [f64; 3]) -> f64 {
    l[1].hypot(l[2])
}
fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    (a[1] - b[1]).hypot(a[2] - b[2])
}
fn palette_distance(value: [f64; 3], target: [f64; 3]) -> f64 {
    if chroma(target) < 8. { distance(value, target).hypot(value[0] - target[0]) } else { distance(value, target) }
}
pub(super) fn mask(path: &Path, dimensions: (u32, u32)) -> Result<GrayImage> {
    let image = super::open_image(path)?.to_luma8();
    ensure!(image.dimensions() == dimensions, "Mask must match original image dimensions: {}", path.display());
    Ok(image)
}
fn validate(regions: &[Region]) -> Result<()> {
    ensure!(regions.len() <= 32, "Use at most 32 explicit regions");
    let mut ids = HashSet::new();
    for r in regions {
        ensure!(!r.id.is_empty() && r.id.len() <= 80 && ids.insert(&r.id), "Region IDs must be nonempty and unique");
        ensure!(matches!(r.intent.as_str(), "color" | "neutral" | "exclude" | "closed_detail"), "Unknown region intent");
        ensure!(r.confidence.is_finite() && (0.0..=1.0).contains(&r.confidence), "Region confidence must be 0..1");
        if let Some(color) = &r.color {
            hex(color)?;
        }
        ensure!(r.palette_key.as_ref().is_none_or(|v| v.len() <= 256), "Palette key too long");
    }
    Ok(())
}
pub(super) fn load_regions(path: Option<&Path>) -> Result<Vec<Region>> {
    let Some(path) = path else { return Ok(Vec::new()) };
    ensure!(fs::metadata(path)?.len() <= 128000, "Region file exceeds 128KB");
    let mut doc: Annotations = super::read_json(path)?;
    ensure!(doc.version == 1, "Use region schema version 1");
    validate(&doc.regions)?;
    let parent = path.parent().context("Region file has no parent")?;
    for region in &mut doc.regions {
        if !region.mask.is_absolute() {
            region.mask = parent.join(&region.mask);
        }
    }
    Ok(doc.regions)
}
fn allocate<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values.try_reserve_exact(length).context("Insufficient memory for coverage masks")?;
    values.resize(length, value);
    Ok(values)
}
fn components(causes: &GrayImage) -> Vec<Value> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    // Component extraction runs on a bounded diagnostic grid; region counts below remain full resolution.
    for (x, y, p) in causes.enumerate_pixels() {
        let index = u64::from(y) * u64::from(causes.width()) + u64::from(x);
        if p.0[0] == 0 || !seen.insert(index) {
            continue;
        }
        let cause = p.0[0];
        let mut q = VecDeque::from([(x, y)]);
        let (mut left, mut top, mut right, mut bottom, mut count) = (x, y, x, y, 0_u64);
        while let Some((x, y)) = q.pop_front() {
            count += 1;
            left = left.min(x);
            top = top.min(y);
            right = right.max(x);
            bottom = bottom.max(y);
            let neighbors = [
                x.checked_sub(1).map(|xx| (xx, y)),
                x.checked_add(1).filter(|xx| *xx < causes.width()).map(|xx| (xx, y)),
                y.checked_sub(1).map(|yy| (x, yy)),
                y.checked_add(1).filter(|yy| *yy < causes.height()).map(|yy| (x, yy)),
            ];
            for (xx, yy) in neighbors.into_iter().flatten() {
                if causes.get_pixel_checked(xx, yy).is_some_and(|p| p.0[0] == cause) && seen.insert(u64::from(yy) * u64::from(causes.width()) + u64::from(xx)) {
                    q.push_back((xx, yy));
                }
            }
        }
        if result.len() < 256 {
            result.push(json!({"cause":cause_name(cause),"diagnostic_samples":count,"grid_bounds":[left,top,right-left+1,bottom-top+1],"confidence":if cause==1 {0.25}else{0.9},"automatic_repair_authorized":false}));
        }
    }
    result
}
fn cause_name(c: u8) -> &'static str {
    match c {
        2 => "model_left_declared_region_neutral",
        3 => "postprocessing_color_loss",
        4 => "protection_conflict",
        5 => "palette_mismatch",
        6 => "source_detail_color_residue",
        _ => "uncertain_unannotated_neutral",
    }
}

pub fn quality(files: QualityFiles<'_>) -> Result<Value> {
    ensure!(!files.directory.exists(), "Choose a fresh quality-report directory");
    let source = super::open_image(files.source)?.to_rgb8();
    let final_image = super::open_image(files.final_image)?.to_rgb8();
    let raw = files.raw.map(|p| super::open_image(p).map(|v| v.to_rgb8())).transpose()?;
    ensure!(
        source.dimensions() == final_image.dimensions() && raw.as_ref().is_none_or(|r| r.dimensions() == source.dimensions()),
        "Source, raw and final dimensions must match"
    );
    let regions = load_regions(files.annotations)?;
    let protect = files.protect.map(|p| mask(p, source.dimensions())).transpose()?;
    let mut report = analyze(&source, raw.as_ref(), &final_image, &regions, protect.as_ref())?;
    fs::create_dir_all(files.directory)?;
    let mut preview = RgbImage::from_pixel(256, (regions.len() as u32).max(1) * 24, Rgb([255, 255, 255]));
    let mut entries = Vec::new();
    for (i, region) in regions.iter().enumerate() {
        let name = format!("region-{:02}.png", i + 1);
        mask(&region.mask, source.dimensions())?.save(files.directory.join(&name))?;
        if let Some(color) = &region.color {
            let color = Rgb(hex(color)?);
            for y in (i as u32) * 24..(i as u32 + 1) * 24 {
                for x in 0..256 {
                    preview.put_pixel(x, y, color);
                }
            }
        }
        entries.push(json!({"id":region.id,"mask":name,"palette_row":i,"color":region.color}));
    }
    preview.save(files.directory.join("palette-preview.png"))?;
    if let Some(path) = files.stages {
        ensure!(fs::metadata(path)?.len() <= 128000, "Stage manifest exceeds 128KB");
        let doc: Value = super::read_json(path)?;
        let stages = doc["stages"].as_array().ok_or_else(|| anyhow::anyhow!("Missing stages array"))?;
        ensure!(stages.len() <= 8, "Use at most eight diagnostic stages");
        let mut observations = Vec::new();
        for stage in stages {
            let name = stage["name"].as_str().filter(|s| s.len() <= 80).ok_or_else(|| anyhow::anyhow!("Invalid stage name"))?;
            let path = Path::new(stage["path"].as_str().ok_or_else(|| anyhow::anyhow!("Missing stage path"))?);
            let image = super::open_image(path)?.to_rgb8();
            let (measured, _) = analyze(&source, raw.as_ref(), &image, &regions, protect.as_ref())?;
            observations.push(json!({"name":name,"path":path,"report":measured}));
        }
        report.0["stage_observations"] = json!(observations);
    }
    report.0["heatmap_legend"] = json!({"gray":"uncertain unannotated neutral","orange":"missing declared color","magenta":"postprocessing loss","red":"protection conflict","yellow":"palette mismatch","cyan":"source-detail residue"});
    report.0["diagnostics"] = json!({"source":files.source,"raw":files.raw,"final":files.final_image,"regions":entries,"heatmap":"missing-color-heatmap.png","palette_preview":"palette-preview.png"});
    fs::write(files.directory.join("quality.json"), serde_json::to_vec_pretty(&report.0)?)?;
    report.1.save(files.directory.join("missing-color-heatmap.png"))?;
    Ok(report.0)
}

pub fn analyze(
    source: &RgbImage,
    raw: Option<&RgbImage>,
    final_image: &RgbImage,
    regions: &[Region],
    protect: Option<&GrayImage>,
) -> Result<(Value, RgbImage)> {
    validate(regions)?;
    ensure!(
        source.dimensions() == final_image.dimensions()
            && raw.is_none_or(|r| r.dimensions() == source.dimensions())
            && protect.is_none_or(|m| m.dimensions() == source.dimensions()),
        "Analysis dimensions differ"
    );
    let (width, height) = source.dimensions();
    let n = usize::try_from(u64::from(width) * u64::from(height))?;
    ensure!(width > 0 && height > 0 && n <= 120_000_000, "Analysis exceeds 120MP");
    ensure!(n.saturating_mul(regions.len()) <= 256_000_000, "Too many full-resolution region masks; analyze smaller groups");
    let masks: Vec<_> = regions.iter().map(|r| mask(&r.mask, source.dimensions())).collect::<Result<_>>()?;
    let mut owners = if regions.is_empty() { Vec::new() } else { allocate(n, 0_u8)? };
    let mut excluded = if regions.is_empty() { Vec::new() } else { allocate(n, false)? };
    let mut overlap = 0_u64;
    for (i, (r, m)) in regions.iter().zip(&masks).enumerate() {
        for (index, p) in m.pixels().enumerate() {
            if p.0[0] <= 127 {
                continue;
            }
            if matches!(r.intent.as_str(), "neutral" | "exclude") || matches!(r.category.as_str(), "text" | "intentional_uncolored") {
                if let Some(v) = excluded.get_mut(index) {
                    *v = true;
                }
            } else if let Some(v) = owners.get_mut(index) {
                if *v != 0 {
                    if usize::from(*v).checked_sub(1).and_then(|index| regions.get(index)).is_some_and(|old| super::automatic::same_assignment(r, old)) {
                        continue;
                    }
                    if *v != 255 {
                        overlap += 1;
                    }
                    *v = 255;
                } else {
                    *v = (i + 1) as u8;
                }
            }
        }
    }
    let lut = linear_table();
    let (dw, dh) = super::coordinates::fit(width, height, 1024);
    let grid = image::imageops::thumbnail(source, dw, dh);
    let mut causes = GrayImage::new(grid.width(), grid.height());
    let mut heat = grid;
    let (mut eligible, mut missing, mut conflicts, mut lost, mut mismatches, mut source_ink, mut ink_kept) = (0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
    // Sparse, unannotated neutral areas remain review-only. Never manufacture an eligibility percentage.
    let mut sampled_new_dark = 0_u64;
    for y in 0..causes.height() {
        for x in 0..causes.width() {
            let ox = ((u64::from(x) * u64::from(width)) / u64::from(causes.width())) as u32;
            let oy = ((u64::from(y) * u64::from(height)) / u64::from(causes.height())) as u32;
            let s = *source.get_pixel(ox, oy);
            let f = *final_image.get_pixel(ox, oy);
            let is_protected = protect.is_some_and(|m| m.get_pixel(ox, oy).0[0] > 0);
            if luma(s) < 60 {
                source_ink += 1;
                if luma(f) < 90 {
                    ink_kept += 1;
                }
            }
            if luma(s) > 235 && luma(f) < 70 {
                sampled_new_dark += 1;
            }
            if !is_protected && luma(s) > 45 && (12.0..95.0).contains(&lab(f, &lut)[0]) && chroma(lab(f, &lut)) < 8. {
                causes.put_pixel(x, y, Luma([1]));
            }
        }
    }
    let mut summaries = Vec::new();
    let mut groups: HashMap<String, Vec<[f64; 2]>> = HashMap::new();
    for (region_index, (region, m)) in regions.iter().zip(&masks).enumerate() {
        let expected = region.color.as_ref().map(|v| hex(v).map(|c| lab(Rgb(c), &lut))).transpose()?;
        let chromatic = expected.is_none_or(|e| chroma(e) >= 8.);
        let (mut total, mut count, mut neutral, mut conflict, mut loss, mut mismatch, mut residue, mut overlap_count) =
            (0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
        let (mut sum_a, mut sum_b, mut error, mut sum_sq) = (0., 0., 0., 0.);
        for (x, y, p) in m.enumerate_pixels() {
            if p.0[0] <= 127 {
                continue;
            }
            total += 1;
            let index = usize::try_from(u64::from(y) * u64::from(width) + u64::from(x))?;
            let s = *source.get_pixel(x, y);
            let f = lab(*final_image.get_pixel(x, y), &lut);
            let r = raw.map(|im| lab(*im.get_pixel(x, y), &lut));
            let protected = protect.is_some_and(|v| v.get_pixel(x, y).0[0] > 0);
            let excluded_pixel = excluded.get(index).copied().unwrap_or(false);
            let overlapping = owners.get(index).copied() == Some(255);
            if protected {
                conflict += 1;
                if matches!(region.intent.as_str(), "color" | "closed_detail") {
                    conflicts += 1;
                }
            }
            if overlapping {
                overlap_count += 1;
            }
            let mut cause = 0;
            if matches!(region.intent.as_str(), "color" | "closed_detail") && !excluded_pixel && !overlapping && region.confidence >= 0.8 && luma(s) > 30 {
                if protected {
                    cause = 4;
                } else {
                    count += 1;
                    sum_a += f[1];
                    sum_b += f[2];
                    sum_sq += f[1] * f[1] + f[2] * f[2];
                    if chromatic && chroma(f) < 8. {
                        neutral += 1;
                        cause = 2;
                        if r.is_some_and(|r| chroma(r) >= 12.) {
                            loss += 1;
                            cause = 3;
                        }
                    }
                    if let Some(e) = expected {
                        let delta = distance(e, f);
                        error += delta;
                        if delta > 25. {
                            mismatch += 1;
                            cause = 5;
                        }
                        if region.intent == "closed_detail" && luma(s) > 235 && delta > 18. {
                            residue += 1;
                            cause = 6;
                        }
                    }
                }
            }
            if cause > 0 {
                let gx = ((u64::from(x) * u64::from(causes.width())) / u64::from(width)) as u32;
                let gy = ((u64::from(y) * u64::from(causes.height())) / u64::from(height)) as u32;
                causes.put_pixel(gx, gy, Luma([cause]));
            }
        }
        eligible += count;
        missing += neutral;
        lost += loss;
        mismatches += mismatch;
        let mean = if count > 0 { Some([sum_a / count as f64, sum_b / count as f64]) } else { None };
        if let (Some(key), Some(mean)) = (&region.palette_key, mean) {
            groups.entry(key.clone()).or_default().push(mean);
        }
        let source_detail = if matches!(region.category.as_str(), "eye" | "texture" | "hair") || region.intent == "closed_detail" {
            Some(super::detail::metrics(source, final_image, m, protect)?)
        } else {
            None
        };
        summaries.push(json!({"id":region.id,"category":region.category,"intent":region.intent,"palette_key":region.palette_key,"manual_confidence":region.confidence,"full_resolution":true,"mask_pixels":total,"eligible_pixels":count,"suspected_uncolored_pixels":neutral,"postprocessing_loss_pixels":loss,"protection_overlap_pixels":conflict,"ambiguous_overlap_pixels":overlap_count,"palette_mismatch_pixels":mismatch,"source_detail_color_residue_pixels":residue,"mean_ab":mean,"ab_standard_deviation":if count>0{Some((sum_sq/count as f64-(sum_a/count as f64).powi(2)-(sum_b/count as f64).powi(2)).max(0.).sqrt())}else{None},"mean_palette_error":if count>0 && expected.is_some(){Some(error/count as f64)}else{None},"expected_color":region.color,"automatic_repair_authorized":false,"region_index":region_index,"source_detail_metrics":source_detail}));
    }
    for (x, y, p) in causes.enumerate_pixels() {
        let color = match p.0[0] {
            1 => [110, 110, 110],
            2 => [255, 100, 0],
            3 => [255, 0, 180],
            4 => [255, 0, 0],
            5 => [255, 220, 0],
            6 => [0, 220, 255],
            _ => [0, 0, 0],
        };
        heat.put_pixel(x, y, Rgb(color));
    }
    let consistency:Vec<_>=groups.into_iter().map(|(key,means)|{let mut max_delta=0_f64;for a in &means{for b in &means{max_delta=max_delta.max((a[0]-b[0]).hypot(a[1]-b[1]));}}json!({"palette_key":key,"regions":means.len(),"max_mean_ab_difference":max_delta,"requires_review":max_delta>20.,"note":"Lighting and shadows can change this metric; this is not identity recognition."})}).collect();
    let mut report = json!({"version":1,"width":width,"height":height,"normalization":"8-bit RGB sRGB model boundary","eligibility":"Only explicitly declared, confident, nonoverlapping color regions excluding protected/neutral/black-ink pixels","eligible_pixels":eligible,"suspected_uncolored_pixels":missing,"coverage_percent":if eligible>0{Some(100.*(1.-missing as f64/eligible as f64))}else{None},"postprocessing_loss_pixels":lost,"protection_conflict_pixels":conflicts,"palette_mismatch_pixels":mismatches,"ambiguous_region_overlap_pixels":overlap,"regions":summaries,"palette_consistency":consistency,"suspected_regions":components(&causes),"diagnostic_grid":[causes.width(),causes.height()],"component_limit":256,"geometry":{"sampled_source_ink_pixels":source_ink,"sampled_source_ink_retention":if source_ink>0{Some(ink_kept as f64/source_ink as f64)}else{None},"sampled_unexplained_dark_pixels":sampled_new_dark,"semantic_geometry_verified":false},"requires_manual_review":true,"notes":["Unannotated neutral components are uncertain; white clothing, paper, gutters and shadows may be intentional.","Region coverage is full resolution, but connected-component boxes/geometry are sampled diagnostics.","Closed-detail masks must be identified from the source by a human; no automatic closed-eye classifier is claimed."]});
    report["diagnostic_transform"] =
        json!({"source_dimensions":[width,height],"preview_dimensions":[heat.width(),heat.height()],"crop_xywh":[0,0,width,height],"padding":[0,0]});
    Ok((report, heat))
}

pub fn recolor_pixels(
    source: &RgbImage,
    base: &RgbImage,
    selection: &GrayImage,
    protect: Option<&GrayImage>,
    color: [u8; 3],
    strength: f32,
) -> Result<RgbImage> {
    ensure!(strength.is_finite() && (0.0..=1.0).contains(&strength), "Strength must be 0..1");
    ensure!(
        source.dimensions() == base.dimensions() && selection.dimensions() == base.dimensions() && protect.is_none_or(|m| m.dimensions() == base.dimensions()),
        "Recolor dimensions differ"
    );
    let mut out = base.clone();
    for (x, y, p) in out.enumerate_pixels_mut() {
        let alpha = f32::from(selection.get_pixel(x, y).0[0]) / 255. * strength;
        if alpha == 0. || protect.is_some_and(|m| m.get_pixel(x, y).0[0] > 0) {
            continue;
        }
        let tone = f32::from(luma(*source.get_pixel(x, y))) / 255.;
        for (channel, target) in p.0.iter_mut().zip(color) {
            let value = f32::from(target) * tone;
            *channel = (f32::from(*channel) * (1. - alpha) + value * alpha).round().clamp(0., 255.) as u8;
        }
    }
    Ok(out)
}
pub struct RecolorFiles<'a> {
    pub source: &'a Path,
    pub base: &'a Path,
    pub selection: &'a Path,
    pub protect: Option<&'a Path>,
    pub color: &'a str,
    pub strength: f32,
    pub directory: &'a Path,
}
pub struct AuditFiles<'a> {
    pub source: &'a Path,
    pub base: &'a Path,
    pub candidate: &'a Path,
    pub selection: &'a Path,
    pub protect: Option<&'a Path>,
    pub color: Option<&'a str>,
    pub output: &'a Path,
}
pub fn audit(files: AuditFiles<'_>) -> Result<Value> {
    ensure!(!files.output.exists(), "Audit output already exists");
    let source = super::open_image(files.source)?.to_rgb8();
    let base = super::open_image(files.base)?.to_rgb8();
    let candidate = super::open_image(files.candidate)?.to_rgb8();
    let selection = mask(files.selection, source.dimensions())?;
    let protect = files.protect.map(|p| mask(p, source.dimensions())).transpose()?;
    let report = audit_pixels(&source, &base, &candidate, &selection, protect.as_ref(), files.color.map(hex).transpose()?)?;
    fs::write(files.output, serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}
pub(super) fn audit_pixels(
    source: &RgbImage,
    base: &RgbImage,
    candidate: &RgbImage,
    selection: &GrayImage,
    protect: Option<&GrayImage>,
    color: Option<[u8; 3]>,
) -> Result<Value> {
    ensure!(
        source.dimensions() == base.dimensions()
            && base.dimensions() == candidate.dimensions()
            && selection.dimensions() == base.dimensions()
            && protect.is_none_or(|m| m.dimensions() == base.dimensions()),
        "Repair audit dimensions differ"
    );
    let lut = linear_table();
    let target = color.map(|c| lab(Rgb(c), &lut));
    let (
        mut selected,
        mut outside,
        mut protected_changes,
        mut old_error,
        mut new_error,
        mut ink,
        mut old_ink,
        mut kept,
        mut new_dark,
        mut old_gray,
        mut new_gray,
    ) = (0_u64, 0_u64, 0_u64, 0., 0., 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
    for (x, y, p) in base.enumerate_pixels() {
        let next = *candidate.get_pixel(x, y);
        let chosen = selection.get_pixel(x, y).0[0] > 0;
        let protected = protect.is_some_and(|m| m.get_pixel(x, y).0[0] > 0);
        if !chosen && *p != next {
            outside += 1;
        }
        if protected && *p != next {
            protected_changes += 1;
        }
        if !chosen || protected {
            continue;
        }
        let original = luma(*source.get_pixel(x, y));
        if original < 60 {
            ink += 1;
            if luma(*p) < 90 {
                old_ink += 1;
            }
            if luma(next) < 90 {
                kept += 1;
            }
        }
        if original > 235 && luma(*p) >= 70 && luma(next) < 70 && color.is_none_or(|c| luma(Rgb(c)) >= 70) {
            new_dark += 1;
        }
        if original <= 30 {
            continue;
        }
        selected += 1;
        let before = lab(*p, &lut);
        let after = lab(next, &lut);
        if chroma(before) < 8. {
            old_gray += 1;
        }
        if chroma(after) < 8. {
            new_gray += 1;
        }
        if let Some(target) = target {
            old_error += palette_distance(before, target);
            new_error += palette_distance(after, target);
        }
    }
    let geometry = ink == 0 || (kept as f64 / ink as f64 >= 0.98 && kept + ((ink as f64 * 0.01) as u64) >= old_ink);
    let safe = selected > 0 && outside == 0 && protected_changes == 0 && geometry && new_dark <= 5_u64.max(selected / 100);
    let improvement = target.is_some() && new_error + 0.5 * (selected as f64) < old_error && (target.is_some_and(|t| chroma(t) < 8.) || new_gray <= old_gray);
    Ok(
        json!({"version":1,"accepted":safe && improvement,"safe_to_preview":safe,"selected_pixels_evaluated":selected,"changed_outside_mask":outside,"changed_protected_pixels":protected_changes,"new_unexplained_dark_pixels":new_dark,"before_neutral_pixels":old_gray,"after_neutral_pixels":new_gray,"before_mean_ab_error":if selected>0 && target.is_some(){Some(old_error/selected as f64)}else{None},"after_mean_ab_error":if selected>0 && target.is_some(){Some(new_error/selected as f64)}else{None},"source_ink_retention":if ink>0{Some(kept as f64/ink as f64)}else{None},"semantic_geometry_verified":false,"requires_visual_review":true,"reason":if !safe{"Rejected by exact isolation, protection or source-ink/new-dark-detail checks"}else if !improvement{"Retained for manual review: no approved target or insufficient measurable color improvement"}else{"Approved target agreement improved; isolation, protection and source-ink checks passed"}}),
    )
}
pub fn recolor(files: RecolorFiles<'_>) -> Result<Value> {
    ensure!(!files.directory.exists(), "Choose a fresh recolor directory");
    let source = super::open_image(files.source)?.to_rgb8();
    let base = super::open_image(files.base)?.to_rgb8();
    let selection = mask(files.selection, source.dimensions())?;
    ensure!(selection.pixels().any(|p| p.0[0] > 0), "Selection mask is empty");
    let protected = files.protect.map(|p| mask(p, source.dimensions())).transpose()?;
    let color = hex(files.color)?;
    let candidate = recolor_pixels(&source, &base, &selection, protected.as_ref(), color, files.strength)?;
    let mut report = audit_pixels(&source, &base, &candidate, &selection, protected.as_ref(), Some(color))?;
    let accepted = report["accepted"].as_bool().unwrap_or(false);
    fs::create_dir_all(files.directory)?;
    candidate.save(files.directory.join("candidate.png"))?;
    if accepted {
        candidate.save(files.directory.join("recolored.png"))?;
    }
    report["method"] = json!("Explicit masked palette multiplied by source luminance; no inference or semantic segmentation");
    report["source"] = json!(files.source);
    report["base"] = json!(files.base);
    report["mask"] = json!(files.selection);
    report["color"] = json!(files.color);
    report["strength"] = json!(files.strength);
    report["geometry_source"] = json!("Source luminance supplies structure inside the mask; generated shading is replaced there");
    fs::write(files.directory.join("repair-report.json"), serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (RgbImage, RgbImage, GrayImage) {
        (RgbImage::from_pixel(32, 32, Rgb([255, 255, 255])), RgbImage::from_pixel(32, 32, Rgb([160, 160, 160])), GrayImage::from_pixel(32, 32, Luma([255])))
    }
    #[test]
    fn palette_recolor_restores_closed_source_detail_and_exact_isolation() {
        let (mut source, mut base, mut mask) = fixture();
        mask.fill(0);
        for y in 10..20 {
            for x in 10..20 {
                mask.put_pixel(x, y, Luma([255]));
                base.put_pixel(x, y, Rgb([0, 150, 0]));
            }
        }
        for x in 10..20 {
            source.put_pixel(x, 15, Rgb([0, 0, 0]));
        }
        let mut protect = GrayImage::new(32, 32);
        protect.put_pixel(12, 12, Luma([255]));
        let out = recolor_pixels(&source, &base, &mask, Some(&protect), [230, 180, 140], 1.).unwrap();
        assert_eq!(out.get_pixel(12, 15).0, [0, 0, 0]);
        assert_eq!(out.get_pixel(12, 12), base.get_pixel(12, 12));
        assert_eq!(out.get_pixel(12, 13).0, [230, 180, 140]);
        for (x, y, p) in base.enumerate_pixels() {
            if mask.get_pixel(x, y).0[0] == 0 {
                assert_eq!(*p, *out.get_pixel(x, y));
            }
        }
    }
    #[test]
    fn rejects_bad_colors_strength_and_dimensions() {
        assert!(hex("#XX0000").is_err());
        assert!(hex("#FF").is_err());
        let (s, b, m) = fixture();
        assert!(recolor_pixels(&s, &b, &m, None, [0, 0, 0], f32::NAN).is_err());
        assert!(recolor_pixels(&s, &b, &GrayImage::new(1, 1), None, [0, 0, 0], 1.).is_err());
    }
    #[test]
    fn no_annotations_never_claims_coverage() {
        let (s, b, _) = fixture();
        let (r, _) = analyze(&s, None, &b, &[], None).unwrap();
        assert!(r["coverage_percent"].is_null());
        assert_eq!(r["eligible_pixels"], 0);
        assert_eq!(r["requires_manual_review"], true);
    }
    #[test]
    fn identical_full_color_remains_unchanged_with_zero_strength() {
        let (s, b, m) = fixture();
        assert_eq!(recolor_pixels(&s, &b, &m, None, [240, 100, 60], 0.).unwrap(), b);
    }

    struct MaskFixture {
        root: PathBuf,
        region: Region,
    }
    impl MaskFixture {
        fn new(points: &[(u32, u32)], intent: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!("manga-fidelity-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir_all(&root).unwrap();
            let path = root.join("mask.png");
            let mut mask = GrayImage::new(32, 32);
            for (x, y) in points {
                mask.put_pixel(*x, *y, Luma([255]));
            }
            mask.save(&path).unwrap();
            Self {
                root,
                region: Region {
                    id: "region".into(),
                    mask: path,
                    category: "material".into(),
                    intent: intent.into(),
                    color: Some("#E6B48C".into()),
                    palette_key: Some("person-1/base".into()),
                    confidence: 1.,
                },
            }
        }
    }
    impl Drop for MaskFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn two_pixel_region_is_not_lost_by_analysis_downsampling() {
        let (s, b, _) = fixture();
        let f = MaskFixture::new(&[(4, 5), (5, 5)], "color");
        let (r, _) = analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap();
        assert_eq!(r["eligible_pixels"], 2);
        assert_eq!(r["suspected_uncolored_pixels"], 2);
        assert_eq!(r["coverage_percent"], 0.);
    }
    #[test]
    fn detects_postprocessing_loss_and_protection_conflict_separately() {
        let (s, b, _) = fixture();
        let f = MaskFixture::new(&[(4, 5), (5, 5)], "color");
        let raw = RgbImage::from_pixel(32, 32, Rgb([230, 180, 140]));
        let mut protect = GrayImage::new(32, 32);
        protect.put_pixel(4, 5, Luma([255]));
        let (r, _) = analyze(&s, Some(&raw), &b, std::slice::from_ref(&f.region), Some(&protect)).unwrap();
        assert_eq!(r["eligible_pixels"], 1);
        assert_eq!(r["protection_conflict_pixels"], 1);
        assert_eq!(r["postprocessing_loss_pixels"], 1);
    }
    #[test]
    fn neutral_black_ink_and_low_confidence_are_not_missing_color() {
        let (mut s, b, _) = fixture();
        let mut f = MaskFixture::new(&[(4, 5)], "neutral");
        assert!(analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap().0["coverage_percent"].is_null());
        f.region.intent = "color".into();
        f.region.confidence = 0.5;
        assert_eq!(analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap().0["eligible_pixels"], 0);
        f.region.confidence = 1.;
        s.put_pixel(4, 5, Rgb([0, 0, 0]));
        assert_eq!(analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap().0["eligible_pixels"], 0);
    }
    #[test]
    fn overlapping_annotations_are_uncertain_and_not_double_counted() {
        let (s, b, _) = fixture();
        let f = MaskFixture::new(&[(4, 5)], "color");
        let mut second = f.region.clone();
        second.id = "other".into();
        let (r, _) = analyze(&s, None, &b, &[f.region.clone(), second], None).unwrap();
        assert_eq!(r["ambiguous_region_overlap_pixels"], 1);
        assert_eq!(r["eligible_pixels"], 0);
    }
    #[test]
    fn declared_closed_detail_flags_foreign_color_without_claiming_eye_detection() {
        let (s, mut b, _) = fixture();
        b.put_pixel(4, 5, Rgb([0, 180, 40]));
        let f = MaskFixture::new(&[(4, 5)], "closed_detail");
        let (r, _) = analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap();
        assert_eq!(r["regions"][0]["source_detail_color_residue_pixels"], 1);
        assert_eq!(r["geometry"]["semantic_geometry_verified"], false);
    }
    #[test]
    fn full_color_coverage_does_not_hide_palette_mismatch() {
        let (s, mut b, _) = fixture();
        b.put_pixel(4, 5, Rgb([40, 60, 220]));
        let f = MaskFixture::new(&[(4, 5)], "color");
        let (r, _) = analyze(&s, None, &b, std::slice::from_ref(&f.region), None).unwrap();
        assert_eq!(r["coverage_percent"], 100.);
        assert_eq!(r["palette_mismatch_pixels"], 1);
    }
    #[test]
    fn invalid_region_confidence_and_duplicate_ids_fail_gracefully() {
        let f = MaskFixture::new(&[(4, 5)], "color");
        assert!(validate(&[f.region.clone(), f.region.clone()]).is_err());
        let mut region = f.region.clone();
        region.confidence = f64::NAN;
        assert!(validate(&[region]).is_err());
    }
    #[test]
    fn recolor_candidates_keep_sources_and_reject_no_improvement() {
        let (s, b, _) = fixture();
        let f = MaskFixture::new(&[(4, 5), (5, 5)], "color");
        let source = f.root.join("source.png");
        let base = f.root.join("base.png");
        s.save(&source).unwrap();
        b.save(&base).unwrap();
        let directory = f.root.join("repair");
        let report = recolor(RecolorFiles {
            source: &source,
            base: &base,
            selection: &f.region.mask,
            protect: None,
            color: "#E6B48C",
            strength: 1.,
            directory: &directory,
        })
        .unwrap();
        assert_eq!(report["accepted"], true);
        assert_eq!(report["changed_outside_mask"], 0);
        assert_eq!(super::super::open_image(&base).unwrap().to_rgb8(), b);
        let good = directory.join("recolored.png");
        let rejected = f.root.join("no-improvement");
        assert_eq!(
            recolor(RecolorFiles {
                source: &source,
                base: &good,
                selection: &f.region.mask,
                protect: None,
                color: "#E6B48C",
                strength: 1.,
                directory: &rejected
            })
            .unwrap()["accepted"],
            false
        );
        assert!(!rejected.join("recolored.png").exists());
        assert!(rejected.join("candidate.png").exists());
    }
    #[test]
    fn audit_rejects_outside_and_protected_changes_and_unapproved_candidates() {
        let (s, b, mut m) = fixture();
        m.fill(0);
        m.put_pixel(4, 5, Luma([255]));
        let mut c = b.clone();
        c.put_pixel(4, 5, Rgb([230, 180, 140]));
        assert_eq!(audit_pixels(&s, &b, &c, &m, None, None).unwrap()["accepted"], false);
        assert_eq!(audit_pixels(&s, &b, &c, &m, None, Some([230, 180, 140])).unwrap()["accepted"], true);
        assert_eq!(audit_pixels(&s, &b, &c, &m, Some(&m), Some([230, 180, 140])).unwrap()["safe_to_preview"], false);
        c.put_pixel(0, 0, Rgb([0, 0, 0]));
        assert_eq!(audit_pixels(&s, &b, &c, &m, None, Some([230, 180, 140])).unwrap()["changed_outside_mask"], 1);
    }
    #[test]
    fn audit_rejects_lost_source_ink() {
        let (mut s, b, m) = fixture();
        s.put_pixel(4, 5, Rgb([0, 0, 0]));
        assert_eq!(audit_pixels(&s, &b, &b, &m, None, Some([230, 180, 140])).unwrap()["safe_to_preview"], false);
    }
    #[test]
    fn neutral_target_uses_lightness_and_preserves_black_materials() {
        let (s, b, m) = fixture();
        let c = recolor_pixels(&s, &b, &m, None, [30, 30, 30], 1.).unwrap();
        assert_eq!(audit_pixels(&s, &b, &c, &m, None, Some([30, 30, 30])).unwrap()["accepted"], true);
    }
    #[test]
    #[ignore = "24MP CPU performance check; run in release"]
    fn benchmark_24mp() {
        let start = std::time::Instant::now();
        let s = RgbImage::from_pixel(6000, 4000, Rgb([255, 255, 255]));
        let b = RgbImage::from_pixel(6000, 4000, Rgb([160, 160, 160]));
        let m = GrayImage::from_pixel(6000, 4000, Luma([255]));
        let c = recolor_pixels(&s, &b, &m, None, [230, 180, 140], 1.).unwrap();
        let report = audit_pixels(&s, &b, &c, &m, None, Some([230, 180, 140])).unwrap();
        assert_eq!(report["accepted"], true);
        eprintln!("24MP recolor plus full-resolution audit: {:.3}s", start.elapsed().as_secs_f64());
        let f = MaskFixture::new(&[(1, 1)], "color");
        m.save(&f.region.mask).unwrap();
        let analysis_start = std::time::Instant::now();
        let (r, _) = analyze(&s, Some(&b), &c, std::slice::from_ref(&f.region), None).unwrap();
        assert_eq!(r["coverage_percent"], 100.);
        eprintln!("24MP explicit-region coverage: {:.3}s", analysis_start.elapsed().as_secs_f64());
    }
    #[test]
    fn approved_skin_and_white_clothing_keep_distinct_meanings_and_identity_colors() {
        let (s, mut b, _) = fixture();
        let first = MaskFixture::new(&[(4, 5), (5, 5)], "color");
        let mut second = MaskFixture::new(&[(20, 22), (21, 22)], "color");
        second.region.id = "inset".into();
        second.region.palette_key = first.region.palette_key.clone();
        b.put_pixel(4, 5, Rgb([40, 40, 180]));
        b.put_pixel(5, 5, Rgb([40, 40, 180]));
        b.put_pixel(20, 22, Rgb([180, 40, 40]));
        b.put_pixel(21, 22, Rgb([180, 40, 40]));
        let regions = [first.region.clone(), second.region.clone()];
        assert_eq!(analyze(&s, None, &b, &regions, None).unwrap().0["palette_consistency"][0]["requires_review"], true);
        let m1 = mask(&first.region.mask, s.dimensions()).unwrap();
        let m2 = mask(&second.region.mask, s.dimensions()).unwrap();
        let corrected = recolor_pixels(&s, &b, &m1, None, [230, 180, 140], 1.).unwrap();
        let corrected = recolor_pixels(&s, &corrected, &m2, None, [230, 180, 140], 1.).unwrap();
        assert_eq!(analyze(&s, None, &corrected, &regions, None).unwrap().0["palette_consistency"][0]["requires_review"], false);
        assert_eq!(corrected.get_pixel(4, 5), corrected.get_pixel(20, 22));
        let mut white = first.region.clone();
        white.category = "clothing".into();
        white.intent = "neutral".into();
        assert!(analyze(&s, None, &s, &[white], None).unwrap().0["coverage_percent"].is_null());
        let mut skin = first.region.clone();
        skin.category = "skin".into();
        assert_eq!(analyze(&s, None, &s, &[skin], None).unwrap().0["suspected_uncolored_pixels"], 2);
        let mut protected = first.region.clone();
        protected.category = "intentional_uncolored".into();
        assert_eq!(analyze(&s, None, &s, &[protected], None).unwrap().0["eligible_pixels"], 0);
    }
}
