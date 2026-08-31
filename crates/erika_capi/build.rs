fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos") {
        // Without an ELF SONAME, CMake records this cdylib's absolute build
        // path in the N-API bridge's DT_NEEDED entry, which cannot resolve on
        // device after HAR packaging.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,liberika_capi.so");
    }
}
