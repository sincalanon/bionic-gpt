use std::env;
use std::path::Path;

fn main() {
    // Compile our SQL
    cornucopia();
}

fn cornucopia() {
    // For the sake of simplicity, this example uses the defaults.
    let queries_path = "queries";

    // Again, for simplicity, we generate the module in our project, but
    // we could've also generated it elsewhere if we wanted to.
    // For example, you could make the destination the `target` folder
    // and include the generated file with a `include_str` statement in your project.

    let out_dir = env::var_os("OUT_DIR").unwrap();
    let file_path = Path::new(&out_dir).join("cornucopia");

    // Rerun this build script if the queries or migrations change.
    println!("cargo:rerun-if-changed={queries_path}");
    println!("cargo:rerun-if-env-changed=CORNUCOPIA_PREGENERATED");

    // Offline builds (for example the Windows installer build): use code that
    // was generated earlier by `cornucopia live` against a migrated database.
    // CORNUCOPIA_PREGENERATED points at the generated crate directory
    // (the folder that contains `src/lib.rs`).
    if let Some(pregenerated) = env::var_os("CORNUCOPIA_PREGENERATED") {
        let src = Path::new(&pregenerated).join("src");
        println!("cargo:rerun-if-changed={}", src.display());
        copy_dir(&src, &file_path.join("src")).unwrap_or_else(|e| {
            panic!("Could not copy pregenerated cornucopia code from {}: {e}", src.display())
        });
        return;
    }

    let db_url = env::var_os("DATABASE_URL").unwrap();

    // Call cornucopia. Use whatever CLI command you need.
    let output = std::process::Command::new("cornucopia")
        .arg("live")
        .arg("-q")
        .arg(queries_path)
        .arg("-d")
        .arg(&file_path)
        .arg(db_url)
        .output()
        .unwrap();

    // If Cornucopia couldn't run properly, try to display the error.
    if !output.status.success() {
        panic!("{}", &std::str::from_utf8(&output.stderr).unwrap());
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}
