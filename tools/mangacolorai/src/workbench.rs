use eframe::egui;
use serde_json::Value;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum MaskTool {
    #[default]
    Brush,
    Region,
    Eyedropper,
}

#[derive(Default)]
pub struct Workbench {
    pub source: Option<PathBuf>,
    pub attempts: Vec<PathBuf>,
    source_texture: Option<egui::TextureHandle>,
    result_texture: Option<egui::TextureHandle>,
    live_texture: Option<egui::TextureHandle>,
    live_signature: Option<u64>,
    selection_revision: u64,
    pub live_image: Option<image::RgbImage>,
    pub save_live_requested: bool,
    loaded: Option<(PathBuf, PathBuf)>,
    pub zoom: f32,
    pub split: f32,
    pub paint: bool,
    tool: MaskTool,
    seeded_mask: Option<image::GrayImage>,
    erase: bool,
    radius: f32,
    strokes: Vec<[f32; 3]>,
    undo_points: Vec<usize>,
    last_point: Option<egui::Pos2>,
    pub repair_prompt: String,
    pub crop_context: f64,
    pub repair_requested: bool,
    pub recolor_requested: bool,
    pub quality_requested: bool,
    pub detail_requested: bool,
    pub detail_mode: String,
    pub detail_strength: f64,
    pub region_category: String,
    pub approved_regions: Vec<Value>,
    pub register_region: bool,
    pub analyze_approved: bool,
    pub palette_key: String,
    pub candidate_base: Option<PathBuf>,
    pub candidate_previewing: bool,
    pub candidate_reviewable: bool,
    pub commit_candidate: bool,
    pub reject_candidate: bool,
    pub target_color: String,
    pub region_intent: String,
    pub palette_choices: Vec<(String, String)>,
    pub pending_candidate: Option<PathBuf>,
    pub accept_candidate: bool,
    pub quality_path: Option<PathBuf>,
    pub suggestions: Vec<Value>,
    external_mask: Option<PathBuf>,
    external_mask_texture: Option<egui::TextureHandle>,
    pub quality_texture: Option<egui::TextureHandle>,
    pub protection_texture: Option<egui::TextureHandle>,
    show_protection: bool,
    hide_uncertain: bool,
    pub automatic_overlay: bool,
    pub message: String,
    pub review: Option<Review>,
}
pub struct Review {
    pub path: PathBuf,
    pub data: Value,
    pub assignments: bool,
    preview: Option<egui::TextureHandle>,
}
pub fn load_document(path: &Path) -> Result<Value, String> {
    if std::fs::metadata(path).map_err(|e| e.to_string())?.len() > 2_000_000 {
        return Err("Review file exceeds 2MB.".into());
    }
    let data = std::fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(data.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&data)).map_err(|e| e.to_string())
}
pub fn validate_text(data: &Value) -> Result<(), String> {
    let width = data["width"].as_u64().unwrap_or(0);
    let height = data["height"].as_u64().unwrap_or(0);
    let regions = data["regions"].as_array().ok_or("Missing text regions")?;
    if width == 0 || height == 0 || width.saturating_mul(height) > 120_000_000 || regions.len() > 200 {
        return Err("Invalid text canvas or too many regions.".into());
    }
    for r in regions {
        let n = |key: &str| r[key].as_u64().ok_or("Text boxes require nonnegative integer coordinates");
        let (x, y, w, h) = (n("x")?, n("y")?, n("width")?, n("height")?);
        if w == 0 || h == 0 || x.saturating_add(w) > width || y.saturating_add(h) > height {
            return Err("Text box lies outside the page.".into());
        }
        if r["selected"].as_bool().unwrap_or(false) && r["translation"].as_str().is_none_or(|s| s.trim().is_empty() || s.len() > 16000) {
            return Err("Complete each selected translation before approving.".into());
        }
    }
    Ok(())
}
fn texture(path: &Path, ctx: &egui::Context) -> Result<egui::TextureHandle, String> {
    let im = super::preview_image(path)?;
    Ok(ctx.load_texture(
        path.to_string_lossy(),
        egui::ColorImage::from_rgba_unmultiplied([im.width() as usize, im.height() as usize], im.as_raw()),
        egui::TextureOptions::LINEAR,
    ))
}
impl Workbench {
    pub fn set_source(&mut self, path: PathBuf) {
        if self.source.as_ref() != Some(&path) {
            self.strokes.clear();
            self.undo_points.clear();
            self.last_point = None;
            self.loaded = None;
            self.live_texture = None;
            self.live_signature = None;
            self.live_image = None;
            self.selection_revision = self.selection_revision.wrapping_add(1);
            self.quality_path = None;
            self.quality_texture = None;
            self.protection_texture = None;
            self.automatic_overlay = false;
            self.external_mask = None;
            self.seeded_mask = None;
            self.external_mask_texture = None;
            self.suggestions.clear();
            self.approved_regions.clear();
            self.pending_candidate = None;
            self.candidate_base = None;
            self.candidate_previewing = false;
        }
        self.source = Some(path);
    }
    pub fn open_review(&mut self, path: PathBuf, assignments: bool) {
        match load_document(&path).and_then(|data| {
            if !data.is_object() {
                return Err("Review must be a JSON object".into());
            }
            if assignments {
                validate_assignments(&data)?;
            } else if data["regions"].as_array().is_none_or(|a| a.len() > 200 || a.iter().any(|r| !r.is_object())) {
                return Err("Invalid text review structure".into());
            }
            Ok(data)
        }) {
            Ok(data) => self.review = Some(Review { path, data, assignments, preview: None }),
            Err(e) => self.message = e,
        }
    }
    pub fn show_review(&mut self, ctx: &egui::Context) {
        let Some(review) = self.review.as_mut() else { return };
        if let Some(path) = review.data["source"].as_str() {
            let path = PathBuf::from(path);
            if review.preview.is_none()
                && let Ok(image) = texture(&path, ctx)
            {
                review.preview = Some(image);
            }
            if let Some(image) = &review.preview {
                egui::Window::new("Detected regions — source page").default_pos(egui::pos2(10., 80.)).default_width(320.).show(ctx, |ui| {
                    let size = image.size_vec2() * (310. / image.size_vec2().x).min(500. / image.size_vec2().y);
                    let response = ui.add(egui::Image::new(image).fit_to_exact_size(size));
                    let width = review.data["width"].as_f64().unwrap_or(1.).max(1.) as f32;
                    let height = review.data["height"].as_f64().unwrap_or(1.).max(1.) as f32;
                    let key = if review.assignments { "panels" } else { "regions" };
                    for (i, r) in review.data[key].as_array().into_iter().flatten().enumerate() {
                        let x = r["x"].as_f64().unwrap_or(0.) as f32 / width;
                        let y = r["y"].as_f64().unwrap_or(0.) as f32 / height;
                        let w = r["width"].as_f64().unwrap_or(0.) as f32 / width;
                        let h = r["height"].as_f64().unwrap_or(0.) as f32 / height;
                        let rect = egui::Rect::from_min_size(response.rect.min + egui::vec2(x * size.x, y * size.y), egui::vec2(w * size.x, h * size.y));
                        ui.painter().rect_stroke(rect, 0., egui::Stroke::new(1., egui::Color32::LIGHT_RED), egui::StrokeKind::Inside);
                        ui.painter().text(rect.min, egui::Align2::LEFT_TOP, format!("{}", i + 1), egui::FontId::proportional(12.), egui::Color32::RED);
                        if review.assignments {
                            for person in r["vision_assignment"]["people"].as_array().into_iter().flatten() {
                                if let Some(bounds) = person["source_bbox"].as_array().filter(|a| a.len() == 4) {
                                    let value = |n: usize| bounds.get(n).and_then(|v| v.as_f64()).unwrap_or(0.) as f32;
                                    let person_rect = egui::Rect::from_min_size(
                                        response.rect.min + egui::vec2(value(0) / width * size.x, value(1) / height * size.y),
                                        egui::vec2(value(2) / width * size.x, value(3) / height * size.y),
                                    );
                                    ui.painter().rect_stroke(person_rect, 0., egui::Stroke::new(1., egui::Color32::LIGHT_BLUE), egui::StrokeKind::Inside);
                                    ui.painter().text(
                                        person_rect.min,
                                        egui::Align2::LEFT_TOP,
                                        format!("{} / {}", person["id"], person["outfit"]),
                                        egui::FontId::proportional(11.),
                                        egui::Color32::LIGHT_BLUE,
                                    );
                                }
                            }
                        }
                    }
                });
            }
        }
        let has_profiles = review.data.get("profiles").is_some();
        let mut approved = false;
        let mut saved = false;
        egui::Window::new(if review.assignments { "Approve panel identities and outfit colors" } else { "Review text before coloring" })
            .default_width(720.)
            .default_height(600.)
            .resizable(true)
            .show(ctx, |ui| {
                ui.label(review.path.to_string_lossy());
                if review.assignments {
                    ui.label("Inspect each match and edit its color instructions. Delete incorrect instructions. No match is safer than a wrong match.");
                } else {
                    ui.label("Correct OCR, translation and pixel coordinates. Uncheck regions that should stay in the artwork.");
                }
                egui::ScrollArea::vertical().max_height(470.).show(ui, |ui| {
                    let key = if review.assignments { "panels" } else { "regions" };
                    if let Some(regions) = review.data[key].as_array_mut() {
                        for (i, r) in regions.iter_mut().enumerate() {
                            ui.push_id(i, |ui| {
                                ui.separator();
                                ui.label(format!("Box {} · {} · x:{} y:{} {}×{}", i + 1, r["id"], r["x"], r["y"], r["width"], r["height"]));
                                if review.assignments {
                                    if let Some(warning) = r["vision_assignment"]["review_warning"].as_str() {
                                        ui.label(warning);
                                    }
                                    if let Some(appearances) = r["vision_assignment"]["people"].as_array_mut() {
                                        for person in appearances {
                                            if person["recovered_requires_confirmation"] == true {
                                                let mut confirmed = person["identity_confirmed"].as_bool().unwrap_or(false);
                                                ui.checkbox(&mut confirmed, "I checked this recovered identity/outfit against the source");
                                                person["identity_confirmed"] = confirmed.into();
                                            }
                                            ui.label(format!("{} · source xywh {}", person["appearance_id"], person["source_bbox"]));
                                            ui.label(person["evidence"].as_str().unwrap_or("No distinguishing evidence supplied"));
                                            edit_string(ui, person, "id", "Character ID (unknown if uncertain)");
                                            edit_string(ui, person, "outfit", "Selected outfit ID/name (empty if uncertain)");
                                            let mut confidence = person["confidence"].as_f64().unwrap_or(0.);
                                            ui.add(egui::Slider::new(&mut confidence, 0.0..=1.0).text("Match confidence; approved match ≥0.95"));
                                            person["confidence"] = confidence.into();
                                            let mut outfit_confidence = person["outfit_confidence"].as_f64().unwrap_or(confidence);
                                            ui.add(egui::Slider::new(&mut outfit_confidence, 0.0..=1.0).text("Outfit confidence; ≥0.95 to use garment colors"));
                                            person["outfit_confidence"] = outfit_confidence.into();
                                        }
                                    }
                                    if !has_profiles {
                                        edit_string(ui, r, "style", "Approved color instructions");
                                    } else {
                                        edit_string(ui, r, "base_style", "Additional instructions (identity colors rebuilt from approved profiles)");
                                    }
                                } else {
                                    let mut selected = r["selected"].as_bool().unwrap_or(false);
                                    ui.checkbox(&mut selected, "Replace this text");
                                    r["selected"] = selected.into();
                                    let mut rectangle = r["rectangle_mask"].as_bool().unwrap_or(false);
                                    ui.checkbox(&mut rectangle, "Use edited rectangle for removal (check artwork boundaries)");
                                    r["rectangle_mask"] = rectangle.into();
                                    edit_string(ui, r, "source_text", "Original OCR");
                                    edit_string(ui, r, "translation", "Translation");
                                    ui.horizontal(|ui| {
                                        for key in ["x", "y", "width", "height"] {
                                            let mut n = r[key].as_u64().unwrap_or(0);
                                            ui.label(key);
                                            ui.add(egui::DragValue::new(&mut n).range(0..=120000));
                                            r[key] = n.into();
                                        }
                                    });
                                }
                            });
                        }
                    }
                });
                ui.horizontal(|ui| {
                    saved = ui.button("Save edits").clicked();
                    approved = ui.button("Approve and continue").clicked();
                });
                ui.label(&self.message);
            });
        if saved || approved {
            if approved && review.assignments {
                if let Some(profiles) = review.data["profiles"]["characters"].as_array().cloned()
                    && let Some(panels) = review.data["panels"].as_array_mut()
                {
                    for panel in panels {
                        let crop = [panel["x"].as_u64(), panel["y"].as_u64(), panel["width"].as_u64(), panel["height"].as_u64()];
                        if let [Some(x), Some(y), Some(w), Some(h)] = crop
                            && [x, y, w, h].iter().all(|v| *v <= u64::from(u32::MAX))
                        {
                            super::bindings::locate(&mut panel["vision_assignment"], [x as u32, y as u32, w as u32, h as u32]);
                        }
                        // Rebuild from authoritative profiles after identity/outfit
                        // edits so old suggested colors cannot survive a correction.
                        panel["style"] =
                            super::bindings::matched_profile_instructions(panel["base_style"].as_str().unwrap_or(""), &panel["vision_assignment"], &profiles)
                                .into();
                    }
                }
                review.data["approved"] = Value::Bool(true);
            }
            if approved && !review.assignments {
                review.data["requires_review"] = false.into();
            }
            let valid = if review.assignments { validate_assignments(&review.data) } else { validate_text(&review.data) };
            let result = valid.and_then(|()| {
                let bytes = serde_json::to_vec_pretty(&review.data).map_err(|e| e.to_string())?;
                std::fs::write(&review.path, bytes).map_err(|e| e.to_string())?;
                if approved {
                    std::fs::write(format!("{}.approved", review.path.display()), b"approved").map_err(|e| e.to_string())?;
                }
                Ok(())
            });
            match result {
                Ok(()) => {
                    self.message = "Saved.".into();
                    if approved {
                        self.review = None;
                    }
                }
                Err(e) => self.message = e,
            }
        }
    }
    pub fn show(&mut self, ui: &mut egui::Ui, result: &Path, ctx: &egui::Context, busy: bool) {
        let Some(source) = self.source.clone() else {
            ui.label("Select the source page for this result.");
            return;
        };
        if self.loaded.as_ref() != Some(&(source.clone(), result.to_path_buf())) {
            if image::image_dimensions(&source).ok() != image::image_dimensions(result).ok() {
                self.message = "Source and result dimensions differ; choose the matching original page.".into();
                ui.label(&self.message);
                return;
            }
            match (texture(&source, ctx), texture(result, ctx)) {
                (Ok(a), Ok(b)) => {
                    self.source_texture = Some(a);
                    self.result_texture = Some(b);
                    self.loaded = Some((source, result.to_path_buf()));
                }
                (Err(e), _) | (_, Err(e)) => {
                    self.message = e;
                    return;
                }
            }
        }
        egui::ScrollArea::vertical()
            .id_salt("color-repair-controls")
            .max_height(280.)
            .show(ui, |ui| {
        ui.horizontal(|ui| {
            ui.label("Zoom");
            ui.add(egui::Slider::new(&mut self.zoom, 0.2..=4.).max_decimals(1));
            ui.label("Source / Result");
            ui.add(egui::Slider::new(&mut self.split, 0.0..=1.));
            if ui.checkbox(&mut self.paint, "Edit repair mask").changed() && !self.paint {
                self.tool = MaskTool::Brush;
                self.last_point = None;
            }
            if self.paint {
                ui.radio_value(&mut self.tool, MaskTool::Brush, "Brush paint");
                ui.radio_value(&mut self.tool, MaskTool::Region, "Multi-select enclosed regions");
                if ui.radio_value(&mut self.tool, MaskTool::Eyedropper, "Pick color").changed() {
                    // Show the colorized side across the whole canvas while sampling.
                    self.split = 0.0;
                }
                if self.tool == MaskTool::Brush {
                    ui.checkbox(&mut self.erase, "Erase mask");
                }
            }
        });
        ui.horizontal(|ui| {
            if ui.add_enabled(!busy, egui::Button::new("Analyze color coverage (CPU)")).clicked() {
                self.quality_requested = true;
                self.analyze_approved = false;
            }
            if !self.approved_regions.is_empty() && ui.add_enabled(!busy, egui::Button::new("Compare approved appearances")).clicked() {
                self.analyze_approved = true;
                self.quality_requested = true;
            }
            if let Some(path) = &self.quality_path {
                ui.hyperlink_to("Quality report", path.to_string_lossy());
            }
            if self.pending_candidate.is_some() && ui.add_enabled(!busy, egui::Button::new("Preview retained candidate")).clicked() {
                self.accept_candidate = true;
            }
        });
        let mut import = None;
        if !self.suggestions.is_empty() {
            egui::CollapsingHeader::new("Suggested missing-color regions")
                .default_open(false)
                .show(ui, |ui| {
                ui.checkbox(&mut self.hide_uncertain, "Hide uncertain suggestions");
                for item in self.suggestions.iter().take(16) {
                    if self.hide_uncertain && item["classification"] == "uncertain" {
                        continue;
                    }
                    ui.horizontal(|ui| {
                        ui.label(format!("{} · {} · confidence {}", item["id"], item["classification"], item["confidence"]));
                        if ui.add_enabled(!busy, egui::Button::new("Select proposed mask")).clicked() {
                            import = item["mask"].as_str().map(PathBuf::from);
                        }
                    });
                    ui.label(item["reason"].as_str().unwrap_or("Manual review required"));
                }
            });
        }
        if let Some(path) = import {
            match super::preview_image(&path) {
                Ok(image) => {
                    let mut pixels = image;
                    for p in pixels.pixels_mut() {
                        *p = image::Rgba([240, 50, 90, (u16::from(p[0]) * 70 / 255) as u8]);
                    }
                    self.external_mask_texture = Some(ctx.load_texture(
                        "suggested-mask",
                        egui::ColorImage::from_rgba_unmultiplied([pixels.width() as usize, pixels.height() as usize], pixels.as_raw()),
                        egui::TextureOptions::LINEAR,
                    ));
                    self.external_mask = Some(path);
                    self.seeded_mask = None;
                    self.strokes.clear();
                    self.undo_points.clear();
                    self.selection_revision = self.selection_revision.wrapping_add(1);
                    self.live_signature = None;
                    self.paint = true;
                    self.target_color.clear();
                    self.palette_key.clear();
                    self.region_category.clear();
                    self.message = "Proposed mask loaded. Inspect boundaries and explicitly choose a category and palette.".into();
                }
                Err(error) => self.message = error,
            }
        }
        if self.pending_candidate.is_some() {
            ui.horizontal(|ui| {
                if ui.add_enabled(!busy && self.candidate_previewing && self.candidate_reviewable, egui::Button::new("Accept inspected correction")).clicked() {
                    self.commit_candidate = true;
                }
                if ui.add_enabled(!busy, egui::Button::new("Reject / restore previous result")).clicked() {
                    self.reject_candidate = true;
                }
            });
            ui.label("Candidates never replace the accepted image until you inspect and accept. Failed numerical checks cannot be accepted here.");
        }
        if self.paint {
            ui.label(match self.tool {
                MaskTool::Brush => "Paint or erase the mask with the brush. Choose a category and color, then inspect the live result.",
                MaskTool::Region => "Click one or more enclosed source regions to add them to the same mask. Clear mask starts over.",
                MaskTool::Eyedropper => "Click a colored area in the result to sample its color. Sampling switches back to Brush paint.",
            });
            ui.horizontal(|ui| {
                ui.label("Brush radius (% width)");
                ui.add(egui::Slider::new(&mut self.radius, 0.2..=8.));
                if ui.button("Undo stroke").clicked()
                    && let Some(index) = self.undo_points.pop()
                {
                    self.strokes.truncate(index);
                    self.selection_revision = self.selection_revision.wrapping_add(1);
                }
                if ui.button("Clear mask").clicked() {
                    self.strokes.clear();
                    self.external_mask = None;
                    self.seeded_mask = None;
                    self.external_mask_texture = None;
                    self.undo_points.clear();
                    self.selection_revision = self.selection_revision.wrapping_add(1);
                    self.live_signature = None;
                }
            });
            ui.horizontal(|ui| {
                ui.menu_button(if self.region_category.is_empty() { "Region category".to_owned() } else { self.region_category.clone() }, |ui| {
                    for value in ["skin", "hair", "clothing", "background", "text", "intentional_uncolored", "eye", "texture"] {
                        ui.selectable_value(&mut self.region_category, value.into(), value);
                    }
                });
                if self.region_category == "skin" && !super::valid_hex(&self.target_color) {
                    self.target_color = "#F1CEB6".into();
                }
                ui.label("Target color");
                let mut selected = parse_hex_color(&self.target_color).map_or(egui::Color32::WHITE, |[red, green, blue]| {
                    egui::Color32::from_rgb(red, green, blue)
                });
                if ui.color_edit_button_srgba(&mut selected).on_hover_text("Choose the target RGB color").changed() {
                    self.target_color = format!("#{:02X}{:02X}{:02X}", selected.r(), selected.g(), selected.b());
                    self.palette_key.clear();
                }
                ui.label("#RRGGBB");
                if ui.text_edit_singleline(&mut self.target_color).changed() {
                    self.palette_key.clear();
                }
                ui.menu_button("Choose saved color", |ui| {
                    for (name, color) in &self.palette_choices {
                        if ui.selectable_label(false, name).clicked() {
                            self.target_color = color.clone();
                            self.palette_key = name.clone();
                        }
                    }
                });
            });
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(!busy && self.has_mask() && super::valid_hex(&self.target_color), egui::Button::new("Run checked palette repair (CPU)"))
                    .clicked()
                {
                    self.recolor_requested = true;
                }
                ui.menu_button(if self.region_intent.is_empty() { "color".to_owned() } else { self.region_intent.clone() }, |ui| {
                    for value in ["color", "neutral", "exclude", "closed_detail"] {
                        ui.selectable_value(&mut self.region_intent, value.into(), value);
                    }
                });
            });
            if ui.add_enabled(!busy && self.has_mask() && !self.region_category.is_empty(), egui::Button::new("Save approved region / appearance")).clicked() {
                self.register_region = true;
            }
            ui.label(format!(
                "Approved regions on this page: {}. A shared palette key compares corresponding appearances; category labels are manual.",
                self.approved_regions.len()
            ));
            ui.label("Blue brush strokes erase selected pixels. Clear mask discards the proposal. Coverage uses the painted region; closed_detail requires you to identify the closed feature. Palette repair replaces shading inside the mask with source tones.");
            ui.horizontal(|ui| {
                ui.menu_button(if self.detail_mode.is_empty() { "Source geometry".to_owned() } else { self.detail_mode.clone() }, |ui| {
                    ui.selectable_value(&mut self.detail_mode, "geometry".into(), "Source eye/region luminance geometry");
                    ui.selectable_value(&mut self.detail_mode, "texture".into(), "Source high-frequency texture");
                });
                ui.add(egui::Slider::new(&mut self.detail_strength, 0.0..=1.0).text("Detail strength"));
                if ui.add_enabled(!busy && self.has_mask(), egui::Button::new("Preview source detail (CPU)")).clicked() {
                    self.detail_requested = true;
                }
            });
            if self.live_image.is_some() && ui.add_enabled(!busy, egui::Button::new("Save Image…")).clicked() {
                self.save_live_requested = true;
            }
            ui.label("Geometry removes invented luminance inside the mask; source-white areas may turn white. Texture adds source contrast and requires visual review.");
            ui.add(egui::Slider::new(&mut self.crop_context, 0.0..=1.0).text("AI crop context"));
            ui.text_edit_multiline(&mut self.repair_prompt);
            if ui.add_enabled(!busy && self.has_mask() && !self.repair_prompt.trim().is_empty(), egui::Button::new("Create masked repair candidate")).clicked()
            {
                self.repair_requested = true;
            }
        }
        ui.label(&self.message);
        if let Some(texture) = &self.protection_texture {
            ui.checkbox(&mut self.show_protection, "Show Pass 2 exclusions (white = protected)");
            if self.show_protection {
                let size = texture.size_vec2();
                ui.add(egui::Image::new(texture).fit_to_exact_size(size * (ui.available_width() / size.x).min(320. / size.y).min(1.)));
            }
        }
        if let Some(image) = &self.quality_texture {
            egui::CollapsingHeader::new("Coverage heatmap").show(ui,|ui| {
            ui.label(if self.automatic_overlay{"Orange: context-supported neutral patch · yellow: uncertain neutral region. No unapproved suggestion is automatically repaired."}else{"Orange: missing color · magenta: postprocessing loss · red: protection conflict · yellow: palette mismatch · cyan: source-detail residue · gray: uncertain."});
            let size=image.size_vec2();let size=size*(ui.available_width()/size.x).min(320./size.y).min(1.);ui.add(egui::Image::new(image).fit_to_exact_size(size));
        });
        }
        });
        if let Err(error) = self.update_live_preview(result, ctx) {
            self.live_image = None;
            self.live_texture = None;
            self.message = error;
        }
        let (Some(a), Some(b)) = (&self.source_texture, self.live_texture.as_ref().or(self.result_texture.as_ref())) else { return };
        let fit = (ui.available_width() / b.size_vec2().x).min(1.);
        let size = b.size_vec2() * fit * self.zoom.max(0.2);
        let mut seed = None;
        let mut sample_color_at = None;
        egui::ScrollArea::both().id_salt("comparison").show(ui, |ui| {
            let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click_and_drag());
            let uv = egui::Rect::from_min_max(egui::Pos2::ZERO, egui::pos2(1., 1.));
            ui.painter().image(b.id(), rect, uv, egui::Color32::WHITE);
            let left = egui::Rect::from_min_max(rect.min, egui::pos2(rect.left() + rect.width() * self.split, rect.bottom()));
            ui.painter().with_clip_rect(left.intersect(ui.clip_rect())).image(a.id(), rect, uv, egui::Color32::WHITE);
            if self.paint
                && self.tool == MaskTool::Region
                && !busy
                && response.clicked()
                && let Some(pos) = response.interact_pointer_pos()
            {
                seed = Some(((pos.x - rect.left()) / rect.width(), (pos.y - rect.top()) / rect.height()));
            }
            if self.paint
                && self.tool == MaskTool::Eyedropper
                && !busy
                && response.clicked()
                && let Some(pos) = response.interact_pointer_pos()
            {
                sample_color_at = Some(((pos.x - rect.left()) / rect.width(), (pos.y - rect.top()) / rect.height()));
            }
            if self.paint
                && let Some(texture) = &self.external_mask_texture
            {
                ui.painter().image(texture.id(), rect, uv, egui::Color32::WHITE);
            }
            if self.paint
                && self.tool == MaskTool::Brush
                && !busy
                && (response.dragged() || response.clicked())
                && let Some(pos) = response.interact_pointer_pos()
            {
                let previous_len = self.strokes.len();
                let point = egui::pos2(((pos.x - rect.left()) / rect.width()).clamp(0., 1.), ((pos.y - rect.top()) / rect.height()).clamp(0., 1.));
                let radius = self.radius.max(0.2) / 100.;
                if let Some(previous) = self.last_point {
                    let distance = ((point.x - previous.x).powi(2) + ((point.y - previous.y) * rect.height() / rect.width()).powi(2)).sqrt();
                    let steps = (distance / (radius * 0.4)).ceil().clamp(1., 500.) as usize;
                    for i in 1..=steps {
                        let t = i as f32 / steps as f32;
                        self.strokes.push([
                            previous.x + (point.x - previous.x) * t,
                            previous.y + (point.y - previous.y) * t,
                            if self.erase { -radius } else { radius },
                        ]);
                    }
                } else {
                    self.undo_points.push(self.strokes.len());
                    self.strokes.push([point.x, point.y, if self.erase { -radius } else { radius }]);
                }
                self.last_point = Some(point);
                if self.strokes.len() != previous_len {
                    self.selection_revision = self.selection_revision.wrapping_add(1);
                    ctx.request_repaint();
                }
            } else {
                self.last_point = None;
            }
            for [x, y, r] in &self.strokes {
                ui.painter().circle_filled(
                    egui::pos2(rect.left() + x * rect.width(), rect.top() + y * rect.height()),
                    r.abs() * rect.width(),
                    if *r < 0. { egui::Color32::from_rgba_unmultiplied(40, 180, 230, 140) } else { egui::Color32::from_rgba_unmultiplied(240, 50, 90, 55) },
                );
            }
        });
        if let Some((x, y)) = sample_color_at {
            let sampled = (|| -> Result<[u8; 3], String> {
                let sample = |width: u32, height: u32, pixel: &[u8]| -> Result<[u8; 3], String> {
                    if width == 0 || height == 0 || pixel.len() < 3 {
                        return Err("The result image has no pixels to sample.".into());
                    }
                    Ok([pixel[0], pixel[1], pixel[2]])
                };
                if let Some(live) = &self.live_image {
                    let (width, height) = live.dimensions();
                    let px = ((x.clamp(0.0, 0.999_999) * width as f32) as u32).min(width.saturating_sub(1));
                    let py = ((y.clamp(0.0, 0.999_999) * height as f32) as u32).min(height.saturating_sub(1));
                    let pixel = live.get_pixel(px, py);
                    sample(width, height, &pixel.0)
                } else {
                    let image = image::ImageReader::open(result).map_err(|e| e.to_string())?.decode().map_err(|e| e.to_string())?.to_rgb8();
                    let (width, height) = image.dimensions();
                    let px = ((x.clamp(0.0, 0.999_999) * width as f32) as u32).min(width.saturating_sub(1));
                    let py = ((y.clamp(0.0, 0.999_999) * height as f32) as u32).min(height.saturating_sub(1));
                    let pixel = image.get_pixel(px, py);
                    sample(width, height, &pixel.0)
                }
            })();
            match sampled {
                Ok([red, green, blue]) => {
                    self.target_color = format!("#{red:02X}{green:02X}{blue:02X}");
                    self.palette_key.clear();
                    self.tool = MaskTool::Brush;
                    self.message = format!("Sampled #{red:02X}{green:02X}{blue:02X} from the color result. Brush paint is ready.");
                }
                Err(error) => self.message = error,
            }
        }
        if let Some((x, y)) = seed {
            let result = (|| -> Result<image::GrayImage, String> {
                let path = self.source.as_ref().ok_or("No source image")?;
                let dimensions = image::image_dimensions(path).map_err(|e| e.to_string())?;
                if u64::from(dimensions.0) * u64::from(dimensions.1) > 120_000_000 {
                    return Err("Source exceeds 120 MP".into());
                }
                let original = image::open(path).map_err(|e| e.to_string())?.to_luma8();
                super::segmentation::grow(
                    &original,
                    ((x.clamp(0., 0.999999) * original.width() as f32) as u32, (y.clamp(0., 0.999999) * original.height() as f32) as u32),
                )
            })();
            match result {
                Ok(incoming) => {
                    let merged_result = (|| -> Result<image::GrayImage, String> {
                        let (width, height) = incoming.dimensions();
                        let mut merged = if let Some(existing) = &self.seeded_mask {
                            if existing.dimensions() != (width, height) {
                                return Err("Existing selection dimensions do not match the source page.".into());
                            }
                            existing.clone()
                        } else if let Some(path) = &self.external_mask {
                            let existing = image::ImageReader::open(path).map_err(|e| e.to_string())?.decode().map_err(|e| e.to_string())?.to_luma8();
                            if existing.dimensions() != (width, height) {
                                return Err("Proposed mask dimensions do not match the source page.".into());
                            }
                            existing
                        } else {
                            image::GrayImage::new(width, height)
                        };
                        for (x, y, pixel) in incoming.enumerate_pixels() {
                            if pixel[0] > 0 {
                                let old = merged.get_pixel(x, y)[0];
                                merged.put_pixel(x, y, image::Luma([old.max(pixel[0])]));
                            }
                        }
                        Ok(merged)
                    })();
                    let mask = match merged_result {
                        Ok(mask) => mask,
                        Err(error) => {
                            self.message = error;
                            return;
                        }
                    };
                    let preview = image::imageops::thumbnail(&mask, 1024, 1024);
                    let pixels: Vec<u8> = preview.pixels().flat_map(|p| [240, 50, 90, (u16::from(p[0]) * 70 / 255) as u8]).collect();
                    self.external_mask_texture = Some(ctx.load_texture(
                        "source-region",
                        egui::ColorImage::from_rgba_unmultiplied([preview.width() as usize, preview.height() as usize], &pixels),
                        egui::TextureOptions::LINEAR,
                    ));
                    self.seeded_mask = Some(mask);
                    self.external_mask = None;
                    self.selection_revision = self.selection_revision.wrapping_add(1);
                    self.live_signature = None;
                    self.paint = true;
                    self.tool = MaskTool::Region;
                    self.message = "Region added to the current mask. Click additional regions to multi-select; use Clear mask to start over.".into();
                }
                Err(error) => self.message = error,
            }
        }
    }
    fn has_mask(&self) -> bool {
        !self.strokes.is_empty() || self.external_mask.is_some() || self.seeded_mask.is_some()
    }
    pub fn save_mask(&self, path: &Path, width: u32, height: u32) -> Result<(), String> {
        let mask = self.build_mask(width, height)?;
        mask.save(path).map_err(|e| e.to_string())?;
        let mut bounds = (width, height, 0, 0);
        let mut any = false;
        for (x, y, p) in mask.enumerate_pixels() {
            if p.0[0] > 0 {
                any = true;
                bounds.0 = bounds.0.min(x);
                bounds.1 = bounds.1.min(y);
                bounds.2 = bounds.2.max(x);
                bounds.3 = bounds.3.max(y);
            }
        }
        if !any {
            return Err("Paint at least one region.".into());
        }
        let padding = (width / 50).max(16);
        let x = bounds.0.saturating_sub(padding);
        let y = bounds.1.saturating_sub(padding);
        let right = bounds.2.saturating_add(padding).saturating_add(1).min(width);
        let bottom = bounds.3.saturating_add(padding).saturating_add(1).min(height);
        let data = serde_json::json!({"id":"repair","x":x,"y":y,"width":right-x,"height":bottom-y});
        std::fs::write(path.with_extension("bounds.json"), serde_json::to_vec(&data).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    }
    fn build_mask(&self, width: u32, height: u32) -> Result<image::GrayImage, String> {
        if width == 0 || height == 0 || u64::from(width) * u64::from(height) > 120_000_000 {
            return Err("Invalid mask dimensions.".into());
        }
        let mut mask = if let Some(mask) = &self.seeded_mask {
            if mask.dimensions() != (width, height) {
                return Err("Selection dimensions do not match source".into());
            }
            mask.clone()
        } else if let Some(path) = &self.external_mask {
            let (w, h) = image::image_dimensions(path).map_err(|e| e.to_string())?;
            if (w, h) != (width, height) {
                return Err("Suggested mask dimensions do not match this page.".into());
            }
            image::ImageReader::open(path).map_err(|e| e.to_string())?.decode().map_err(|e| e.to_string())?.to_luma8()
        } else {
            image::GrayImage::new(width, height)
        };
        for [x, y, r] in &self.strokes {
            let cx = x * width as f32;
            let cy = y * height as f32;
            let radius = r.abs() * width as f32;
            let x0 = (cx - radius).max(0.) as u32;
            let y0 = (cy - radius).max(0.) as u32;
            let x1 = (cx + radius).min(width as f32 - 1.) as u32;
            let y1 = (cy + radius).min(height as f32 - 1.) as u32;
            for yy in y0..=y1 {
                for xx in x0..=x1 {
                    let distance = ((xx as f32 - cx).powi(2) + (yy as f32 - cy).powi(2)).sqrt();
                    if distance <= radius {
                        let alpha = (((radius - distance) / (radius * 0.15).max(1.)).clamp(0., 1.) * 255.).round() as u8;
                        let old = mask.get_pixel(xx, yy).0[0];
                        mask.put_pixel(xx, yy, image::Luma([if *r < 0. { old.min(255 - alpha) } else { old.max(alpha) }]));
                    }
                }
            }
        }
        Ok(mask)
    }
    fn update_live_preview(&mut self, result: &Path, ctx: &egui::Context) -> Result<(), String> {
        if !self.has_mask()
            || !super::valid_hex(&self.target_color)
            || !matches!(self.region_category.as_str(), "skin" | "hair" | "clothing" | "background" | "eye" | "texture")
            || (!self.region_intent.is_empty() && self.region_intent != "color")
        {
            self.live_image = None;
            self.live_texture = None;
            self.live_signature = None;
            return Ok(());
        }
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        result.hash(&mut hasher);
        self.target_color.hash(&mut hasher);
        self.region_category.hash(&mut hasher);
        self.region_intent.hash(&mut hasher);
        self.selection_revision.hash(&mut hasher);
        for [x, y, radius] in &self.strokes {
            x.to_bits().hash(&mut hasher);
            y.to_bits().hash(&mut hasher);
            radius.to_bits().hash(&mut hasher);
        }
        if let Some(path) = &self.external_mask {
            path.hash(&mut hasher);
        }
        let signature = hasher.finish();
        if self.live_signature == Some(signature) {
            return Ok(());
        }
        let mut output = image::ImageReader::open(result).map_err(|e| e.to_string())?.decode().map_err(|e| e.to_string())?.to_rgb8();
        let (width, height) = output.dimensions();
        if u64::from(width) * u64::from(height) > 120_000_000 {
            return Err("Live preview is limited to 120 megapixels.".into());
        }
        let source_path = self.source.as_ref().ok_or("Select the matching source page")?;
        if image::image_dimensions(source_path).map_err(|e| e.to_string())? != (width, height) {
            return Err("Source and result dimensions differ.".into());
        }
        let source = image::ImageReader::open(source_path).map_err(|e| e.to_string())?.decode().map_err(|e| e.to_string())?.to_luma8();
        let mask = self.build_mask(width, height)?;
        let values = self.target_color.trim().trim_start_matches('#');
        let parse = |offset| u8::from_str_radix(values.get(offset..offset + 2).unwrap_or("00"), 16).unwrap_or(0);
        let palette = [parse(0), parse(2), parse(4)];
        let target_y = 0.2126 * f64::from(palette[0]) + 0.7152 * f64::from(palette[1]) + 0.0722 * f64::from(palette[2]);
        for (x, y, pixel) in output.enumerate_pixels_mut() {
            let alpha = f64::from(mask.get_pixel(x, y)[0]) / 255.;
            let source_y = source.get_pixel(x, y)[0];
            if alpha == 0. || source_y < 48 {
                continue;
            }
            let current_y = 0.2126 * f64::from(pixel[0]) + 0.7152 * f64::from(pixel[1]) + 0.0722 * f64::from(pixel[2]);
            if current_y < 28. || current_y >= 250. {
                continue;
            }
            for channel in 0..3 {
                let colored = (f64::from(palette[channel]) + current_y - target_y).clamp(0., 255.);
                pixel[channel] = (f64::from(pixel[channel]) * (1. - alpha) + colored * alpha).round() as u8;
            }
        }
        let rgba = image::DynamicImage::ImageRgb8(output.clone()).thumbnail(1800, 1800).to_rgba8();
        self.live_texture = Some(ctx.load_texture(
            "live-palette-preview",
            egui::ColorImage::from_rgba_unmultiplied([rgba.width() as usize, rgba.height() as usize], rgba.as_raw()),
            egui::TextureOptions::LINEAR,
        ));
        self.live_image = Some(output);
        self.live_signature = Some(signature);
        ctx.request_repaint();
        Ok(())
    }
    pub fn initialize() -> Self {
        Self { crop_context: 0.2, detail_strength: 1., zoom: 1., split: 0.5, radius: 1.5, ..Self::default() }
    }
}
fn parse_hex_color(value: &str) -> Option<[u8; 3]> {
    if !super::valid_hex(value) {
        return None;
    }
    Some([u8::from_str_radix(value.get(1..3)?, 16).ok()?, u8::from_str_radix(value.get(3..5)?, 16).ok()?, u8::from_str_radix(value.get(5..7)?, 16).ok()?])
}
fn edit_string(ui: &mut egui::Ui, value: &mut Value, key: &str, label: &str) {
    ui.label(label);
    let mut text = value[key].as_str().unwrap_or("").to_owned();
    ui.add(egui::TextEdit::multiline(&mut text).desired_rows(2).desired_width(f32::INFINITY).char_limit(16000));
    value[key] = text.into();
}
fn validate_assignments(data: &Value) -> Result<(), String> {
    let panels = data["panels"].as_array().ok_or("Missing panels")?;
    if panels.is_empty() || panels.len() > 64 || panels.iter().any(|p| p["style"].as_str().is_none_or(|s| s.len() > 32000)) {
        return Err("Invalid panel instructions.".into());
    }
    for panel in panels {
        if let Some(people) = panel.get("vision_assignment").and_then(|v| v.get("people"))
            && people.as_array().is_none_or(|a| a.len() > 64 || a.iter().any(|p| !p.is_object()))
        {
            return Err("Invalid appearance list".into());
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_overflowing_or_missing_text() {
        let mut v = serde_json::json!({"width":100,"height":100,"regions":[{"x":90,"y":0,"width":20,"height":10,"selected":true,"translation":"ok"}]});
        assert!(validate_text(&v).is_err());
        v["regions"][0]["width"] = 10.into();
        assert!(validate_text(&v).is_ok());
        v["regions"][0]["translation"] = "".into();
        assert!(validate_text(&v).is_err());
    }
    #[test]
    fn painted_mask_uses_original_page_coordinates() -> Result<(), Box<dyn std::error::Error>> {
        let mut w = Workbench::initialize();
        w.strokes.push([0.5, 0.5, 0.05]);
        let path = std::env::temp_dir().join(format!("manga-mask-{}.png", std::process::id()));
        w.save_mask(&path, 100, 200)?;
        let mask = image::open(&path)?.to_luma8();
        assert_eq!(mask.get_pixel(50, 100).0, [255]);
        assert_eq!(mask.get_pixel(50, 115).0, [0]);
        std::fs::remove_file(path)?;
        Ok(())
    }
    #[test]
    fn eraser_removes_pixels_from_an_approved_selection() -> Result<(), Box<dyn std::error::Error>> {
        let mut w = Workbench::initialize();
        w.strokes = vec![[0.5, 0.5, 0.3], [0.5, 0.5, -0.1]];
        let file = std::env::temp_dir().join(format!("mangacolorai-eraser-{}.png", std::process::id()));
        w.save_mask(&file, 100, 100)?;
        let mask = image::open(&file)?.to_luma8();
        assert_eq!(mask.get_pixel(50, 50)[0], 0);
        assert_eq!(mask.get_pixel(70, 50)[0], 255);
        assert_eq!(mask.get_pixel(2, 2)[0], 0);
        std::fs::remove_file(&file)?;
        std::fs::remove_file(file.with_extension("bounds.json"))?;
        Ok(())
    }
}
