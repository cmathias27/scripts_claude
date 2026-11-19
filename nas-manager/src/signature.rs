//! Signatures ed25519 des publications : liste des versions des scripts
//! (versions-scripts.json.sig) et liste des empreintes d'une Release (signatures.txt.sig,
//! qui couvre nas-manager.exe et les binaires de l'interface texte).
//!
//! La cle privee n'est pas sur GitHub (voir signature/signer-publication.sh) : un compte
//! GitHub compromis ne suffit pas a faire installer un fichier modifie.

use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use std::collections::HashMap;

/// Cles publiques acceptees (base64 des 32 octets), meme cle que signature/cle-publique.pem.
/// Plusieurs cles possibles pour en changer sans couper les mises a jour.
pub const PUBLIC_KEYS: &[&str] = &["dlSYXIEMvM1/ItXAbT5gUKjoCg0/L5DFFzsmex9/RFA="];

/// Fichier de la Release qui liste les empreintes, et sa signature
pub const SUMS_FILE: &str = "signatures.txt";
pub const SUMS_SIG_FILE: &str = "signatures.txt.sig";

/// Texte tel qu'il a ete signe (fins de ligne Unix)
pub fn unix(s: &str) -> String {
    s.replace("\r\n", "\n")
}

/// `sig_b64` : signature en base64 (contenu d'un fichier .sig)
pub fn verify(message: &[u8], sig_b64: &str) -> bool {
    verify_with(PUBLIC_KEYS, message, sig_b64)
}

fn verify_with(keys: &[&str], message: &[u8], sig_b64: &str) -> bool {
    let b64 = base64::engine::general_purpose::STANDARD;
    let Some(sig) = b64.decode(sig_b64.trim()).ok().and_then(|s| <[u8; 64]>::try_from(s.as_slice()).ok()) else {
        return false;
    };
    let sig = Signature::from_bytes(&sig);
    keys.iter().any(|k| {
        b64.decode(k)
            .ok()
            .and_then(|k| <[u8; 32]>::try_from(k.as_slice()).ok())
            .and_then(|k| VerifyingKey::from_bytes(&k).ok())
            .is_some_and(|k| k.verify_strict(message, &sig).is_ok())
    })
}

/// Contenu de signatures.txt : « nas-manager X.Y.Z » puis « <sha256>  <fichier> » par ligne
#[derive(Debug, PartialEq)]
pub struct ReleaseSums {
    pub version: String,
    pub sums: HashMap<String, String>,
}

/// Lit signatures.txt apres verification de sa signature ; None si la signature est invalide
pub fn release_sums(txt: &str, sig_b64: &str) -> Option<ReleaseSums> {
    let txt = unix(txt);
    if !verify(txt.as_bytes(), sig_b64) {
        return None;
    }
    parse_sums(&txt)
}

fn parse_sums(txt: &str) -> Option<ReleaseSums> {
    let mut lines = txt.lines();
    let version = lines.next()?.strip_prefix("nas-manager ")?.trim().to_string();
    let sums = lines
        .filter_map(|l| {
            let (h, f) = l.split_once(char::is_whitespace)?;
            let f = f.trim().trim_start_matches('*');
            (h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit())).then(|| (f.to_string(), h.to_ascii_lowercase()))
        })
        .collect();
    Some(ReleaseSums { version, sums })
}

pub fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // signatures.txt signe par la vraie cle (openssl pkeyutl -sign -rawin), comme
    // signature/signer-publication.sh : verifie que openssl et ed25519-dalek s'accordent
    const SUMS: &str = include_str!("../tests/signatures-exemple.txt");
    const SUMS_SIG: &str = include_str!("../tests/signatures-exemple.txt.sig");

    #[test]
    fn manifeste_integre_signe() {
        let sig = include_str!("../../versions-scripts.json.sig");
        assert!(
            verify(unix(crate::scripts::EMBEDDED_MANIFEST).as_bytes(), sig),
            "versions-scripts.json.sig ne correspond pas : relancer python3 maj-versions-scripts.py avec la cle privee"
        );
    }

    #[test]
    fn liste_de_publication() {
        let r = release_sums(SUMS, SUMS_SIG).expect("signature de l'exemple refusee");
        assert_eq!(r.version, "0.0.0");
        assert_eq!(r.sums.get("nas-manager.exe").map(String::as_str), Some(sha256_hex(b"exemple").as_str()));
        assert_eq!(r.sums.len(), 2);
        // fins de ligne Windows : meme texte signe
        assert!(release_sums(&SUMS.replace('\n', "\r\n"), SUMS_SIG).is_some());
    }

    #[test]
    fn modifications_refusees() {
        assert!(release_sums(&SUMS.replace("0.0.0", "9.9.9"), SUMS_SIG).is_none());
        assert!(release_sums(&format!("{SUMS}{}  autre\n", "0".repeat(64)), SUMS_SIG).is_none());
        assert!(release_sums(SUMS, "").is_none());
        assert!(release_sums(SUMS, "pas du base64").is_none());
        let mut s = base64::engine::general_purpose::STANDARD.decode(SUMS_SIG.trim()).unwrap();
        s[10] ^= 1;
        assert!(release_sums(SUMS, &base64::engine::general_purpose::STANDARD.encode(s)).is_none());
        // autre cle : refusee
        assert!(!verify_with(&["11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="], SUMS.as_bytes(), SUMS_SIG));
    }

    #[test]
    fn lecture_de_la_liste() {
        let h = "a".repeat(64);
        let r = parse_sums(&format!("nas-manager 1.2.3\n{h}  nas-manager.exe\n{h} *bin\nligne invalide\n")).unwrap();
        assert_eq!(r.version, "1.2.3");
        assert_eq!(r.sums.len(), 2);
        assert!(r.sums.contains_key("bin"));
        assert!(parse_sums("autre 1.0\n").is_none());
    }
}
