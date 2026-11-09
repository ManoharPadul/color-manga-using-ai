#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use image::{DynamicImage, ImageReader, imageops::FilterType};
use serde::Serialize;
use std::path::{Path, PathBuf};

const MAX_PIXELS: u64 = 256_000_000;

#[derive(Parser)]
#[command(name = "MangaColorAI-Image", about = "Standalone image preparation utility for MangaColorAI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Info {
        input: PathBuf,
    },
    Convert {
        input: PathBuf,
        output: PathBuf,
    },
    Resize {
        input: PathBuf,
        output: PathBuf,
        #[arg(long)]
        width: u32,
        #[arg(long)]
        height: u32,
    },
    Crop {
        input: PathBuf,
        output: PathBuf,
        #[arg(long)]
        x: u32,
        #[arg(long)]
        y: u32,
        #[arg(long)]
        width: u32,
        #[arg(long)]
        height: u32,
    },
}

#[derive(Serialize)]
struct ImageInfo {
    width: u32,
    height: u32,
}

fn open(path: &Path) -> Result<DynamicImage> {
    let image = ImageReader::open(path)
        .with_context(|| format!("Could not open image: {}", path.display()))?
        .decode()
        .with_context(|| format!("Could not decode image: {}", path.display()))?;
    let (width, height) = (image.width(), image.height());
    ensure!(width > 0 && height > 0, "Image dimensions must be positive");
    ensure!(u64::from(width) * u64::from(height) <= MAX_PIXELS, "Image exceeds the 256 megapixel safety limit");
    Ok(image)
}

fn save(image: &DynamicImage, output: &Path) -> Result<()> {
    if let Some(parent) = output.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).with_context(|| format!("Could not create output directory: {}", parent.display()))?;
        }
    }
    image.save(output).with_context(|| format!("Could not save image: {}", output.display()))
}

fn run() -> Result<()> {
    match Cli::parse().command {
        Command::Info { input } => {
            let image = open(&input)?;
            let info = ImageInfo { width: image.width(), height: image.height() };
            println!("{}", serde_json::to_string(&info)?);
        }
        Command::Convert { input, output } => {
            let image = open(&input)?;
            save(&image, &output)?;
        }
        Command::Resize { input, output, width, height } => {
            ensure!(width > 0 && height > 0, "Resize dimensions must be positive");
            ensure!(u64::from(width) * u64::from(height) <= MAX_PIXELS, "Resize exceeds the 256 megapixel safety limit");
            let image = open(&input)?;
            let resized = image.resize_exact(width, height, FilterType::Lanczos3);
            save(&resized, &output)?;
        }
        Command::Crop { input, output, x, y, width, height } => {
            ensure!(width > 0 && height > 0, "Crop dimensions must be positive");
            let image = open(&input)?;
            ensure!(x.checked_add(width).is_some_and(|right| right <= image.width()), "Crop extends beyond image width");
            ensure!(y.checked_add(height).is_some_and(|bottom| bottom <= image.height()), "Crop extends beyond image height");
            let cropped = image.crop_imm(x, y, width, height);
            save(&cropped, &output)?;
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
