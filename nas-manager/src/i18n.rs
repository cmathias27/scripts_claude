//! Traduction de l'interface (francais par defaut, anglais).
//! Les textes restent ecrits en francais dans le code ; `tr` et `tf` renvoient
//! leur traduction anglaise (table `i18n_en.rs`) quand l'anglais est choisi.
//! Les messages produits par les scripts des NAS restent en francais.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

static LANG: AtomicU8 = AtomicU8::new(0); // 0 = francais, 1 = anglais

fn table() -> &'static HashMap<&'static str, &'static str> {
    static T: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    T.get_or_init(|| crate::i18n_en::EN.iter().copied().collect())
}

/// "" = langue de Windows, "fr" ou "en"
pub fn set_language(code: &str) {
    let en = match code {
        "en" => true,
        "fr" => false,
        _ => sys_locale::get_locale().map(|l| !l.to_lowercase().starts_with("fr")).unwrap_or(false),
    };
    LANG.store(en as u8, Ordering::Relaxed);
}

pub fn is_english() -> bool {
    LANG.load(Ordering::Relaxed) == 1
}

/// Texte traduit
pub fn tr(s: &'static str) -> &'static str {
    if is_english() {
        table().get(s).copied().unwrap_or(s)
    } else {
        s
    }
}

/// Modele traduit, puis {0}, {1}... remplaces par les valeurs
pub fn tf(template: &'static str, args: &[&dyn std::fmt::Display]) -> String {
    let t = tr(template);
    let mut out = String::with_capacity(t.len() + 16);
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '{' {
            if chars.peek() == Some(&'{') {
                chars.next();
                out.push('{');
                continue;
            }
            let mut num = String::new();
            while let Some(&d) = chars.peek() {
                if d.is_ascii_digit() {
                    num.push(d);
                    chars.next();
                } else {
                    break;
                }
            }
            if chars.peek() == Some(&'}') && !num.is_empty() {
                chars.next();
                if let Some(a) = num.parse::<usize>().ok().and_then(|i| args.get(i)) {
                    out.push_str(&a.to_string());
                }
                continue;
            }
            out.push('{');
            out.push_str(&num);
            continue;
        }
        if c == '}' && chars.peek() == Some(&'}') {
            chars.next();
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn modeles() {
        // (sans changer la langue globale : les tests tournent en parallele)
        assert_eq!(tf("a {0} b {1} {{x}}", &[&1, &"deux"]), "a 1 b deux {x}");
        assert_eq!(table().get("Paramètres").copied(), Some("Settings"));
    }
    #[test]
    fn table_coherente() {
        // memes {N} dans la traduction que dans l'original
        for (fr, en) in crate::i18n_en::EN {
            let count = |s: &str| (0..10).filter(|i| s.contains(&format!("{{{i}}}"))).count();
            assert_eq!(count(fr), count(en), "placeholders differents : {fr} / {en}");
        }
    }
}
