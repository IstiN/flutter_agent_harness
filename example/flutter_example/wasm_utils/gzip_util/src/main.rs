use std::env;
use std::fs::File;
use std::io::{copy, BufReader, BufWriter};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: gzip_util file");
        eprintln!("       gzip_util -d file.gz");
        std::process::exit(1);
    }

    if args[1] == "-d" {
        let path = &args[2];
        let out_path = path.trim_end_matches(".gz");
        let input = File::open(path)?;
        let output = File::create(out_path)?;
        let mut decoder = flate2::read::GzDecoder::new(BufReader::new(input));
        let mut writer = BufWriter::new(output);
        copy(&mut decoder, &mut writer)?;
    } else {
        let path = &args[1];
        let out_path = format!("{}.gz", path);
        let input = File::open(path)?;
        let output = File::create(&out_path)?;
        let mut encoder = flate2::write::GzEncoder::new(
            output,
            flate2::Compression::default(),
        );
        let mut reader = BufReader::new(input);
        copy(&mut reader, &mut encoder)?;
        encoder.finish()?;
        std::fs::remove_file(path)?;
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("gzip_util: {}", e);
        std::process::exit(1);
    }
}
