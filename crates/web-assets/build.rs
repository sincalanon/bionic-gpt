//! Generates `static_files.rs`: one `StaticFile` per asset with a
//! content-hashed public name.
//!
//! Replaces the `cache-busters` crate, which wrote absolute paths into Rust
//! string literals without escaping (breaks on Windows) and made the server
//! read assets from the build machine's path at runtime. Here every asset is
//! embedded with `include_bytes!`, so the binary is self-contained.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let asset_dirs = [manifest_dir.join("dist"), manifest_dir.join("images")];

    let mut output = String::from(
        r#"
pub mod statics {
    pub struct StaticFile {
        pub file_name: &'static str,
        pub name: &'static str,
        pub mime: &'static str,
        pub data: &'static [u8],
    }
"#,
    );

    let mut names = Vec::new();
    for dir in &asset_dirs {
        println!("cargo:rerun-if-changed={}", dir.display());
        if dir.exists() {
            process_directory(dir, &mut output, &mut names);
        }
    }

    output.push_str(
        r#"
    #[allow(dead_code)]
    impl StaticFile {
        /// Get a single `StaticFile` by name, if it exists.
        #[must_use]
        pub fn get(name: &str) -> Option<&'static Self> {
            STATICS.iter().copied().find(|s| s.name == name)
        }
    }
"#,
    );

    let list = names
        .iter()
        .map(|n| format!("&{n}"))
        .collect::<Vec<_>>()
        .join(", ");
    let _ = writeln!(output, "    pub static STATICS: &[&StaticFile] = &[{list}];");
    output.push_str("}\n");

    fs::write(out_dir.join("static_files.rs"), output).unwrap();
}

fn process_directory(dir: &Path, output: &mut String, names: &mut Vec<String>) {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            process_directory(&path, output, names);
        } else if path.is_file() {
            process_file(&path, output, names);
        }
    }
}

fn process_file(path: &Path, output: &mut String, names: &mut Vec<String>) {
    let bytes = fs::read(path).unwrap();
    let hash = fnv1a_hex(&bytes);

    let file_name = path.file_name().unwrap().to_str().unwrap();
    let var_name = file_name.replace(['/', '.', '-', ' '], "_");
    let stem = path.file_stem().unwrap().to_str().unwrap();
    let extension = path.extension().map(|e| e.to_str().unwrap()).unwrap_or("");
    let hashed_name = format!("/static/{stem}-{hash}.{extension}");
    let mime = mime_type_from_extension(extension);
    let path_str = path.to_str().unwrap();

    // `{:?}` produces a correctly escaped Rust string literal on every OS.
    let _ = write!(
        output,
        r#"
    #[allow(non_upper_case_globals)]
    pub static {var_name}: StaticFile = StaticFile {{
        file_name: {path_lit:?},
        name: {name_lit:?},
        mime: {mime:?},
        data: include_bytes!({path_lit:?}),
    }};
"#,
        path_lit = path_str,
        name_lit = hashed_name,
    );
    names.push(var_name);
}

fn fnv1a_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn mime_type_from_extension(extension: &str) -> &'static str {
    match extension {
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "ico" => "image/x-icon",
        "webp" => "image/webp",
        "css" => "text/css",
        "js" => "application/javascript",
        "map" | "json" => "application/json",
        "wasm" => "application/wasm",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}
