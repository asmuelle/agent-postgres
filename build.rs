/// Build script for pgAgent.
///
/// # Swift binding generation
///
/// uniffi Swift bindings are generated from the compiled cdylib using library
/// mode. To generate bindings manually:
///
/// ```sh
/// cargo build -p pgAgent
/// uniffi-bindgen generate \
///     target/debug/lib_midnight_ssh.dylib \
///     --language swift \
///     --out-dir pgAgent/bindings
/// ```
///
/// In Xcode, this runs as a build phase before the Swift compilation step.
fn main() {
    // Trigger re-build when the FFI interface changes.
    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=src/lib.rs");

    // The cdylib target is needed for uniffi binding generation.
    // The staticlib is what the final macOS app links against.
    println!("cargo:rustc-cfg=uniffi_library_mode");
}
