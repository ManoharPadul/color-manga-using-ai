use eframe::egui;
use std::path::Path;

pub struct Sampler {
    pub person_id: String,
    pixels: image::RgbaImage,
    texture: egui::TextureHandle,
    hex: String,
}
impl Sampler {
    pub fn open(path: &Path, person_id: String, ctx: &egui::Context) -> Result<Self, String> {
        let pixels = super::preview_image(path)?;
        let texture = ctx.load_texture(
            "approved-reference",
            egui::ColorImage::from_rgba_unmultiplied([pixels.width() as usize, pixels.height() as usize], pixels.as_raw()),
            egui::TextureOptions::LINEAR,
        );
        Ok(Self { person_id, pixels, texture, hex: String::new() })
    }
    pub fn show(&mut self, ctx: &egui::Context) -> Option<(String, String)> {
        let mut choice = None;
        let mut open = true;
        egui::Window::new("Sample an approved reference palette").open(&mut open).default_width(560.).show(ctx, |ui| {
            ui.label("Click a flat base-color area. Avoid ink, highlights and shadows. The selected hex value is saved into this person's chapter profile.");
            let size = self.texture.size_vec2();
            let size = size * (520. / size.x).min(430. / size.y).min(1.);
            let response = ui.add(egui::Image::new(&self.texture).fit_to_exact_size(size).sense(egui::Sense::click()));
            if response.clicked()
                && let Some(pos) = response.interact_pointer_pos()
            {
                let x = ((pos.x - response.rect.left()) / response.rect.width() * self.pixels.width() as f32)
                    .clamp(0., self.pixels.width().saturating_sub(1) as f32) as u32;
                let y = ((pos.y - response.rect.top()) / response.rect.height() * self.pixels.height() as f32)
                    .clamp(0., self.pixels.height().saturating_sub(1) as f32) as u32;
                let p = self.pixels.get_pixel(x, y);
                self.hex = format!("#{:02X}{:02X}{:02X}", p.0[0], p.0[1], p.0[2]);
            }
            ui.label(format!("Selected: {}", self.hex));
            ui.add_enabled_ui(!self.hex.is_empty(), |ui| {
                ui.horizontal(|ui| {
                    for field in ["hair", "eyes", "skin"] {
                        if ui.button(format!("Use for {field}")).clicked() {
                            choice = Some((field.to_owned(), self.hex.clone()));
                        }
                    }
                    if ui.button("Copy hex for outfit").clicked() {
                        ctx.copy_text(self.hex.clone());
                    }
                });
            });
        });
        if !open {
            return Some(("close".into(), String::new()));
        }
        choice
    }
}
