fn main() {
    if std::env::var("DUCKDB_STATIC").is_ok() {
        // Common libraries
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");

        // DuckDB is built with zig c++ (libc++ ABI) - libc++.a is in the same dir
        // as libduckdb_static.a (copied there by `just setup-duckdb`)
        if let Ok(lib_dir) = std::env::var("DUCKDB_LIB_DIR") {
            println!("cargo:rustc-link-search=native={lib_dir}");
        }
        println!("cargo:rustc-link-lib=static:+whole-archive=c++");
        println!("cargo:rustc-link-lib=static:+whole-archive=c++abi");

        // Platform-specific libraries
        let target = std::env::var("TARGET").unwrap_or_default();

        if target.contains("linux") {
            println!("cargo:rustc-link-lib=dl");
            println!("cargo:rustc-link-lib=z");
        } else if target.contains("darwin") || target.contains("apple") {
            println!("cargo:rustc-link-lib=z");
        }
    }
}
