use std::env;
use std::fs::File;
use std::io::{copy};
use std::path::Path;

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: tar_util -cf archive.tar file...");
        eprintln!("       tar_util -xf archive.tar -C dir");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "-cf" => {
            if args.len() < 4 {
                return Err("missing archive name or files".into());
            }
            let archive_path = &args[2];
            let files = &args[3..];
            let tar_file = File::create(archive_path)?;
            let mut builder = tar::Builder::new(tar_file);
            for entry in files {
                let name = entry.trim_start_matches('/');
                let mut file = File::open(entry)
                    .map_err(|e| format!("cannot open {}: {}", entry, e))?;
                let metadata = file.metadata()
                    .map_err(|e| format!("cannot stat {}: {}", entry, e))?;
                let mut header = tar::Header::new_gnu();
                header.set_path(name)
                    .map_err(|e| format!("invalid path {}: {}", name, e))?;
                header.set_size(metadata.len());
                header.set_mode(0o644);
                header.set_cksum();
                builder.append(&mut header, &mut file)
                    .map_err(|e| format!("cannot append {}: {}", entry, e))?;
            }
            builder.finish()?;
        }
        "-xf" => {
            if args.len() < 3 {
                return Err("missing archive name".into());
            }
            let archive_path = &args[2];
            let out_dir = if args.len() >= 5 && args[3] == "-C" {
                &args[4]
            } else {
                "."
            };
            let tar_file = File::open(archive_path)
                .map_err(|e| format!("cannot open archive {}: {}", archive_path, e))?;
            let mut archive = tar::Archive::new(tar_file);
            for entry in archive.entries()? {
                let mut entry = entry?;
                let path = entry.path()?;
                let out_path = Path::new(out_dir).join(&*path);
                if let Some(parent) = out_path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                if entry.header().entry_type().is_dir() {
                    std::fs::create_dir_all(&out_path)?;
                } else {
                    let mut out_file = File::create(&out_path)?;
                    copy(&mut entry, &mut out_file)?;
                }
            }
        }
        _ => {
            return Err(format!("unsupported operation: {}", args[1]).into());
        }
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("tar_util: {}", e);
        std::process::exit(1);
    }
}
