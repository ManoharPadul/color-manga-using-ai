//! Conservative CPU second pass. Unannotated candidates are proposals, never repairs.
use super::fidelity::{self, Region, chroma, lab, linear_table, luma};
use anyhow::{Result, ensure};
use image::{GrayImage, Luma, Rgb, RgbImage};
use serde_json::{Value, json};
use std::{collections::VecDeque, fs, path::Path, time::Instant};
pub struct Files<'a> {
    pub source: &'a Path,
    pub colored: &'a Path,
    pub raw: Option<&'a Path>,
    pub regions: Option<&'a Path>,
    pub protect: Option<&'a Path>,
    pub profiles: Option<&'a Path>,
    pub output: &'a Path,
    pub apply: bool,
    pub sensitivity: f64,
    pub attempts: usize,
    pub debug: bool,
}
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
fn protected(mask: Option<&GrayImage>, x: u32, y: u32) -> bool {
    mask.is_some_and(|m| m.get_pixel(x, y)[0] > 0)
}
fn threshold(sensitivity: f64) -> f64 {
    6. + 6. * sensitivity
}
fn category_threshold(category: &str, sensitivity: f64) -> f64 {
    // Hair and fabric may legitimately have much weaker chroma than skin.
    let (base, range) = match category {
        "skin" => (6., 6.),
        "hair" => (3., 3.),
        "clothing" => (4., 4.),
        _ => (3., 2.),
    };
    base + range * sensitivity
}
fn neutral_palette(color: [u8; 3]) -> bool {
    // Palette intent must not change when detection sensitivity changes.
    // D65 neutral RGB colors have essentially zero Lab chroma; pale peach is
    // chromatic and must not be mistaken for intentionally white material.
    chroma(lab(Rgb(color), &linear_table())) < 3.
}
fn approved(r: &Region) -> bool {
    r.confidence >= 0.95 && r.intent == "color" && matches!(r.category.as_str(), "skin" | "hair" | "clothing") && r.color.is_some()
}
pub(super) fn same_assignment(a: &Region, b: &Region) -> bool {
    approved(a)
        && approved(b)
        && a.category == b.category
        && a.palette_key.as_ref().is_some_and(|key| !key.is_empty() && b.palette_key.as_ref() == Some(key))
        && a.color.as_ref().zip(b.color.as_ref()).is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
}
fn missing_mask(source: &RgbImage, base: &RgbImage, region: &GrayImage, protect: Option<&GrayImage>, owners: &GrayImage, cutoff: f64) -> GrayImage {
    let lut = linear_table();
    let (w, h) = source.dimensions();
    let mut output = GrayImage::new(w, h);
    for (x, y, p) in base.enumerate_pixels() {
        if region.get_pixel(x, y)[0] < 128
            || owners.get_pixel(x, y)[0] != 1
            || protected(protect, x, y)
            || luma(*p) < 32
            || luma(*source.get_pixel(x, y)) < 45
            || chroma(lab(*p, &lut)) >= cutoff
        {
            continue;
        }
        // Keep the ink pixel itself excluded, but do not erode neighboring
        // material pixels: that erosion left neutral rims around source lines.
        output.put_pixel(x, y, Luma([255]));
    }
    // Feather inward only. No selected pixel can grow outside the approved region.
    let binary = output.clone();
    for (x, y, p) in output.enumerate_pixels_mut() {
        if p[0] > 0 && neighbors(x, y, w, h).any(|(xx, yy)| binary.get_pixel(xx, yy)[0] == 0) {
            p[0] = 180;
        }
    }
    output
}
// Boundary comparisons are source-edge aware: a real material edge is not a seam.
// This supplements (rather than replaces) the exact-pixel and geometry audits.
fn seam_audit(source: &RgbImage, base: &RgbImage, candidate: &RgbImage, mask: &GrayImage, authority: &GrayImage, protect: Option<&GrayImage>) -> Value {
    let (w, h) = source.dimensions();
    let lut = linear_table();
    let (mut before, mut after, mut count) = (0., 0., 0_u64);
    for (x, y, p) in mask.enumerate_pixels() {
        if p[0] == 0 {
            continue;
        }
        for (nx, ny) in neighbors(x, y, w, h) {
            if authority.get_pixel(nx, ny)[0] < 128
                || mask.get_pixel(nx, ny)[0] != 0
                || protected(protect, nx, ny)
                || neighbors(nx, ny, w, h).any(|(xx, yy)| luma(*source.get_pixel(xx, yy)) < 85 || protected(protect, xx, yy))
                || luma(*source.get_pixel(x, y)).abs_diff(luma(*source.get_pixel(nx, ny))) > 30
            {
                continue;
            }
            let distance = |image: &RgbImage| {
                let a = lab(*image.get_pixel(x, y), &lut);
                let b = lab(*image.get_pixel(nx, ny), &lut);
                ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
            };
            before += distance(base);
            after += distance(candidate);
            count += 1;
        }
    }
    let denominator = count.max(1) as f64;
    let before = before / denominator;
    let after = after / denominator;
    json!({"boundary_pairs":count,"mean_delta_e_before":before,"mean_delta_e_after":after,
        "accepted":count == 0 || after <= before + 3.,"reason":"Source-smooth repair boundaries must not increase mean Lab discontinuity by more than 3"})
}
fn changed(a: &RgbImage, b: &RgbImage) -> u64 {
    a.pixels().zip(b.pixels()).filter(|(a, b)| a != b).count() as u64
}
fn global_proposals(
    source: &RgbImage,
    base: &RgbImage,
    protect: Option<&GrayImage>,
    known: Option<&GrayImage>,
    sensitivity: f64,
) -> Result<(Vec<Value>, RgbImage, Vec<GrayImage>)> {
    let (w, h) = base.dimensions();
    let (dw, dh) = super::coordinates::fit(w, h, 768);
    let small = image::imageops::thumbnail(base, dw, dh);
    let (wg, hg) = small.dimensions();
    let src = image::imageops::resize(source, wg, hg, image::imageops::FilterType::Triangle);
    let protected_grid = protect.map(|m| {
        // Max pooling retains thin lettering at noninteger diagnostic scales.
        let mut grid = GrayImage::new(wg, hg);
        for (x, y, p) in m.enumerate_pixels() {
            if p[0] > 0 {
                grid.put_pixel((u64::from(x) * u64::from(wg) / u64::from(w)) as u32, (u64::from(y) * u64::from(hg) / u64::from(h)) as u32, Luma([255]));
            }
        }
        grid
    });
    let known = known.map(|m| image::imageops::resize(m, wg, hg, image::imageops::FilterType::Nearest));
    let mut classes = GrayImage::new(wg, hg);
    let mut seen = GrayImage::new(wg, hg);
    let lut = linear_table();
    let mut overlay = small.clone();
    for (x, y, p) in small.enumerate_pixels() {
        let c = if protected(protected_grid.as_ref(), x, y) || luma(*src.get_pixel(x, y)) < 70 {
            4
        } else if known.as_ref().is_some_and(|m| m.get_pixel(x, y)[0] > 0) {
            known.as_ref().map(|m| m.get_pixel(x, y)[0]).unwrap_or(5)
        } else if p.0.iter().all(|v| *v >= 244) && src.get_pixel(x, y).0.iter().all(|v| *v >= 244) {
            // Unchanged source-white is not evidence of a missed color. This
            // removes bubble interiors, eye whites and teeth from proposals.
            // Approved semantic regions still use their independent full-res path.
            3
        } else if chroma(lab(*p, &lut)) >= threshold(sensitivity) {
            1
        } else {
            5
        };
        classes.put_pixel(x, y, Luma([c]));
    }
    let mut proposals: Vec<Value> = Vec::new();
    let mut masks = Vec::new();
    for y in 0..hg {
        for x in 0..wg {
            if seen.get_pixel(x, y)[0] > 0 || classes.get_pixel(x, y)[0] != 5 {
                continue;
            }
            seen.put_pixel(x, y, Luma([255]));
            let mut queue = VecDeque::from([(x, y)]);
            let mut points = Vec::new();
            let (mut colored, mut boundary, mut sa, mut sb, mut square, mut edge) = (0_u64, 0_u64, 0., 0., 0., false);
            let (mut left, mut right, mut top, mut bottom) = (x, x, y, y);
            while let Some((xx, yy)) = queue.pop_front() {
                points.push((xx, yy));
                left = left.min(xx);
                right = right.max(xx);
                top = top.min(yy);
                bottom = bottom.max(yy);
                edge |= xx == 0 || yy == 0 || xx + 1 == wg || yy + 1 == hg;
                for (nx, ny) in neighbors(xx, yy, wg, hg) {
                    let class = classes.get_pixel(nx, ny)[0];
                    if class == 5 && seen.get_pixel(nx, ny)[0] == 0 && luma(*src.get_pixel(xx, yy)).abs_diff(luma(*src.get_pixel(nx, ny))) <= 45 {
                        seen.put_pixel(nx, ny, Luma([255]));
                        queue.push_back((nx, ny));
                    } else if class != 5 {
                        boundary += 1;
                        if class == 1 {
                            colored += 1;
                            let c = lab(*small.get_pixel(nx, ny), &lut);
                            sa += c[1];
                            sb += c[2];
                            square += c[1] * c[1] + c[2] * c[2];
                        }
                    }
                }
            }
            if points.len() < 16
                || (edge && points.len() > ((u64::from(wg) * u64::from(hg)) / 4) as usize)
                || (points.len() <= 48 && colored < 2 && boundary >= points.len() as u64 / 2)
            {
                continue;
            }
            let variance =
                if colored > 0 { (square / colored as f64 - (sa / colored as f64).powi(2) - (sb / colored as f64).powi(2)).max(0.).sqrt() } else { 100. };
            let contextual = !edge
                && (right - left + 1).min(bottom - top + 1) > 2
                && (right - left + 1).max(bottom - top + 1) <= (right - left + 1).min(bottom - top + 1).saturating_mul(12)
                && colored >= 8
                && colored as f64 / (boundary.max(1) as f64) > 0.85
                && variance < 10.
                && points.len() < ((u64::from(wg) * u64::from(hg)) / 10) as usize;
            let class = if contextual { "probably_missing_color" } else { "uncertain" };
            let confidence = if contextual { 0.7 } else { 0.25 };
            let reason = if contextual {
                "Neutral patch surrounded by consistent chroma without a source-ink boundary; category and palette still require approval"
            } else {
                "No approved material/palette evidence; may be white clothing, eye whites, text, page margin or intentional gray"
            };
            let mut proposal = GrayImage::new(wg, hg);
            for (xx, yy) in points.iter().copied() {
                proposal.put_pixel(xx, yy, Luma([255]));
                overlay.put_pixel(xx, yy, if contextual { Rgb([255, 90, 50]) } else { Rgb([210, 190, 60]) });
            }
            let id = format!("suggestion-{:02}", proposals.len() + 1);
            let score = if contextual { 1_000_000 + points.len() } else { points.len() };
            let replacement = if proposals.len() >= 64 {
                proposals
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, p)| p["ranking_score"].as_u64().unwrap_or(0))
                    .map(|(i, p)| (i, p["ranking_score"].as_u64().unwrap_or(0)))
            } else {
                None
            };
            if replacement.is_some_and(|(_, old)| score as u64 <= old) {
                continue;
            }
            let item = json!({"id":id,"classification":class,"category":"unassigned","confidence":confidence,"reason":reason,"automatic_repair_authorized":false,"diagnostic_grid_pixels":points.len(),"bounds":[u64::from(left)*u64::from(w)/u64::from(wg),u64::from(top)*u64::from(h)/u64::from(hg),(u64::from(right-left+1)*u64::from(w)).div_ceil(u64::from(wg)),(u64::from(bottom-top+1)*u64::from(h)).div_ceil(u64::from(hg))],"mask":null,"ranking_score":score});
            if let Some((index, _)) = replacement {
                if let Some(p) = proposals.get_mut(index) {
                    *p = item;
                }
                if let Some(m) = masks.get_mut(index) {
                    *m = proposal;
                }
            } else {
                proposals.push(item);
                masks.push(proposal);
            }
        }
    }
    let mut ranked: Vec<_> = proposals.into_iter().zip(masks).collect();
    ranked.sort_by_key(|(p, _)| std::cmp::Reverse(p["ranking_score"].as_u64().unwrap_or(0)));
    let (mut proposals, masks): (Vec<Value>, Vec<GrayImage>) = ranked.into_iter().unzip();
    overlay = small.clone();
    for (p, m) in proposals.iter().zip(&masks) {
        if p["classification"] == "uncertain" {
            continue;
        }
        for (x, y, v) in m.enumerate_pixels() {
            if v[0] > 0 {
                overlay.put_pixel(x, y, if p["classification"] == "probably_missing_color" { Rgb([255, 90, 50]) } else { Rgb([210, 190, 60]) });
            }
        }
    }
    for (i, p) in proposals.iter_mut().enumerate() {
        p["id"] = json!(format!("suggestion-{:02}", i + 1));
    }
    Ok((proposals, overlay, masks))
}
pub fn run(files: Files<'_>) -> Result<Value> {
    let started = Instant::now();
    ensure!(!files.output.exists(), "Choose a fresh second-pass directory");
    ensure!(files.sensitivity.is_finite() && (0.0..=1.0).contains(&files.sensitivity), "Sensitivity must be 0..1");
    ensure!(files.attempts <= 8, "At most eight repair attempts");
    let source = super::open_image(files.source)?.to_rgb8();
    let base = super::open_image(files.colored)?.to_rgb8();
    ensure!(source.dimensions() == base.dimensions(), "Second-pass dimensions differ");
    let (w, h) = source.dimensions();
    let regions = fidelity::load_regions(files.regions)?;
    let profiles = files
        .profiles
        .map(|p| -> Result<Value> {
            ensure!(fs::metadata(p)?.len() <= 128000, "Profiles exceed 128KB");
            super::read_json(p)
        })
        .transpose()?;
    ensure!(u64::from(w) * u64::from(h) * (regions.len() as u64) <= 256_000_000, "Too many full-resolution annotated pixels");
    let protect = Some(super::protection::unified(&source, files.source, files.protect)?);
    let mut owners = GrayImage::new(w, h);
    let mut first_owner = GrayImage::new(w, h);
    let mut known = GrayImage::new(w, h);
    for (region_index, region) in regions.iter().enumerate() {
        let mask = fidelity::mask(&region.mask, (w, h))?;
        let neutral = region.color.as_deref().map(fidelity::hex).transpose()?.is_some_and(neutral_palette);
        for (x, y, p) in mask.enumerate_pixels() {
            if p[0] > 127 {
                if region.intent == "exclude" || region.category == "text" {
                    known.put_pixel(x, y, Luma([4]));
                } else if region.intent == "neutral" || region.category == "intentional_uncolored" || neutral {
                    known.put_pixel(x, y, Luma([3]));
                }
                let old = owners.get_pixel(x, y)[0];
                if old == 0 {
                    first_owner.put_pixel(x, y, Luma([(region_index + 1) as u8]));
                    owners.put_pixel(x, y, Luma([1]));
                } else if old == 1 {
                    let first = first_owner.get_pixel(x, y)[0];
                    let compatible = usize::from(first).checked_sub(1).and_then(|i| regions.get(i)).is_some_and(|other| same_assignment(region, other));
                    if !compatible {
                        owners.put_pixel(x, y, Luma([2]));
                    }
                }
            }
        }
    }
    let (mut proposals, overlay, masks) = global_proposals(&source, &base, protect.as_ref(), Some(&known), files.sensitivity)?;
    for proposal in &mut proposals {
        proposal["source_page"] = json!(files.source);
        proposal["coordinate_space"] = json!("original_pixels_xywh");
        proposal["character_id"] = Value::Null;
        proposal["outfit_id"] = Value::Null;
        proposal["garment_id"] = Value::Null;
        proposal["expected_palette"] = Value::Null;
        proposal["suggested_repair_method"] = json!("review_category_identity_palette_and_mask");
        proposal["semantic_evidence"] = json!(false);
        proposal["protection_conflict_status"] = json!("protected pixels excluded; no semantic authorization");
    }
    fs::create_dir_all(files.output)?;
    if let Some(mask) = &protect {
        mask.save(files.output.join("unified-protection.png"))?;
    }
    if files.debug {
        overlay.save(files.output.join("coverage-overlay.png"))?;
        for (i, small) in masks.iter().take(16).enumerate() {
            let mut mask = image::imageops::resize(small, w, h, image::imageops::FilterType::Nearest);
            for (x, y, p) in mask.enumerate_pixels_mut() {
                if luma(*source.get_pixel(x, y)) < 85 || protected(protect.as_ref(), x, y) {
                    p[0] = 0;
                }
            }
            let path = files.output.join(format!("suggestion-{:02}.png", i + 1));
            mask.save(&path)?;
            if let Some(item) = proposals.get_mut(i) {
                item["mask"] = json!(path);
            }
        }
    }
    let lut = linear_table();
    let mut working = base.clone();
    let (mut attempted, mut accepted, mut rejected) = (0, 0, 0);
    let mut records = Vec::new();
    for region in &regions {
        let manual = fidelity::mask(&region.mask, (w, h))?;
        let target = region.color.as_deref().map(fidelity::hex).transpose()?;
        let neutral = matches!(region.intent.as_str(), "neutral" | "exclude")
            || matches!(region.category.as_str(), "text" | "intentional_uncolored")
            || target.is_some_and(neutral_palette);
        if neutral {
            records.push(json!({"id":region.id,"classification":if region.category=="text"||region.intent=="exclude"{"protected"}else{"intentional_white_gray"},"confidence":region.confidence,"reason":"Approved neutral/excluded region or neutral palette; no automatic recoloring","attempted":false}));
            continue;
        }
        let cutoff = target.map(|c| category_threshold(&region.category, files.sensitivity).min(chroma(lab(Rgb(c), &lut)) * 0.65)).unwrap_or(3.);
        let mut selection = missing_mask(&source, &working, &manual, protect.as_ref(), &owners, cutoff);
        // Blending a gray missed patch into an already correct material leaves a
        // gray rim. Use full correction at an edge only when adjacent existing
        // color agrees with the approved palette. Protection remains absolute.
        if let Some(color) = target {
            let expected = lab(Rgb(color), &lut);
            let binary = selection.clone();
            for (x, y, p) in selection.enumerate_pixels_mut() {
                if p[0] != 180 {
                    continue;
                }
                if neighbors(x, y, w, h).any(|(nx, ny)| {
                    let adjacent = lab(*working.get_pixel(nx, ny), &lut);
                    binary.get_pixel(nx, ny)[0] == 0
                        && manual.get_pixel(nx, ny)[0] >= 128
                        && !protected(protect.as_ref(), nx, ny)
                        && chroma(adjacent) > cutoff
                        && (adjacent[1] - expected[1]).hypot(adjacent[2] - expected[2]) < 10.
                        && luma(*source.get_pixel(x, y)).abs_diff(luma(*source.get_pixel(nx, ny))) < 30
                }) {
                    p[0] = 255;
                }
            }
        }
        let count = selection.pixels().filter(|p| p[0] > 0).count();
        let palette_verified = match (&profiles, &region.palette_key, &region.color) {
            (Some(profiles), Some(key), Some(color)) => super::bindings::palette(profiles, key).is_some_and(|c| c.eq_ignore_ascii_case(color)),
            _ => true,
        };
        let eligible = approved(region) && count > 0 && target.is_some() && palette_verified;
        let mut record = json!({"id":region.id,"category":region.category,"palette_key":region.palette_key,"approved_mask":region.mask,"classification":if count==0{"confidently_colored"}else if eligible{"probably_missing_color"}else{"uncertain"},"confidence":if eligible{0.98}else{region.confidence.min(0.7)},"suspected_pixels":count,"reason":if eligible{"Manual human-related region and chromatic palette agree; bright neutral pixels inside source-edge-constrained selection"}else{"No approved human-related palette/category, conflicting masks, or no eligible neutral pixels"},"attempted":false,"accepted":false});
        record["profile_palette_verified"] = json!(palette_verified);
        record["expected_palette"] = json!(region.color);
        record["character_id"] = json!(region.palette_key.as_deref().and_then(|k| k.split('/').next()));
        if !palette_verified {
            record["reason"] = json!("Saved region palette conflicts with current authoritative profile or garment ID; review assignment before repair");
        }
        if files.apply && eligible && attempted < files.attempts {
            attempted += 1;
            record["attempted"] = json!(true);
            if let Some(color) = target {
                let transfer = super::color_transfer::boundary_candidate(&source, &working, &selection, protect.as_ref(), color)?;
                let candidate = transfer.image;
                let audit = fidelity::audit_pixels(&source, &working, &candidate, &selection, protect.as_ref(), Some(color))?;
                let context_audit = fidelity::audit_pixels(&source, &working, &candidate, &manual, protect.as_ref(), Some(color))?;
                let seam = seam_audit(&source, &working, &candidate, &selection, &manual, protect.as_ref());
                record["cpu_candidates_evaluated"] = json!(1);
                record["repair_method"] = json!("source_boundary_supported_chroma_propagation");
                if files.debug {
                    // Retain a diagnostic comparison, never accept the old
                    // source-luminance fill in place of the shading-safe repair.
                    let legacy = fidelity::recolor_pixels(&source, &working, &selection, protect.as_ref(), color, 1.)?;
                    record["legacy_candidate_comparison"] = json!({"audit":fidelity::audit_pixels(&source,&working,&legacy,&selection,protect.as_ref(),Some(color))?,"seam_audit":seam_audit(&source,&working,&legacy,&selection,&manual,protect.as_ref()),"accepted_as_result":false});
                    legacy.save(files.output.join(format!("repair-{attempted}-legacy.png")))?;
                    record["cpu_candidates_evaluated"] = json!(2);
                }
                let boundary_ok = transfer.evidence["requires_boundary_review"] == false && transfer.evidence["luminance_preserved"] == true;
                record["boundary_evidence"] = transfer.evidence;
                record["context_geometry_audit"] = context_audit.clone();
                record["audit"] = audit.clone();
                let ok = audit["accepted"].as_bool() == Some(true)
                    && context_audit["safe_to_preview"].as_bool() == Some(true)
                    && seam["accepted"] == true
                    && boundary_ok;
                if !boundary_ok {
                    record["reason"] =
                        json!("Uncertain source/material boundary or luminance change; review the mask and surrounding palette before acceptance");
                }
                record["seam_audit"] = seam;
                record["chroma_threshold"] = json!(cutoff);
                record["accepted"] = json!(ok);
                record["changed_pixels"] = json!(changed(&working, &candidate));
                if files.debug {
                    selection.save(files.output.join(format!("repair-{attempted}-mask.png")))?;
                    candidate.save(files.output.join(format!("repair-{attempted}-candidate.png")))?;
                }
                if ok {
                    working = candidate;
                    accepted += 1;
                } else {
                    rejected += 1;
                }
            }
        }
        records.push(record);
    }
    if accepted > 0 {
        working.save(files.output.join("repaired.png"))?;
    }
    let raw = files.raw.map(|p| super::open_image(p).map(|i| i.to_rgb8())).transpose()?;
    let (final_measurements, _) = fidelity::analyze(&source, raw.as_ref(), &working, &regions, protect.as_ref())?;
    let protected_pixels = protect.as_ref().map(|m| m.pixels().filter(|p| p[0] > 0).count()).unwrap_or(0);
    let review_count = proposals.len() + records.iter().filter(|r| r["suspected_pixels"].as_u64().unwrap_or(0) > 0 && r["accepted"] != true).count();
    let summary = json!({"regions_analyzed":regions.len(),"unassigned_proposals":proposals.len(),"repairs_accepted":accepted,"repairs_rejected":rejected,"requiring_review":review_count,"protected_pixels":protected_pixels});
    let mut report = json!({"version":1,"pass":2,"summary":summary,"unified_protection":files.output.join("unified-protection.png"),"final_measurements":final_measurements,"cpu_only":true,"source":files.source,"input":files.colored,"width":w,"height":h,"sensitivity":files.sensitivity,"auto_repair_enabled":files.apply,"repair_attempt_limit":files.attempts,"repairs_attempted":attempted,"repairs_accepted":accepted,"repairs_rejected":rejected,"changed_pixels":changed(&base,&working),"proposals":proposals,"approved_regions":records,"elapsed_seconds":started.elapsed().as_secs_f64(),"result":if accepted>0{Some(files.output.join("repaired.png"))}else{None},"requires_visual_review":true,"semantic_geometry_verified":false,"overlay":if files.debug{Some(files.output.join("coverage-overlay.png"))}else{None},"notes":["Unannotated neutral components are proposals only; categories are never inferred from saturation alone.","Only manually approved skin/hair/clothing masks with chromatic palettes can auto-repair. Neutral/black pixels, source ink barriers, overlaps and protection are excluded.","Global components are sampled at up to 768 pixels; approved repair masks and audits use original resolution.","Cached text/bubble masks are combined with a resolution-scaled guard and blank edge bands. Without cached layout, unchanged white is unresolved rather than a missing-color proposal; no automatic text recognition is claimed."]});
    report["diagnostic_transform"] = json!({"source_dimensions":[w,h],"preview_dimensions":[overlay.width(),overlay.height()],"crop_xywh":[0,0,w,h],"padding":[0,0],"unknown_regions_hidden":true});
    fs::write(files.output.join("coverage.json"), serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shading_preserving_fallback_passes_unchanged_seam_gate_after_bright_fill_fails() {
        let source = RgbImage::from_pixel(128, 128, Rgb([255, 255, 255]));
        let mut base = RgbImage::from_pixel(128, 128, Rgb([170, 180, 200]));
        for y in 32..96 {
            for x in 32..96 {
                base.put_pixel(x, y, Rgb([180, 180, 180]));
            }
        }
        let manual = GrayImage::from_pixel(128, 128, Luma([255]));
        let owners = GrayImage::from_pixel(128, 128, Luma([1]));
        let selection = missing_mask(&source, &base, &manual, None, &owners, 8.2);
        let first = fidelity::recolor_pixels(&source, &base, &selection, None, [255, 228, 213], 1.).unwrap();
        assert_eq!(seam_audit(&source, &base, &first, &selection, &manual, None)["accepted"], false);
        let second = super::super::color_transfer::candidate(&base, &selection, None, [255, 228, 213]).unwrap();
        assert_eq!(seam_audit(&source, &base, &second, &selection, &manual, None)["accepted"], true);
        let audit = fidelity::audit_pixels(&source, &base, &second, &selection, None, Some([255, 228, 213])).unwrap();
        assert_eq!(audit["accepted"], true);
        assert_eq!(audit["changed_outside_mask"], 0);
    }
    #[test]
    fn approved_pale_peach_is_not_neutral_at_maximum_sensitivity() {
        let peach = [255, 228, 213];
        assert!(!neutral_palette(peach));
        for neutral in [[255, 255, 255], [128, 128, 128], [0, 0, 0], [2, 0, 1]] {
            assert!(neutral_palette(neutral));
        }
        let source = RgbImage::from_pixel(32, 32, Rgb([255, 255, 255]));
        let base = RgbImage::from_pixel(32, 32, Rgb([200, 200, 200]));
        let region = GrayImage::from_pixel(32, 32, Luma([255]));
        let owners = GrayImage::from_pixel(32, 32, Luma([1]));
        let lut = linear_table();
        let cutoff = category_threshold("skin", 1.).min(chroma(lab(Rgb(peach), &lut)) * 0.65);
        assert!(chroma(lab(Rgb(peach), &lut)) > cutoff);
        assert!(missing_mask(&source, &base, &region, None, &owners, cutoff).get_pixel(16, 16)[0] > 0);
        let colored = RgbImage::from_pixel(32, 32, Rgb(peach));
        assert!(missing_mask(&source, &colored, &region, None, &owners, cutoff).pixels().all(|p| p[0] == 0));
    }
    #[test]
    fn compatible_overlap_requires_same_approved_identity_material_and_palette() {
        let a: Region = serde_json::from_value(json!({"id":"a","mask":"mask.png","category":"skin","color":"#FFE4D5","palette_key":"p1/skin"})).unwrap();
        let mut b = a.clone();
        b.id = "b".into();
        assert!(same_assignment(&a, &b));
        b.palette_key = Some("p2/skin".into());
        assert!(!same_assignment(&a, &b));
        b = a.clone();
        b.intent = "neutral".into();
        assert!(!same_assignment(&a, &b));
        b = a.clone();
        b.color = Some("#AABBCC".into());
        assert!(!same_assignment(&a, &b));
    }
    #[test]
    fn white_clothing_margins_and_teeth_are_not_automatically_repaired() {
        let s = RgbImage::from_pixel(64, 64, Rgb([255, 255, 255]));
        let b = s.clone();
        let (p, _, _) = global_proposals(&s, &b, None, None, 0.5).unwrap();
        assert!(p.iter().all(|p| p["automatic_repair_authorized"] == false));
        assert!(p.iter().all(|p| p["classification"] == "uncertain"));
    }
    #[test]
    fn connected_neutral_hole_has_context_but_no_semantic_authority() {
        let s = RgbImage::from_pixel(64, 64, Rgb([255, 255, 255]));
        let mut b = RgbImage::from_pixel(64, 64, Rgb([240, 150, 100]));
        for y in 25..33 {
            for x in 25..33 {
                b.put_pixel(x, y, Rgb([180, 180, 180]));
            }
        }
        let (p, _, _) = global_proposals(&s, &b, None, None, 0.5).unwrap();
        assert!(p.iter().any(|p| p["classification"] == "probably_missing_color"));
        assert!(p.iter().all(|p| p["automatic_repair_authorized"] == false));
    }
    #[test]
    fn approved_missing_selection_stops_at_source_ink_protection_and_overlaps() {
        let mut s = RgbImage::from_pixel(32, 32, Rgb([255, 255, 255]));
        let b = RgbImage::from_pixel(32, 32, Rgb([200, 200, 200]));
        let mut region = GrayImage::new(32, 32);
        for y in 8..24 {
            for x in 8..24 {
                region.put_pixel(x, y, Luma([255]));
            }
        }
        let mut owners = GrayImage::from_pixel(32, 32, Luma([1]));
        let mut p = GrayImage::new(32, 32);
        p.put_pixel(12, 12, Luma([255]));
        s.put_pixel(15, 15, Rgb([0, 0, 0]));
        owners.put_pixel(18, 18, Luma([2]));
        let m = missing_mask(&s, &b, &region, Some(&p), &owners, category_threshold("skin", 0.5));
        assert_eq!(m.get_pixel(12, 12)[0], 0);
        assert_eq!(m.get_pixel(15, 15)[0], 0);
        assert_eq!(m.get_pixel(18, 18)[0], 0);
        assert_eq!(m.get_pixel(0, 0)[0], 0);
        assert!(m.get_pixel(10, 10)[0] > 0);
        let candidate = fidelity::recolor_pixels(&s, &b, &m, Some(&p), [230, 180, 140], 1.).unwrap();
        let audit = fidelity::audit_pixels(&s, &b, &candidate, &m, Some(&p), Some([230, 180, 140])).unwrap();
        assert_eq!(audit["accepted"], true);
        assert_eq!(audit["changed_outside_mask"], 0);
    }
    #[test]
    fn category_thresholds_do_not_treat_muted_fabric_like_skin() {
        assert!(category_threshold("hair", 1.) < category_threshold("clothing", 1.));
        assert!(category_threshold("clothing", 1.) < category_threshold("skin", 1.));
    }
    #[test]
    fn unchanged_white_details_and_protected_text_never_become_proposals() {
        let source = RgbImage::from_pixel(137, 193, Rgb([255, 255, 255]));
        let mut colored = RgbImage::from_pixel(137, 193, Rgb([240, 150, 100]));
        let mut protection = GrayImage::new(137, 193);
        for y in 40..70 {
            for x in 40..70 {
                colored.put_pixel(x, y, Rgb([255, 255, 255]));
            }
        }
        for y in 90..120 {
            for x in 40..70 {
                colored.put_pixel(x, y, Rgb([180, 180, 180]));
                protection.put_pixel(x, y, Luma([255]));
            }
        }
        let (proposals, _, _) = global_proposals(&source, &colored, Some(&protection), None, 0.5).unwrap();
        assert!(proposals.is_empty());
    }
    #[test]
    fn seam_gate_rejects_a_new_rectangular_color_boundary() {
        let source = RgbImage::from_pixel(24, 24, Rgb([200, 200, 200]));
        let base = source.clone();
        let mut candidate = base.clone();
        let mut mask = GrayImage::new(24, 24);
        for y in 8..16 {
            for x in 8..16 {
                mask.put_pixel(x, y, Luma([255]));
                candidate.put_pixel(x, y, Rgb([240, 130, 90]));
            }
        }
        assert_eq!(seam_audit(&source, &base, &candidate, &mask, &GrayImage::from_pixel(24, 24, Luma([255])), None)["accepted"], false);
        assert_eq!(seam_audit(&source, &base, &base, &mask, &GrayImage::from_pixel(24, 24, Luma([255])), None)["accepted"], true);
    }
}
