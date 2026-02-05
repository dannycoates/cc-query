fn main() {
    if std::env::var("DUCKDB_STATIC").is_ok() {
        // Common libraries
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");

        // Platform-specific libraries
        let target = std::env::var("TARGET").unwrap_or_default();

        if target.contains("linux") {
            println!("cargo:rustc-link-lib=stdc++");
            println!("cargo:rustc-link-lib=dl");
            println!("cargo:rustc-link-lib=z");
        } else if target.contains("darwin") || target.contains("apple") {
            println!("cargo:rustc-link-lib=c++");
            println!("cargo:rustc-link-lib=z");
        }
    }
}
