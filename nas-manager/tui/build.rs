// Les modules partages avec l'application Windows (modele, traductions, scripts d'etat)
// sont compiles ici avec ce drapeau : leurs tests propres a l'application sont ecartes.
fn main() {
    println!("cargo:rustc-check-cfg=cfg(nas_manager_tui)");
    println!("cargo:rustc-cfg=nas_manager_tui");
    println!("cargo:rerun-if-changed=build.rs");
}
