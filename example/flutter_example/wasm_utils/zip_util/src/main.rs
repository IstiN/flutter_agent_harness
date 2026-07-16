use std::env;
use std::fs::File;
use std::io::{copy, BufReader};
use std::path::Path;

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: zip_util archive.zip file...");
        eprintln!("       zip_util archive.zip -d dir");
        std::process::exit(1);
    }

    let archive_path = &args[1];

    // Detect extraction mode: second token is -d or any later token is -d.
    let extract_mode = args.len() >= 3 && args[2] == "-d" || args.iter().skip(2).any(|a| a == "-d");

    if extract_mode {
        let mut out_dir = ".";
        let mut i = 2;
        while i < args.len() {
            if args[i] == "-d" && i + 1 < args.len() {
                out_dir = &args[i + 1];
                i += 2;
            } else {
                i += 1;
            }
        }
        let file = File::open(archive_path)
            .map_err(|e| format!("cannot open archive {}: {}", archive_path, e))?;
        let mut archive = zip::ZipArchive::new(file)?;
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i)?;
            let entry_path = entry.mangled_name();
            let stripped = entry_path.strip_prefix("/").unwrap_or(&entry_path);
            let out_path = Path::new(out_dir).join(stripped);
            if entry.is_dir() {
                std::fs::create_dir_all(&out_path)?;
            } else {
                if let Some(parent) = out_path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let out_file = File::create(&out_path)?;
                let mut writer = std::io::BufWriter::new(out_file);
                copy(&mut entry, &mut writer)?;
            }
        }
    } else {
        let files = &args[2..];
        let file = File::create(archive_path)?;
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for entry in files {
            let name = entry.trim_start_matches('/');
            zip.start_file(name, options)?;
            let f = File::open(entry)
                .map_err(|e| format!("cannot open {}: {}", entry, e))?;
            let mut reader = BufReader::new(f);
            copy(&mut reader, &mut zip)?;
        }
        zip.finish()?;
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("zip_util: {}", e);
        std::process::exit(1);
    }
}
