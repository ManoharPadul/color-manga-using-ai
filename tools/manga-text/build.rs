// Koharu's static native dependencies must share the application's dynamic MSVC CRT.
fn main() {
    println!("cargo:rerun-if-env-changed=TARGET");
    if std::env::var("TARGET").is_ok_and(|target| target.ends_with("windows-msvc")) {
        println!("cargo:rustc-link-arg=/NODEFAULTLIB:LIBCMT");
    }
}
