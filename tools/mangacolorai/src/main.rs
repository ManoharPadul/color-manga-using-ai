#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![deny(unsafe_code, clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[path = "../../shared/bindings.rs"]
mod bindings;
#[path = "../../shared/coordinates.rs"]
mod coordinates;
mod palette;
mod segmentation;
mod workbench;
mod worker;
use eframe::egui;
use serde::{Deserialize, Serialize};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc,
    time::Duration,
};

#[derive(Serialize, Deserialize, Clone, Default)]
struct Outfit {
    #[serde(default)]
    id: String,
    name: String,
    identify: String,
    colors: String,
    #[serde(default)]
    garments: Vec<Garment>,
}
#[derive(Serialize, Deserialize, Clone, Default)]
struct Garment {
    id: String,
    name: String,
    identify: String,
    color: String,
    #[serde(default)]
    pattern: String,
}
#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(default)]
struct SkinTones {
    base: String,
    shadow: String,
    highlight: String,
    undertone: String,
}
#[derive(Serialize, Deserialize, Clone)]
struct RegionColor {
    name: String,
    color: String,
}
fn valid_hex(value: &str) -> bool {
    value.len() == 7 && value.starts_with('#') && value.chars().skip(1).all(|c| c.is_ascii_hexdigit())
}
#[derive(Serialize, Deserialize, Clone)]
struct Person {
    id: String,
    name: String,
    identify: String,
    hair: String,
    eyes: String,
    skin: String,
    #[serde(default)]
    skin_tones: SkinTones,
    #[serde(default)]
    region_colors: Vec<RegionColor>,
    outfits: Vec<Outfit>,
}
impl Person {
    fn new(index: usize) -> Self {
        Self {
            id: format!("person-{index}"),
            name: format!("Person {index}"),
            identify: String::new(),
            hair: "natural dark brown".into(),
            eyes: "muted brown".into(),
            skin: "natural warm peach".into(),
            skin_tones: SkinTones::default(),
            region_colors: Vec::new(),
            outfits: Vec::new(),
        }
    }
}
#[derive(Serialize, Deserialize)]
struct Profiles {
    version: u32,
    characters: Vec<Person>,
}
fn validate_profiles(profiles: &[Person]) -> Result<(), String> {
    if profiles.len() > 20 {
        return Err("Use at most 20 character profiles.".into());
    }
    let mut ids = std::collections::HashSet::new();
    for p in profiles {
        if p.id.is_empty() || p.id.len() > 64 || !p.id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') || !ids.insert(&p.id) {
            return Err("Character IDs must be unique letters/numbers.".into());
        }
        for v in [&p.name, &p.identify, &p.hair, &p.eyes, &p.skin] {
            if v.trim().is_empty() || v.len() > 2000 {
                return Err(format!("Complete the identity and colors for {}.", p.name));
            }
        }
        for tone in [&p.skin_tones.base, &p.skin_tones.shadow, &p.skin_tones.highlight, &p.skin_tones.undertone] {
            if !tone.is_empty() && !valid_hex(tone) {
                return Err("Optional tones require #RRGGBB.".into());
            }
        }
        let mut names = std::collections::HashSet::new();
        if p.region_colors.len() > 32 {
            return Err("Use at most 32 named region colors.".into());
        }
        for color in &p.region_colors {
            if color.name.trim().is_empty() || color.name.len() > 80 || !names.insert(color.name.to_lowercase()) || !valid_hex(&color.color) {
                return Err("Named region colors need unique names and #RRGGBB values.".into());
            }
        }
        if p.outfits.len() > 20 {
            return Err("Use at most 20 outfit variants.".into());
        }
        let mut outfit_names = std::collections::HashSet::new();
        let mut outfit_ids = std::collections::HashSet::new();
        let mut garment_colors = std::collections::HashMap::new();
        for outfit in &p.outfits {
            if !outfit.id.is_empty() && (!outfit_ids.insert(&outfit.id) || !outfit.id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')) {
                return Err("Outfit IDs must be unique safe names within a character".into());
            }
            if outfit.garments.len() > 32 {
                return Err("At most 32 garments per outfit".into());
            }
            let mut garment_ids = std::collections::HashSet::new();
            for g in &outfit.garments {
                if g.id.is_empty()
                    || g.id.len() > 64
                    || !g.id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
                    || !garment_ids.insert(&g.id)
                    || g.name.trim().is_empty()
                    || g.identify.trim().is_empty()
                    || !valid_hex(&g.color)
                    || g.pattern.len() > 2000
                {
                    return Err("Garments need unique safe IDs, descriptions and #RRGGBB colors".into());
                }
                if let Some(old) = garment_colors.insert(&g.id, &g.color)
                    && !old.eq_ignore_ascii_case(&g.color)
                {
                    return Err("A reused garment ID must retain its approved color; use a different ID for a different garment".into());
                }
            }
            if !outfit_names.insert(outfit.name.to_lowercase()) {
                return Err("Each outfit needs a unique name within its character.".into());
            }
            for v in [&outfit.name, &outfit.identify, &outfit.colors] {
                if v.trim().is_empty() || v.len() > 2000 {
                    return Err(format!("Complete the outfit description and colors for {}.", p.name));
                }
            }
        }
    }
    Ok(())
}
fn first_hex(text: &str) -> Option<String> {
    text.as_bytes().windows(7).find_map(|bytes| std::str::from_utf8(bytes).ok().filter(|s| valid_hex(s)).map(str::to_owned))
}
fn region_project(root: &Path, source: &Path) -> PathBuf {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in source.to_string_lossy().as_bytes() {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3);
    }
    root.join(format!(".local-ai/mangacolorai/region-projects/{hash:016x}.json"))
}
fn natural_key(path: &Path) -> String {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let mut out = String::new();
    let mut digits = String::new();
    for c in name.chars() {
        if c.is_ascii_digit() {
            digits.push(c);
        } else {
            if !digits.is_empty() {
                out.push_str(&format!("{digits:0>20}"));
                digits.clear();
            }
            out.push(c.to_ascii_lowercase());
        }
    }
    if !digits.is_empty() {
        out.push_str(&format!("{digits:0>20}"));
    }
    out
}
fn preview_image(path: &Path) -> Result<image::RgbaImage, String> {
    let (w, h) = image::image_dimensions(path).map_err(|e| e.to_string())?;
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > 120_000_000 {
        return Err("Preview exceeds 120 megapixels.".into());
    }
    let mut reader = image::ImageReader::open(path).map_err(|e| e.to_string())?.with_guessed_format().map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(768_000_000);
    reader.limits(limits);
    reader.decode().map(|v| v.thumbnail(4096, 4096).to_rgba8()).map_err(|e| e.to_string())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum TextMode {
    Off,
    Protect,
    Replace,
}
impl TextMode {
    fn label(self) -> &'static str {
        match self {
            Self::Off => "Off - no text processing",
            Self::Protect => "Protect original lettering (detect only)",
            Self::Replace => "Remove and replace / translate text",
        }
    }
    fn flag(self) -> Option<&'static str> {
        match self {
            Self::Off => None,
            Self::Protect => Some("-PreserveText"),
            Self::Replace => Some("-TextWorkflow"),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    input: String,
    style: String,
    model: String,
    scene: String,
    text: bool,
    language: String,
    review: bool,
    retries: u8,
    vision_config: String,
    steps: u32,
    seed: u32,
    megapixels: f64,
    vision_model: String,
    vision_projector: String,
    reference: String,
    characters: Vec<Person>,
    preserve_text: bool,
    source_shadows: f64,
    original_ink: bool,
    strict_ink: bool,
    quality_report: bool,
    second_pass: bool,
    auto_repair: bool,
    missing_sensitivity: f64,
    max_color_repairs: u8,
    match_characters: bool,
    review_before_color: bool,
    output_directory: String,
    #[serde(default)]
    output_layout_version: u8,
    resume: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            input: String::new(),
            style: String::new(),
            model: "4B FP8".into(),
            scene: "Source".into(),
            text: false,
            language: "source".into(),
            review: false,
            retries: 0,
            vision_config: String::new(),
            steps: 4,
            seed: 42,
            megapixels: 1.5,
            vision_model: String::new(),
            vision_projector: String::new(),
            reference: String::new(),
            characters: Vec::new(),
            preserve_text: true,
            source_shadows: 0.0,
            original_ink: false,
            strict_ink: false,
            quality_report: true,
            second_pass: true,
            auto_repair: false,
            missing_sensitivity: 0.5,
            max_color_repairs: 3,
            match_characters: true,
            review_before_color: false,
            output_directory: String::new(),
            output_layout_version: 2,
            resume: false,
        }
    }
}
impl Settings {
    fn text_mode(&self) -> TextMode {
        if self.text {
            TextMode::Replace
        } else if self.preserve_text {
            TextMode::Protect
        } else {
            TextMode::Off
        }
    }
    fn set_text_mode(&mut self, mode: TextMode) {
        self.text = mode == TextMode::Replace;
        self.preserve_text = mode == TextMode::Protect;
    }
    fn fast_color_only(&mut self) {
        self.set_text_mode(TextMode::Off);
        self.match_characters = false;
        self.review = false;
        self.retries = 0;
        self.original_ink = false;
        self.source_shadows = 0.;
    }
}

enum Event {
    Log(String),
    Done(bool),
}
fn add_fidelity_options(command: &mut Command, settings: &Settings) {
    if settings.original_ink {
        command.arg("-OriginalInk");
        if settings.strict_ink {
            command.arg("-StrictInk");
        }
    }
    if settings.second_pass {
        command.arg("-SecondPass");
    }
    if settings.auto_repair {
        command.arg("-AutoRepair");
    }
    command.arg("-MissingColorSensitivity").arg(settings.missing_sensitivity.to_string()).arg("-MaxColorRepairs").arg(settings.max_color_repairs.to_string());
    if settings.quality_report {
        command.arg("-QualityReport");
    }
}
struct Studio {
    review_needed: bool,
    root: PathBuf,
    settings: Settings,
    pages: Vec<PathBuf>,
    preview_path: Option<PathBuf>,
    texture: Option<egui::TextureHandle>,
    logs: Vec<String>,
    receiver: Option<mpsc::Receiver<Event>>,
    busy: bool,
    status: String,
    result: Option<PathBuf>,
    view_result: bool,
    workbench: workbench::Workbench,
    control_file: Option<PathBuf>,
    paused: bool,
    current_source: Option<PathBuf>,
    results: std::collections::BTreeMap<PathBuf, Vec<PathBuf>>,
    sampler: Option<palette::Sampler>,
    confirm_exit: bool,
    close_when_finished: bool,
}
impl Studio {
    fn new(cc: &eframe::CreationContext<'_>, root: PathBuf) -> Self {
        let mut visuals = egui::Visuals::dark();
        visuals.selection.bg_fill = egui::Color32::from_rgb(157, 67, 97);
        visuals.panel_fill = egui::Color32::from_rgb(25, 24, 29);
        cc.egui_ctx.set_visuals(visuals);
        install_system_fonts(&cc.egui_ctx);
        let settings_path = root.join(".local-ai/mangacolorai/settings.json");
        let mut settings = std::fs::read(settings_path).ok().and_then(|v| serde_json::from_slice::<Settings>(&v).ok()).unwrap_or_default();
        if settings.output_layout_version < 2 {
            let name = Path::new(&settings.output_directory).file_name().unwrap_or_default().to_string_lossy();
            if name.strip_prefix("MangaColorAI-").is_some_and(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit())) {
                settings.output_directory.clear();
            }
            settings.resume = false;
            settings.output_layout_version = 2;
        }
        if settings.style.is_empty() {
            settings.style = root.join("manga-tested-style.txt").to_string_lossy().into_owned();
        }
        if settings.vision_config.is_empty() {
            settings.vision_config = root.join(".local-ai/review-model.json").to_string_lossy().into_owned();
        }
        let mut studio = Self {
            review_needed: false,
            root,
            settings,
            pages: Vec::new(),
            preview_path: None,
            texture: None,
            logs: Vec::new(),
            receiver: None,
            busy: false,
            status: "Ready · local processing".into(),
            result: None,
            view_result: false,
            workbench: workbench::Workbench::initialize(),
            control_file: None,
            paused: false,
            current_source: None,
            results: std::collections::BTreeMap::new(),
            sampler: None,
            confirm_exit: false,
            close_when_finished: false,
        };
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        for pair in args.as_chunks::<2>().0 {
            if let (Some(flag), Some(path)) = (pair.first().and_then(|v| v.to_str()), pair.get(1)) {
                let path = PathBuf::from(path);
                match flag {
                    "--source" => studio.select_input(path, &cc.egui_ctx),
                    "--result" => {
                        studio.result = Some(path.clone());
                        studio.workbench.attempts.push(path);
                        studio.view_result = true;
                    }
                    "--review" => {
                        let assignments = workbench::load_document(&path).is_ok_and(|v| v.get("panels").is_some());
                        studio.workbench.open_review(path, assignments);
                    }
                    _ => {}
                }
            }
        }
        studio
    }
    fn select_input(&mut self, path: PathBuf, ctx: &egui::Context) {
        self.settings.input = path.to_string_lossy().into_owned();
        self.pages = if path.is_dir() {
            std::fs::read_dir(&path).map(|entries| entries.filter_map(Result::ok).map(|v| v.path()).filter(|p| supported(p)).collect()).unwrap_or_default()
        } else {
            vec![path]
        };
        self.pages.sort_by_key(|p| natural_key(p));
        self.view_result = false;
        if let Some(p) = self.pages.first().cloned() {
            self.workbench.set_source(p.clone());
            if let Ok(data) = workbench::load_document(&region_project(&self.root, &p))
                && data["source"].as_str() == p.to_str()
            {
                self.workbench.approved_regions = data["regions"].as_array().filter(|r| r.len() <= 32).cloned().unwrap_or_default();
            }
            self.result = None;
            self.load_preview(p, ctx);
        }
    }
    fn load_preview(&mut self, path: PathBuf, ctx: &egui::Context) {
        self.preview_path = Some(path.clone());
        match preview_image(&path) {
            Ok(image) => {
                let size = [image.width() as usize, image.height() as usize];
                self.texture = Some(ctx.load_texture("page", egui::ColorImage::from_rgba_unmultiplied(size, image.as_raw()), egui::TextureOptions::LINEAR));
            }
            Err(e) => {
                self.texture = None;
                self.status = format!("Preview unavailable: {e}. Processing uses the broader image decoder.");
            }
        }
    }
    fn run(&mut self) {
        if self.busy {
            return;
        }
        if !Path::new(&self.settings.input).exists() {
            self.status = "Choose an image or folder first.".into();
            return;
        }
        if !Path::new(&self.settings.style).is_file() {
            self.status = "Choose an existing color-style text file.".into();
            return;
        }
        if (self.settings.review || (!self.settings.characters.is_empty() && self.settings.match_characters))
            && (!self.settings.vision_model.is_empty() || !self.settings.vision_projector.is_empty())
        {
            if !Path::new(&self.settings.vision_model).is_file() || !Path::new(&self.settings.vision_projector).is_file() {
                self.status = "Select both a vision GGUF and its matching projector.".into();
                return;
            }
            let path = self.root.join(".local-ai/mangacolorai/selected-vision.json");
            let data = serde_json::json!({"model":self.settings.vision_model,"projector":self.settings.vision_projector});
            match serde_json::to_vec_pretty(&data).ok().and_then(|v| std::fs::write(&path, v).ok()) {
                Some(()) => self.settings.vision_config = path.to_string_lossy().into_owned(),
                None => {
                    self.status = "Could not save vision configuration.".into();
                    return;
                }
            }
        }
        let (mut command, root) = (Command::new("powershell.exe"), self.root.clone());
        command
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(root.join("scripts/local-manga/Studio-Run.ps1"))
            .arg("-InputPath")
            .arg(&self.settings.input)
            .arg("-Model")
            .arg(&self.settings.model)
            .arg("-ProcessingMode")
            .arg("FullPage")
            .arg("-Scene")
            .arg(&self.settings.scene)
            .arg("-StyleFile")
            .arg(&self.settings.style);
        command
            .arg("-Steps")
            .arg(self.settings.steps.to_string())
            .arg("-Seed")
            .arg(self.settings.seed.to_string())
            .arg("-Megapixels")
            .arg(self.settings.megapixels.to_string());
        command.arg("-SourceShadows").arg(if self.settings.original_ink { "0".into() } else { self.settings.source_shadows.to_string() });
        add_fidelity_options(&mut command, &self.settings);
        if let Some(flag) = self.settings.text_mode().flag() {
            command.arg(flag);
        }
        if !self.settings.characters.is_empty() {
            if let Err(error) = validate_profiles(&self.settings.characters) {
                self.status = error;
                return;
            }
            if self.settings.match_characters {
                command.arg("-AssignCharacters");
            }
            command.arg("-ReviewConfig").arg(&self.settings.vision_config);
            let profile = root.join(".local-ai/mangacolorai/characters.json");
            let data = serde_json::json!({"version":1,"characters":self.settings.characters});
            match serde_json::to_vec_pretty(&data).ok().and_then(|v| std::fs::write(&profile, v).ok()) {
                Some(()) => {
                    command.arg("-CharacterFile").arg(profile);
                }
                None => {
                    self.status = "Could not save character profiles.".into();
                    return;
                }
            }
        }
        if self.settings.text {
            command.arg("-TargetLanguage").arg(&self.settings.language);
        }
        if self.settings.review {
            command.arg("-Review").arg("-Retries").arg(self.settings.retries.to_string());
            if self.settings.characters.is_empty() {
                command.arg("-ReviewConfig").arg(&self.settings.vision_config);
            }
        }
        if !self.settings.reference.is_empty() {
            command.arg("-ReferenceImage").arg(&self.settings.reference);
        }
        let out = if !self.settings.resume || self.settings.output_directory.is_empty() {
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
            let name = output_folder_name(Path::new(&self.settings.input), Path::new(&self.settings.input).is_dir(), stamp);
            let path = root.join("manga-output").join(name);
            self.settings.output_directory = path.to_string_lossy().into_owned();
            path
        } else {
            PathBuf::from(&self.settings.output_directory)
        };
        if let Err(e) = std::fs::create_dir_all(&out) {
            self.status = e.to_string();
            return;
        }
        let control = out.join("control.txt");
        if let Err(e) = std::fs::write(&control, b"run") {
            self.status = e.to_string();
            return;
        }
        self.control_file = Some(control.clone());
        self.paused = false;
        command.arg("-OutputDirectory").arg(out).arg("-ControlFile").arg(control);
        if self.settings.resume {
            command.arg("-Resume");
        }
        if self.settings.review_before_color {
            command.arg("-ReviewBeforeColor");
        }
        self.launch_worker(command, root);
    }
    fn launch_worker(&mut self, mut command: Command, root: PathBuf) {
        command.arg("-OwnerProcessId").arg(std::process::id().to_string());
        command.current_dir(&root);
        #[cfg(windows)]
        command.creation_flags(0x08000000);
        let (tx, rx) = mpsc::channel();
        self.receiver = Some(rx);
        self.busy = true;
        self.review_needed = false;
        self.logs.clear();
        self.status = "Processing locally…".into();
        let settings_path = root.join(".local-ai/mangacolorai/settings.json");
        if let Ok(bytes) = serde_json::to_vec_pretty(&self.settings) {
            if let Some(parent) = settings_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(settings_path, bytes);
        }
        std::thread::spawn(move || {
            let success = match worker::run(command, &root, &tx) {
                Ok(success) => success,
                Err(e) => {
                    let _ = tx.send(Event::Log(e.to_string()));
                    false
                }
            };
            let _ = tx.send(Event::Done(success));
        });
    }

    fn register_region(&mut self) {
        self.workbench.register_region = false;
        let (Some(source), Some(colored)) = (self.workbench.source.clone(), self.result.clone()) else { return };
        let result = (|| -> Result<(), String> {
            if self.workbench.approved_regions.len() >= 32 {
                return Err("Use at most 32 approved regions per page.".into());
            }
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
            let directory = self.root.join(format!("manga-output/region-{stamp}"));
            std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
            let (w, h) = image::image_dimensions(&colored).map_err(|e| e.to_string())?;
            let mask = directory.join("selection.png");
            self.workbench.save_mask(&mask, w, h)?;
            let intent = if matches!(self.workbench.region_category.as_str(), "text" | "intentional_uncolored") {
                "exclude"
            } else if self.workbench.region_intent.is_empty() {
                "color"
            } else {
                &self.workbench.region_intent
            };
            let color = if valid_hex(&self.workbench.target_color) { Some(&self.workbench.target_color) } else { None };
            let region = serde_json::json!({"id":format!("region-{}",self.workbench.approved_regions.len()+1),"mask":mask,"category":self.workbench.region_category,"intent":intent,"color":color,"palette_key":self.workbench.palette_key,"confidence":1.0});
            self.workbench.approved_regions.push(region);
            let path = region_project(&self.root, &source);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let data = serde_json::json!({"version":1,"source":source,"width":w,"height":h,"regions":self.workbench.approved_regions});
            std::fs::write(&path, serde_json::to_vec_pretty(&data).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            self.workbench.message = format!("Approved mask saved: {}", path.display());
            Ok(())
        })();
        if let Err(error) = result {
            self.status = error;
        }
    }
    fn save_live_image(&mut self, ctx: &egui::Context) {
        self.workbench.save_live_requested = false;
        let Some(image) = self.workbench.live_image.as_ref() else {
            self.status = "Paint a region and choose a category and saved color first.".into();
            return;
        };
        let default_name = self
            .result
            .as_ref()
            .and_then(|p| p.file_stem())
            .map(|s| format!("{}-color-edited.png", s.to_string_lossy()))
            .unwrap_or_else(|| "manga-color-edited.png".into());
        let Some(path) = rfd::FileDialog::new().add_filter("PNG image", &["png"]).set_file_name(default_name).save_file() else { return };
        let same_target = |left: &Path, right: &Path| {
            let canonical_left = std::fs::canonicalize(left).unwrap_or_else(|_| left.to_path_buf());
            let canonical_right = std::fs::canonicalize(right).unwrap_or_else(|_| right.to_path_buf());
            canonical_left.to_string_lossy().eq_ignore_ascii_case(&canonical_right.to_string_lossy())
        };
        if self.workbench.source.as_ref().is_some_and(|source| same_target(source, &path))
            || self.result.as_ref().is_some_and(|result| same_target(result, &path))
        {
            self.status = "Choose a new PNG path so the source and current result stay safe.".into();
            return;
        }
        if let Err(error) = image.save_with_format(&path, image::ImageFormat::Png) {
            self.status = format!("Could not save PNG: {error}");
            return;
        }
        self.result = Some(path.clone());
        self.workbench.attempts.push(path.clone());
        if let Some(source) = self.workbench.source.clone() {
            self.results.entry(source).or_default().push(path.clone());
        }
        self.view_result = true;
        self.load_preview(path.clone(), ctx);
        self.status = format!("Saved edited image: {} · mask kept for another correction", path.display());
    }
    fn cpu_region_action(&mut self, kind: &str) {
        if self.workbench.pending_candidate.is_some() {
            self.status = "Accept or reject the current candidate first.".into();
            self.workbench.detail_requested = false;
            self.workbench.recolor_requested = false;
            self.workbench.quality_requested = false;
            return;
        }
        let analyze = kind == "quality";
        let detail = kind == "detail";
        self.workbench.detail_requested = false;
        self.workbench.quality_requested = false;
        self.workbench.recolor_requested = false;
        let (Some(source), Some(colored)) = (self.workbench.source.clone(), self.result.clone()) else { return };
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let directory = self.root.join(format!("manga-output/diagnostic-{stamp}"));
        let prepared = (|| -> Result<PathBuf, String> {
            std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
            let (w, h) = image::image_dimensions(&colored).map_err(|e| e.to_string())?;
            let mask = directory.join("selection.png");
            if !analyze || (self.workbench.paint && !self.workbench.analyze_approved) {
                self.workbench.save_mask(&mask, w, h)?;
            }
            if analyze && self.workbench.analyze_approved {
                let data = serde_json::json!({"version":1,"regions":self.workbench.approved_regions});
                std::fs::write(directory.join("regions.json"), serde_json::to_vec_pretty(&data).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            } else if analyze && self.workbench.paint {
                let intent = if self.workbench.region_intent.is_empty() { "color" } else { &self.workbench.region_intent };
                let color = if valid_hex(&self.workbench.target_color) { Some(&self.workbench.target_color) } else { None };
                let data = serde_json::json!({"version":1,"regions":[{"id":"painted-region","mask":"selection.png","intent":intent,"color":color,"category":self.workbench.region_category,"palette_key":self.workbench.palette_key,"confidence":1.0}]});
                std::fs::write(directory.join("regions.json"), serde_json::to_vec_pretty(&data).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            }
            Ok(mask)
        })();
        let mask = match prepared {
            Ok(v) => v,
            Err(e) => {
                self.status = e;
                return;
            }
        };
        let mut command = Command::new("powershell.exe");
        command
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(self.root.join(if analyze {
                "scripts/local-manga/Studio-Quality.ps1"
            } else if detail {
                "scripts/local-manga/Studio-Detail.ps1"
            } else {
                "scripts/local-manga/Studio-PaletteRepair.ps1"
            }))
            .arg("-Source")
            .arg(source)
            .arg("-Colored")
            .arg(colored)
            .arg("-OutputDirectory")
            .arg(&directory);
        if analyze {
            command.arg("-Sensitivity").arg(self.settings.missing_sensitivity.to_string());
            if self.workbench.paint || self.workbench.analyze_approved {
                command.arg("-Regions").arg(directory.join("regions.json"));
            }
        } else if detail {
            command
                .arg("-Mask")
                .arg(mask)
                .arg("-Mode")
                .arg(if self.workbench.detail_mode.is_empty() { "geometry" } else { &self.workbench.detail_mode })
                .arg("-Strength")
                .arg(self.workbench.detail_strength.to_string());
        } else {
            command.arg("-Mask").arg(mask).arg("-Color").arg(&self.workbench.target_color).arg("-Category").arg(if self.workbench.region_category.is_empty() {
                "unspecified"
            } else {
                &self.workbench.region_category
            });
        }
        self.current_source = self.workbench.source.clone();
        self.control_file = None;
        self.launch_worker(command, self.root.clone());
    }
    fn repair(&mut self) {
        self.workbench.repair_requested = false;
        let (Some(source), Some(colored)) = (self.workbench.source.clone(), self.result.clone()) else { return };
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        let directory = self.root.join(format!("manga-output/repair-{stamp}"));
        let prepared = (|| -> Result<(PathBuf, PathBuf), String> {
            std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
            let (width, height) = image::image_dimensions(&colored).map_err(|e| e.to_string())?;
            let mask = directory.join("selection.png");
            self.workbench.save_mask(&mask, width, height)?;
            let style = directory.join("repair-style.txt");
            let original = std::fs::read_to_string(&self.settings.style).map_err(|e| e.to_string())?;
            std::fs::write(
                &style,
                format!(
                    "{original}\nCorrect the selected existing region's colors: {}; approved selected color {}. Preserve all original drawing geometry.",
                    self.workbench.repair_prompt, self.workbench.target_color
                ),
            )
            .map_err(|e| e.to_string())?;
            Ok((mask, style))
        })();
        let (mask, style) = match prepared {
            Ok(v) => v,
            Err(e) => {
                self.status = e;
                return;
            }
        };
        let mut command = Command::new("powershell.exe");
        command
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(self.root.join("scripts/local-manga/Studio-Repair.ps1"))
            .arg("-Source")
            .arg(source)
            .arg("-Colored")
            .arg(colored)
            .arg("-Mask")
            .arg(mask)
            .arg("-StyleFile")
            .arg(style)
            .arg("-Model")
            .arg(&self.settings.model)
            .arg("-Steps")
            .arg(self.settings.steps.to_string())
            .arg("-Seed")
            .arg(self.settings.seed.to_string())
            .arg("-Megapixels")
            .arg(self.settings.megapixels.to_string())
            .arg("-OutputDirectory")
            .arg(directory);
        command.arg("-Context").arg(self.workbench.crop_context.to_string());
        if valid_hex(&self.workbench.target_color) {
            command.arg("-ExpectedColor").arg(&self.workbench.target_color);
        }
        if self.settings.original_ink {
            command.arg("-RestoreSourceInk");
        }
        self.current_source = self.workbench.source.clone();
        self.control_file = None;
        self.launch_worker(command, self.root.clone());
    }
}
fn output_folder_name(input: &Path, folder: bool, nonce: u128) -> String {
    let stem = if folder { input.file_name() } else { input.file_stem() }.unwrap_or_default().to_string_lossy();
    let stem = if stem.is_empty() { "Manga" } else { &stem };
    format!("{stem}-{:08x}", nonce & 0xffff_ffff)
}
fn install_system_fonts(ctx: &egui::Context) {
    // System-installed fonts stay on the machine; no font files are bundled or copied.
    let directory = std::env::var_os("WINDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:/Windows")).join("Fonts");
    let mut fonts = egui::FontDefinitions::default();
    let mut total = 0_u64;
    for name in ["Nirmala.ttc", "msyh.ttc", "malgun.ttf", "YuGothM.ttc", "seguisym.ttf"] {
        let path = directory.join(name);
        let Ok(metadata) = std::fs::metadata(&path) else { continue };
        if metadata.len() > 24_000_000 || total.saturating_add(metadata.len()) > 64_000_000 {
            continue;
        }
        if let Ok(bytes) = std::fs::read(path) {
            total = total.saturating_add(bytes.len() as u64);
            fonts.font_data.insert(name.into(), egui::FontData::from_owned(bytes).into());
            for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
                fonts.families.entry(family).or_default().push(name.into());
            }
        }
    }
    ctx.set_fonts(fonts);
}
fn supported(path: &Path) -> bool {
    path.extension().and_then(|v| v.to_str()).is_some_and(|v| {
        matches!(
            v.to_ascii_lowercase().as_str(),
            "png" | "jpg" | "jpeg" | "webp" | "bmp" | "tif" | "tiff" | "gif" | "tga" | "avif" | "heic" | "heif" | "jxl" | "jp2" | "ppm" | "pgm" | "pbm" | "pnm"
        )
    }) && !path.file_name().and_then(|v| v.to_str()).is_some_and(|v| v.contains("-mask."))
}
impl eframe::App for Studio {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let context = ui.ctx().clone();
        let ctx = &context;
        if self.busy && ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.confirm_exit = true;
        }
        if self.confirm_exit {
            egui::Window::new("A conversion is active").show(ctx, |ui| {
                ui.label("Finish the current stage before closing so completed pages and reports are saved.");
                if ui.button("Keep processing").clicked() {
                    self.confirm_exit = false;
                }
                if self.control_file.is_some()
                    && ui.button("Cancel after stage, then close").clicked()
                    && let Some(path) = &self.control_file
                {
                    match std::fs::write(path, b"cancel") {
                        Ok(()) => {
                            self.close_when_finished = true;
                            self.confirm_exit = false;
                        }
                        Err(e) => self.status = e.to_string(),
                    }
                }
            });
        }
        let events: Vec<_> = self.receiver.as_ref().map(|r| r.try_iter().collect()).unwrap_or_default();
        for event in events {
            match event {
                Event::Log(line) => {
                    if line.starts_with("[CANCELED]") {
                        self.status = "Canceled at safe boundary; completed pages kept".into();
                    }
                    if let Some(path) = line.strip_prefix("[PAGE_SOURCE] ") {
                        let source = PathBuf::from(path.trim());
                        if self.workbench.source.as_ref() != Some(&source) {
                            self.workbench.set_source(source.clone());
                            self.result = None;
                            self.view_result = false;
                            self.load_preview(source.clone(), ctx);
                        }
                        self.current_source = Some(source);
                    }
                    for (prefix, assignments) in [("[TEXT_REVIEW] ", false), ("[ASSIGNMENT_REVIEW] ", true)] {
                        if let Some(path) = line.strip_prefix(prefix) {
                            self.workbench.open_review(PathBuf::from(path.trim()), assignments);
                            self.status = "Waiting for your review".into();
                        }
                    }
                    if let Some(path) = line.strip_prefix("[QUALITY] ") {
                        let path = PathBuf::from(path.trim());
                        match workbench::load_document(&path) {
                            Ok(data) => {
                                let automatic = if data["pass"].as_u64() == Some(2) { Some(&data) } else { data.get("automatic") };
                                if automatic
                                    .and_then(|a| a["approved_regions"].as_array())
                                    .is_some_and(|regions| regions.iter().any(|r| r["suspected_pixels"].as_u64().unwrap_or(0) > 0 && r["accepted"] != true))
                                {
                                    self.review_needed = true;
                                }
                                self.workbench.protection_texture =
                                    automatic.and_then(|a| a["unified_protection"].as_str()).and_then(|p| preview_image(Path::new(p)).ok()).map(|image| {
                                        ctx.load_texture(
                                            "pass2-protection",
                                            egui::ColorImage::from_rgba_unmultiplied([image.width() as usize, image.height() as usize], image.as_raw()),
                                            egui::TextureOptions::LINEAR,
                                        )
                                    });
                                self.workbench.suggestions = automatic
                                    .and_then(|a| a["proposals"].as_array())
                                    .map(|a| a.iter().filter(|r| r["mask"].as_str().is_some()).cloned().collect())
                                    .unwrap_or_default();
                                self.workbench.message = if let Some(report) = automatic {
                                    format!(
                                        "CPU pass 2: {} suggestions · {} repairs attempted / {} accepted / {} rejected · {} changed pixels. Uncertain regions require an approved category and palette.",
                                        report["proposals"].as_array().map_or(0, Vec::len),
                                        report["repairs_attempted"],
                                        report["repairs_accepted"],
                                        report["repairs_rejected"],
                                        report["changed_pixels"]
                                    )
                                } else {
                                    format!(
                                        "Coverage: {} · missing: {} · palette mismatch: {} · protection conflicts: {}. Inspect source geometry before accepting.",
                                        data["coverage_percent"],
                                        data["suspected_uncolored_pixels"],
                                        data["palette_mismatch_pixels"],
                                        data["protection_conflict_pixels"]
                                    )
                                };
                                self.workbench.automatic_overlay = automatic.and_then(|a| a["overlay"].as_str()).is_some();
                                let overlay = automatic
                                    .and_then(|a| a["overlay"].as_str())
                                    .map(PathBuf::from)
                                    .or_else(|| path.parent().map(|p| p.join("missing-color-heatmap.png")));
                                self.workbench.quality_texture = overlay.and_then(|p| preview_image(&p).ok()).map(|image| {
                                    ctx.load_texture(
                                        "coverage-heatmap",
                                        egui::ColorImage::from_rgba_unmultiplied([image.width() as usize, image.height() as usize], image.as_raw()),
                                        egui::TextureOptions::LINEAR,
                                    )
                                });
                            }
                            Err(error) => self.workbench.message = error,
                        }
                        self.workbench.quality_path = Some(path);
                    }
                    if let Some(path) = line.strip_prefix("[CANDIDATE] ") {
                        self.workbench.pending_candidate = Some(PathBuf::from(path.trim()));
                        self.workbench.candidate_base = self.result.clone();
                        self.workbench.candidate_previewing = false;
                        self.workbench.candidate_reviewable = false;
                    }
                    if line.starts_with("[COLOR_REVIEW]") {
                        self.review_needed = true;
                    }
                    if line.starts_with("[REVIEWABLE]") {
                        self.workbench.candidate_reviewable = true;
                    }
                    if let Some(path) = line.strip_prefix("[RESULT] ") {
                        self.workbench.pending_candidate = None;
                        self.workbench.candidate_base = None;
                        self.workbench.candidate_previewing = false;
                        self.result = Some(PathBuf::from(path.trim()));
                        if let Some(source) = self.current_source.clone() {
                            let attempts = self.results.entry(source.clone()).or_default();
                            attempts.push(PathBuf::from(path.trim()));
                            self.workbench.set_source(source);
                            self.workbench.attempts = attempts.clone();
                        }
                        self.view_result = true;
                        self.load_preview(PathBuf::from(path.trim()), ctx);
                    }
                    self.logs.push(line);
                    if self.logs.len() > 3000 {
                        self.logs.drain(..1000);
                    }
                }
                Event::Done(ok) => {
                    self.busy = false;
                    self.workbench.review = None;
                    if self.close_when_finished {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                    self.status = if self.status.starts_with("Canceled") {
                        "Canceled at safe boundary; completed pages kept"
                    } else if ok && self.review_needed {
                        "Finished with unresolved color issues · inspect the report"
                    } else if ok {
                        "Finished · review the result before accepting"
                    } else {
                        "Run failed · completed files are kept; see log"
                    }
                    .into();
                }
            }
        }
        self.workbench.show_review(ctx);
        if let Some(sampler) = self.sampler.as_mut()
            && let Some((field, hex)) = sampler.show(ctx)
        {
            if let Some(person) = self.settings.characters.iter_mut().find(|p| p.id == sampler.person_id) {
                let color = format!("consistent base color {hex}; retain original ink, shading and highlights");
                match field.as_str() {
                    "hair" => person.hair = color,
                    "eyes" => person.eyes = format!("both irises {hex}; keep original pupils, highlights and closed eyes"),
                    "skin" => person.skin = color,
                    _ => {}
                }
            }
            self.sampler = None;
        }
        if self.workbench.accept_candidate && !self.busy {
            self.workbench.accept_candidate = false;
            if let Some(path) = self.workbench.pending_candidate.clone() {
                self.result = Some(path.clone());
                self.workbench.candidate_previewing = true;
                self.load_preview(path, ctx);
            }
        }
        if self.workbench.commit_candidate && !self.busy {
            self.workbench.commit_candidate = false;
            if self.workbench.candidate_reviewable
                && let Some(path) = self.workbench.pending_candidate.take()
            {
                self.result = Some(path.clone());
                self.workbench.attempts.push(path.clone());
                self.workbench.candidate_base = None;
                self.workbench.candidate_previewing = false;
                self.load_preview(path, ctx);
            }
        }
        if self.workbench.reject_candidate && !self.busy {
            self.workbench.reject_candidate = false;
            if let Some(path) = self.workbench.candidate_base.take() {
                self.result = Some(path.clone());
                self.load_preview(path, ctx);
            }
            self.workbench.pending_candidate = None;
            self.workbench.candidate_previewing = false;
        }
        if self.workbench.register_region && !self.busy {
            self.register_region();
        }
        if self.workbench.detail_requested && !self.busy {
            self.cpu_region_action("detail");
        }
        if self.workbench.quality_requested && !self.busy {
            self.cpu_region_action("quality");
        }
        if self.workbench.recolor_requested && !self.busy {
            self.cpu_region_action("recolor");
        }
        if self.workbench.repair_requested && !self.busy {
            self.repair();
        }
        egui::Panel::top("header").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("MangaColorAI");
                ui.checkbox(&mut self.settings.quality_report, "CPU quality report");
                ui.separator();
                ui.label("Local manga workspace");
                if self.busy {
                    ui.spinner();
                    if self.control_file.is_some() && ui.button(if self.paused { "Resume" } else { "Pause after stage" }).clicked() {
                        let command = if self.paused { "run" } else { "pause" };
                        if let Some(path) = &self.control_file {
                            match std::fs::write(path, command) {
                                Ok(()) => self.paused = !self.paused,
                                Err(e) => self.status = e.to_string(),
                            }
                        }
                    }
                    if self.control_file.is_some()
                        && ui.button("Cancel after stage").clicked()
                        && let Some(path) = &self.control_file
                    {
                        match std::fs::write(path, b"cancel") {
                            Ok(()) => self.status = "Cancel requested; finishing current stage".into(),
                            Err(e) => self.status = e.to_string(),
                        }
                    }
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(&self.status);
                });
            });
        });
        egui::Panel::left("pages").default_size(210.).show(ui, |ui| {
            ui.heading("Pages");
            ui.add_space(8.);
            ui.add_enabled_ui(!self.busy, |ui| {
                if ui.button("＋ Open image").clicked()
                    && let Some(p) = rfd::FileDialog::new()
                        .add_filter("Images", &["png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "gif", "tga", "avif", "heic", "heif", "jxl"])
                        .pick_file()
                {
                    self.select_input(p, ctx);
                }
                if ui.button("＋ Open folder").clicked()
                    && let Some(p) = rfd::FileDialog::new().pick_folder()
                {
                    self.select_input(p, ctx);
                }
            });
            if ui.add_enabled(!self.busy && self.workbench.source.is_some(), egui::Button::new("Open colored result…")).clicked()
                && let Some(p) = rfd::FileDialog::new().add_filter("PNG", &["png"]).pick_file()
            {
                self.result = Some(p.clone());
                self.workbench.attempts.push(p);
                self.view_result = true;
            }
            if ui.add_enabled(!self.busy, egui::Button::new("Open text / panel review…")).clicked()
                && let Some(p) = rfd::FileDialog::new().add_filter("JSON", &["json"]).pick_file()
            {
                let assignments = workbench::load_document(&p).is_ok_and(|v| v.get("panels").is_some());
                self.workbench.open_review(p, assignments);
            }
            ui.separator();
            ui.label(format!("{} pages", self.pages.len()));
            egui::ScrollArea::vertical().show(ui, |ui| {
                let mut chosen = None;
                for p in &self.pages {
                    if ui.selectable_label(self.preview_path.as_ref() == Some(p), p.file_name().unwrap_or_default().to_string_lossy()).clicked() {
                        chosen = Some(p.clone());
                    }
                }
                if let Some(p) = chosen {
                    self.workbench.set_source(p.clone());
                    self.workbench.attempts = self.results.get(&p).cloned().unwrap_or_default();
                    self.result = self.workbench.attempts.last().cloned();
                    self.view_result = self.result.is_some();
                    self.load_preview(p, ctx);
                }
            });
        });
        egui::Panel::right("settings").default_size(300.).show(ui, |ui| {
            ui.heading("Color & workflow");
            ui.add_space(8.);
            egui::ScrollArea::vertical().id_salt("settings-scroll").show(ui, |ui| {
                ui.add_enabled_ui(!self.busy, |ui| {
                    ui.label("Colorization model");
                    ui.menu_button(format!("Model: {}", self.settings.model), |ui| {
                        for v in ["9B FP8", "4B FP8", "4B BF16"] {
                            ui.selectable_value(&mut self.settings.model, v.into(), v);
                        }
                    });
                    ui.label("Scene / background");
                    ui.menu_button(format!("Scene: {}", self.settings.scene), |ui| {
                        for (code, label) in [
                            ("Source", "As drawn (no invented scenery)"),
                            ("Indoor", "Indoor room"),
                            ("Outdoor", "Outdoor scene"),
                            ("Mixed", "Mixed indoor/outdoor panels"),
                        ] {
                            ui.selectable_value(&mut self.settings.scene, code.into(), label);
                        }
                    });
                    ui.small("Indoor keeps walls and floors indoors. Does not require another model.");
                    ui.label("Color style");
                    ui.text_edit_singleline(&mut self.settings.style);
                    if ui.button("Choose style file…").clicked()
                        && let Some(p) = rfd::FileDialog::new().add_filter("Text", &["txt"]).pick_file()
                    {
                        self.settings.style = p.to_string_lossy().into_owned();
                    }
                    ui.horizontal(|ui| {
                        ui.label("Steps");
                        ui.add(egui::DragValue::new(&mut self.settings.steps).range(1..=50));
                    });
                    ui.horizontal(|ui| {
                        ui.label("Seed");
                        ui.add(egui::DragValue::new(&mut self.settings.seed).range(0..=2147483647_u32));
                    });
                    ui.horizontal(|ui| {
                        ui.label("MP per full page");
                        ui.add(egui::DragValue::new(&mut self.settings.megapixels).range(0.1..=4.0).speed(0.1).max_decimals(2));
                    });
                    if ui.button("Reset sampling: 4 / 42 / 1.5 MP").clicked() {
                        self.settings.steps = 4;
                        self.settings.seed = 42;
                        self.settings.megapixels = 1.5;
                    }
                    ui.small("Full-page processing: no strip splitting. PNG export keeps original dimensions.");
                    ui.separator();
                    egui::CollapsingHeader::new("Color completeness · CPU pass 2").default_open(true).show(ui,|ui| {
                        if ui.checkbox(&mut self.settings.second_pass,"Find likely missed colors after export").changed() && !self.settings.second_pass {self.settings.auto_repair=false;}
                        ui.add_enabled_ui(self.settings.second_pass,|ui| {
                            ui.checkbox(&mut self.settings.auto_repair,"Auto-repair missing colors");
                            ui.add(egui::Slider::new(&mut self.settings.missing_sensitivity,0.0..=1.0).text("Missing-color sensitivity"));
                            ui.add(egui::Slider::new(&mut self.settings.max_color_repairs,0..=8).text("Maximum CPU repairs"));
                            ui.label("Auto-repair needs approved skin/hair/clothing masks and colors. Other neutral areas remain suggestions. Enable CPU quality report for diagnostic masks.");
                        });
                    });
                    ui.label("Original shadow detail");
                    ui.add_enabled(!self.settings.original_ink, egui::Slider::new(&mut self.settings.source_shadows, 0.0..=1.0).max_decimals(2));
                    ui.small("0 keeps model shading; higher values deepen the source's gray tones. Does not restore changed drawing geometry.");
                    ui.checkbox(&mut self.settings.original_ink, "Preserve original ink and screentones");
                    ui.small("Uses source lines and shading; softer AI color layer. Compare before accepting.");
                    ui.add_enabled(
                        self.settings.original_ink,
                        egui::Checkbox::new(&mut self.settings.strict_ink, "Strong source-detail cleanup (softer colors)"),
                    );
                    ui.label("Text processing");
                    ui.menu_button(self.settings.text_mode().label(), |ui| {
                        for mode in [TextMode::Off, TextMode::Protect, TextMode::Replace] {
                            if ui.selectable_label(self.settings.text_mode() == mode, mode.label()).clicked() {
                                self.settings.set_text_mode(mode);
                            }
                        }
                    });
                    ui.small(match self.settings.text_mode() {
                        TextMode::Off => "No OCR, text detection, cleanup or text restoration. The color model may change lettering.",
                        TextMode::Protect => "Detects/crops text to make protection masks. Does not remove or translate text. Adds a detector pass.",
                        TextMode::Replace => "Runs OCR, cleanup and text rendering. Translation runs for a selected target language. This is slower.",
                    });
                    if ui.button("Fast color only").clicked() {
                        self.settings.fast_color_only();
                    }
                    ui.small(
                        "Fast preset disables text, vision matching/review and ink/shadow postprocessing. Character profiles remain as prompt instructions.",
                    );
                    ui.collapsing("Chapter characters & outfits", |ui| {
                        ui.small("Profiles apply to every page in this run. Describe each person distinctly.");
                        ui.checkbox(&mut self.settings.match_characters, "Match chapter people with vision model (slower)");
                        ui.small("Adds a separate vision-model pass per page. A color-model reload may follow.");
                        if ui.button("Load chapter profiles…").clicked()
                            && let Some(path) = rfd::FileDialog::new().add_filter("JSON", &["json"]).pick_file()
                        {
                            let loaded = std::fs::metadata(&path)
                                .ok()
                                .filter(|m| m.len() <= 128000)
                                .and_then(|_| std::fs::read(&path).ok())
                                .and_then(|bytes| serde_json::from_slice::<Profiles>(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes)).ok());
                            match loaded {
                                Some(p) if p.version == 1 => match validate_profiles(&p.characters) {
                                    Ok(()) => self.settings.characters = p.characters,
                                    Err(e) => self.status = e,
                                },
                                _ => self.status = "Could not load version-1 chapter profiles (maximum 128KB).".into(),
                            }
                        }
                        if ui.button("Save chapter profiles…").clicked() {
                            match validate_profiles(&self.settings.characters) {
                                Ok(()) => {
                                    if let Some(path) = rfd::FileDialog::new().set_file_name("mangacolorai-characters.json").save_file() {
                                        let data = Profiles { version: 1, characters: self.settings.characters.clone() };
                                        match serde_json::to_vec_pretty(&data).ok().and_then(|v| std::fs::write(path, v).ok()) {
                                            Some(()) => self.status = "Saved chapter profiles.".into(),
                                            None => self.status = "Could not save chapter profiles.".into(),
                                        }
                                    }
                                }
                                Err(e) => self.status = e,
                            }
                        }
                        let mut remove = None;
                        for (i, p) in self.settings.characters.iter_mut().enumerate() {
                            egui::CollapsingHeader::new(&p.name).id_salt(&p.id).show(ui, |ui| {
                                ui.label("Name");
                                ui.text_edit_singleline(&mut p.name);
                                ui.label("Identify by appearance");
                                ui.add(egui::TextEdit::multiline(&mut p.identify).desired_rows(2).hint_text("Hair shape, glasses, distinguishing clothing…"));
                                if matches!(p.identify.trim().to_lowercase().as_str(),"its girl"|"its boy"|"girl"|"boy"|"man"|"woman"|"male"|"female") {
                                    ui.label("Add distinguishing source features. Gender alone cannot reliably identify recurring people.");
                                }
                                if ui.button("Sample approved reference colors…").clicked()
                                    && let Some(path) = rfd::FileDialog::new().add_filter("Images", &["png", "jpg", "jpeg", "webp"]).pick_file()
                                {
                                    match palette::Sampler::open(&path, p.id.clone(), ctx) {
                                        Ok(sampler) => self.sampler = Some(sampler),
                                        Err(e) => self.status = e,
                                    }
                                }
                                ui.label("Hair");
                                ui.text_edit_singleline(&mut p.hair);
                                ui.label("Eyes");
                                ui.text_edit_singleline(&mut p.eyes);
                                ui.label("Skin base");
                                ui.text_edit_singleline(&mut p.skin);
                                egui::CollapsingHeader::new("Optional exact palette colors").id_salt(format!("tones-{}", p.id)).show(ui, |ui| {
                                    ui.label("Leave blank to use the skin description. Colors do not identify or create regions.");
                                    for (label, value) in [
                                        ("Base", &mut p.skin_tones.base),
                                        ("Shadow", &mut p.skin_tones.shadow),
                                        ("Highlight", &mut p.skin_tones.highlight),
                                        ("Undertone", &mut p.skin_tones.undertone),
                                    ] {
                                        ui.horizontal(|ui| {
                                            ui.label(label);
                                            ui.add(egui::TextEdit::singleline(value).hint_text("#RRGGBB"));
                                        });
                                    }
                                    let mut remove = None;
                                    for (i, color) in p.region_colors.iter_mut().enumerate() {
                                        ui.horizontal(|ui| {
                                            ui.text_edit_singleline(&mut color.name);
                                            ui.text_edit_singleline(&mut color.color);
                                            if ui.small_button("Remove").clicked() {
                                                remove = Some(i);
                                            }
                                        });
                                    }
                                    if let Some(i) = remove {
                                        p.region_colors.remove(i);
                                    }
                                    if p.region_colors.len() < 32 && ui.button("Add named region color").clicked() {
                                        p.region_colors.push(RegionColor { name: format!("Region {}", p.region_colors.len() + 1), color: "#B77D70".into() });
                                    }
                                });
                                let mut remove_outfit = None;
                                for (j, o) in p.outfits.iter_mut().enumerate() {
                                    ui.separator();
                                    ui.label("Outfit name");
                                    ui.text_edit_singleline(&mut o.name);
                                    ui.label("Stable outfit ID (optional for older profiles)");
                                    ui.text_edit_singleline(&mut o.id);
                                    ui.label("Which existing garments identify it?");
                                    ui.text_edit_singleline(&mut o.identify);
                                    ui.label("Fixed garment colors");
                                    ui.text_edit_multiline(&mut o.colors);
                                    let mut remove_garment=None;
                                    for (k,g) in o.garments.iter_mut().enumerate() {
                                        ui.push_id(k,|ui| {
                                            ui.label("Garment ID / name / source features / approved hex / pattern");
                                            ui.text_edit_singleline(&mut g.id);ui.text_edit_singleline(&mut g.name);ui.text_edit_singleline(&mut g.identify);ui.text_edit_singleline(&mut g.color);ui.text_edit_singleline(&mut g.pattern);
                                            if ui.small_button("Remove garment").clicked(){remove_garment=Some(k);}
                                        });
                                    }
                                    if let Some(k)=remove_garment{o.garments.remove(k);}
                                    if o.garments.len()<32 && ui.small_button("Add approved garment color").clicked(){o.garments.push(Garment{id:format!("garment-{}",o.garments.len()+1),..Garment::default()});}
                                    if ui.small_button("Remove this outfit").clicked() {
                                        remove_outfit = Some(j);
                                    }
                                }
                                if let Some(j) = remove_outfit {
                                    p.outfits.remove(j);
                                }
                                if p.outfits.len() < 20 && ui.button("Add outfit variant").clicked() {
                                    p.outfits.push(Outfit { id:format!("outfit-{}",p.outfits.len()+1),name: format!("Outfit {}", p.outfits.len() + 1), ..Outfit::default() });
                                }
                                if ui.small_button("Remove person profile").clicked() {
                                    remove = Some(i);
                                }
                            });
                        }
                        if let Some(i) = remove {
                            self.settings.characters.remove(i);
                        }
                        if self.settings.characters.len() < 20 && ui.button("Add person").clicked() {
                            let mut index = self.settings.characters.len() + 1;
                            while self.settings.characters.iter().any(|p| p.id == format!("person-{index}")) {
                                index += 1;
                            }
                            self.settings.characters.push(Person::new(index));
                        }
                    });
                    ui.separator();
                    ui.label("Language (used only for Remove and replace mode)");
                    ui.menu_button(format!("Language: {}", self.settings.language), |ui| {
                        for (code, label) in [
                            ("source", "Original language"),
                            ("en-US", "English"),
                            ("ja-JP", "Japanese"),
                            ("hi-IN", "Hindi"),
                            ("es-ES", "Spanish"),
                            ("fr-FR", "French"),
                            ("de-DE", "German"),
                            ("pt-BR", "Portuguese"),
                            ("zh-CN", "Chinese"),
                            ("ko-KR", "Korean"),
                            ("ar-SA", "Arabic"),
                            ("ru-RU", "Russian"),
                        ] {
                            ui.selectable_value(&mut self.settings.language, code.into(), label);
                        }
                    });
                    ui.checkbox(&mut self.settings.review_before_color, "Review text and character matches before coloring (pauses per page)");
                    ui.small("Off: folder runs continue without per-page popups; automatic matches are not saved as approved. On: inspect and approve matches before reuse.");
                    ui.separator();
                    ui.checkbox(&mut self.settings.review, "Vision review after coloring (slower)");
                    ui.label("Vision model configuration");
                    ui.text_edit_singleline(&mut self.settings.vision_config);
                    if ui.button("Choose GGUF review config…").clicked()
                        && let Some(p) = rfd::FileDialog::new().add_filter("JSON", &["json"]).pick_file()
                    {
                        self.settings.vision_config = p.to_string_lossy().into_owned();
                    }
                    ui.collapsing("Custom local vision model / reference", |ui| {
                        ui.label("Vision GGUF");
                        ui.text_edit_singleline(&mut self.settings.vision_model);
                        if ui.button("Choose GGUF…").clicked()
                            && let Some(p) = rfd::FileDialog::new().add_filter("GGUF", &["gguf"]).pick_file()
                        {
                            self.settings.vision_model = p.to_string_lossy().into_owned();
                        }
                        ui.label("Matching vision projector");
                        ui.text_edit_singleline(&mut self.settings.vision_projector);
                        if ui.button("Choose projector…").clicked()
                            && let Some(p) = rfd::FileDialog::new().add_filter("GGUF", &["gguf"]).pick_file()
                        {
                            self.settings.vision_projector = p.to_string_lossy().into_owned();
                        }
                        ui.label("Approved color reference (matching and review)");
                        ui.text_edit_singleline(&mut self.settings.reference);
                        if ui.button("Choose reference image…").clicked()
                            && let Some(p) = rfd::FileDialog::new().add_filter("Images", &["png", "jpg", "jpeg", "webp"]).pick_file()
                        {
                            self.settings.reference = p.to_string_lossy().into_owned();
                        }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Targeted retries");
                        ui.add(egui::DragValue::new(&mut self.settings.retries).range(0..=2));
                    });
                    ui.small("Reviews are advisory. All attempts are kept.");
                    ui.separator();
                    ui.label("Last output / explicit resume target");
                    ui.text_edit_singleline(&mut self.settings.output_directory);
                    if ui.button("Choose existing run to resume…").clicked()
                        && let Some(p) = rfd::FileDialog::new().pick_folder()
                    {
                        self.settings.output_directory = p.to_string_lossy().into_owned();
                        self.settings.resume = true;
                    }
                    if ui.button("New run folder").clicked() {
                        self.settings.resume = false;
                        self.settings.output_directory.clear();
                    }
                    ui.checkbox(&mut self.settings.resume, "Resume existing run (reuse this folder)");
                    ui.small("Off: every Start creates a NEW chapter-named folder. On: reuse the chosen folder and skip verified completed pages.");
                    ui.add_space(12.);
                    if ui.add_sized([260., 40.], egui::Button::new("Color selected image / folder").fill(egui::Color32::from_rgb(150, 63, 91))).clicked() {
                        self.run();
                    }
                });
                ui.separator();
                if ui.button("Open output folder").clicked() {
                    let p = self.result.as_ref().and_then(|p| p.parent()).map(Path::to_path_buf).unwrap_or_else(|| self.root.join("manga-output"));
                    let _ = Command::new("explorer.exe").arg(p).spawn();
                }
            });
        });
        egui::Panel::bottom("log").resizable(true).default_size(155.).show(ui, |ui| {
            ui.collapsing("Processing log", |ui| {
                egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
                    for line in &self.logs {
                        ui.monospace(line);
                    }
                });
            });
        });
        egui::CentralPanel::default().show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading(if self.view_result { "Result" } else { "Source" });
                if let Some(p) = self.result.clone()
                    && ui.button("Show latest result").clicked()
                {
                    self.view_result = true;
                    self.load_preview(p, ctx);
                }
            });
            ui.separator();
            if self.view_result
                && let Some(path) = self.result.clone()
            {
                ui.horizontal(|ui| {
                    if ui.button("Load another color attempt…").clicked()
                        && let Some(p) = rfd::FileDialog::new().add_filter("PNG", &["png"]).pick_file()
                    {
                        self.workbench.attempts.push(p.clone());
                        self.result = Some(p);
                    }
                    ui.menu_button("Previous attempts", |ui| {
                        for (index, attempt) in self.workbench.attempts.iter().enumerate() {
                            if ui.button(format!("Attempt {}", index + 1)).clicked() {
                                self.result = Some(attempt.clone());
                            }
                        }
                    });
                });
                self.workbench.palette_choices = self
                    .settings
                    .characters
                    .iter()
                    .flat_map(|p| {
                        let mut colors = Vec::new();
                        for (name, description) in [("hair", &p.hair), ("eyes", &p.eyes), ("skin", &p.skin)] {
                            if let Some(color) = first_hex(description) {
                                colors.push((format!("{}/{}", p.id, name), color));
                            }
                        }

                        for (name, color) in [
                            ("Base", &p.skin_tones.base),
                            ("Shadow", &p.skin_tones.shadow),
                            ("Highlight", &p.skin_tones.highlight),
                            ("Undertone", &p.skin_tones.undertone),
                        ] {
                            if valid_hex(color) {
                                colors.push((format!("{}/{}", p.id, name), color.clone()));
                            }
                        }
                        colors.extend(p.region_colors.iter().map(|c| (format!("{}/{}", p.id, c.name), c.color.clone())));
                        for outfit in &p.outfits {
                            for garment in &outfit.garments {
                                if valid_hex(&garment.color) {
                                    colors.push((
                                        format!("{}/outfit/{}/{}", p.id, if outfit.id.is_empty() { &outfit.name } else { &outfit.id }, garment.id),
                                        garment.color.clone(),
                                    ));
                                }
                            }
                        }
                        colors
                    })
                    .collect();
                self.workbench.show(ui, &path, ctx, self.busy);
                if self.workbench.save_live_requested && !self.busy {
                    self.save_live_image(ctx);
                }
            } else if let Some(texture) = &self.texture {
                let size = texture.size_vec2();
                let available = ui.available_size();
                let scale = (available.x / size.x).min(available.y / size.y).min(1.0);
                ui.centered_and_justified(|ui| {
                    ui.add(egui::Image::new(texture).fit_to_exact_size(size * scale));
                });
            } else {
                ui.centered_and_justified(|ui| {
                    ui.label("Open an image or folder to begin");
                });
            }
        });
        if self.busy {
            ctx.request_repaint_after(Duration::from_millis(150));
        }
    }
}
fn main() -> eframe::Result {
    let root = std::env::current_exe()
        .ok()
        .and_then(|p| p.ancestors().find(|p| p.join("scripts/local-manga/Studio-Run.ps1").exists()).map(Path::to_path_buf))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1280., 850.]).with_min_inner_size([1000., 650.]),
        ..Default::default()
    };
    eframe::run_native("MangaColorAI", options, Box::new(move |cc| Ok(Box::new(Studio::new(cc, root)))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_off_has_no_processing_flag_and_modes_are_exclusive() {
        let mut settings = Settings::default();
        for mode in [TextMode::Off, TextMode::Protect, TextMode::Replace] {
            settings.set_text_mode(mode);
            assert_eq!(settings.text_mode().flag(), mode.flag());
            assert!(!(settings.text && settings.preserve_text));
        }
        settings.fast_color_only();
        assert!(settings.text_mode().flag().is_none());
        assert!(!settings.review && !settings.match_characters && !settings.original_ink);
        assert_eq!(settings.source_shadows, 0.);
    }
    #[test]
    fn normal_start_uses_new_folder_even_when_last_output_is_remembered() {
        let mut settings = Settings { output_directory: "old-result".into(), ..Settings::default() };
        assert!(!settings.resume || settings.output_directory.is_empty());
        settings.resume = true;
        assert!(settings.resume && !settings.output_directory.is_empty());
        assert_ne!(output_folder_name(Path::new("Chapter"), true, 100), output_folder_name(Path::new("Chapter"), true, 101));
    }
    #[test]
    fn outputs_use_the_source_chapter_name() {
        assert_eq!(output_folder_name(Path::new("Chapter [1]"), true, 42), "Chapter [1]-0000002a");
        assert_eq!(output_folder_name(Path::new("page.webp"), false, 99), "page-00000063");
    }
    #[test]
    fn older_settings_keep_safe_defaults() -> Result<(), serde_json::Error> {
        let settings: Settings = serde_json::from_str(r#"{"model":"4B FP8","seed":123}"#)?;
        assert_eq!(settings.seed, 123);
        assert_eq!(settings.steps, 4);
        assert_eq!(settings.scene, "Source");
        assert!(!settings.resume);
        assert!(settings.preserve_text);
        assert!(!settings.original_ink);
        assert_eq!(settings.source_shadows, 0.0);
        Ok(())
    }

    #[test]
    fn chapter_pages_sort_numerically() {
        let mut pages = [PathBuf::from("10.webp"), PathBuf::from("2.jpg"), PathBuf::from("1.png")];
        pages.sort_by_key(|p| natural_key(p));
        assert_eq!(pages, [PathBuf::from("1.png"), PathBuf::from("2.jpg"), PathBuf::from("10.webp")]);
    }

    #[test]
    fn profiles_reject_ambiguous_ids_and_incomplete_outfits() {
        let mut person = Person::new(1);
        assert!(validate_profiles(&[person.clone()]).is_err());
        person.identify = "short hair, rectangular glasses".into();
        assert!(validate_profiles(&[person.clone()]).is_ok());
        assert!(validate_profiles(&[person.clone(), person.clone()]).is_err());
        person.outfits.push(Outfit { name: "school".into(), identify: "collared shirt".into(), ..Outfit::default() });
        assert!(validate_profiles(&[person]).is_err());
    }
    #[test]
    fn optional_palette_defaults_are_backwards_compatible_and_validated() {
        let old = r##"{"id":"p1","name":"A","identify":"round glasses","hair":"black","eyes":"brown","skin":"tan","outfits":[]}"##;
        let mut person: Person = serde_json::from_str(old).unwrap();
        assert!(person.skin_tones.base.is_empty());
        assert!(validate_profiles(&[person.clone()]).is_ok());
        person.skin_tones.shadow = "#BD8765".into();
        person.region_colors.push(RegionColor { name: "Lips".into(), color: "#AD7068".into() });
        assert!(validate_profiles(&[person.clone()]).is_ok());
        person.region_colors.push(RegionColor { name: "lips".into(), color: "#AABBCC".into() });
        assert!(validate_profiles(&[person]).is_err());
    }
    #[test]
    fn two_pass_defaults_are_conservative_and_keep_sampling() {
        let settings = Settings::default();
        assert!(settings.second_pass);
        assert!(!settings.auto_repair);
        assert_eq!(settings.max_color_repairs, 3);
        assert_eq!(settings.steps, 4);
        assert_eq!(settings.seed, 42);
        assert_eq!(settings.megapixels, 1.5);
    }
    #[test]
    fn second_pass_and_diagnostics_are_not_gated_by_ink_restoration() {
        let mut command = Command::new("unused-test-process");
        let settings = Settings { original_ink: false, second_pass: true, auto_repair: true, quality_report: true, ..Settings::default() };
        add_fidelity_options(&mut command, &settings);
        let args: Vec<_> = command.get_args().filter_map(|s| s.to_str()).collect();
        for flag in ["-SecondPass", "-AutoRepair", "-QualityReport", "-MissingColorSensitivity", "-MaxColorRepairs"] {
            assert!(args.contains(&flag));
        }
        assert!(!args.contains(&"-OriginalInk"));
        assert!(!args.contains(&"-StrictInk"));
    }
}
