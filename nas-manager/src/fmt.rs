//! Mise en forme (francais) : tailles, durees, dates.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use chrono::{Local, TimeZone};

pub fn bytes(b: u64) -> String {
    let en = crate::i18n::is_english();
    let units = if en { ["B", "KB", "MB", "GB", "TB"] } else { ["o", "Ko", "Mo", "Go", "To"] };
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{} {}", b, units[0])
    } else {
        let t = format!("{:.1} {}", v, units[i]);
        if en { t } else { t.replace('.', ",") }
    }
}

/// Nombres decimaux d'une ligne rclone : "864.000" -> "864", "1.234" -> "1,2"
fn tidy_numbers(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut num = String::new();
    let flush = |num: &mut String, out: &mut String| {
        if num.contains('.') {
            if let Ok(v) = num.parse::<f64>() {
                let t = if v >= 100.0 { format!("{v:.0}") } else { format!("{v:.1}").replace('.', ",") };
                out.push_str(&t);
                num.clear();
                return;
            }
        }
        out.push_str(num);
        num.clear();
    };
    for c in s.chars() {
        if c.is_ascii_digit() || (c == '.' && !num.is_empty()) {
            num.push(c);
        } else {
            flush(&mut num, &mut out);
            out.push(c);
        }
    }
    flush(&mut num, &mut out);
    out
}

/// Unites rclone (GiB, MiB/s...) en francais
pub fn rclone_units(s: &str) -> String {
    if crate::i18n::is_english() {
        return s.replace("KiB", "KB").replace("MiB", "MB").replace("GiB", "GB").replace("TiB", "TB");
    }
    tidy_numbers(s).replace("KiB", "Ko")
        .replace("MiB", "Mo")
        .replace("GiB", "Go")
        .replace("TiB", "To")
        .replace("Ki", "Ko")
        .replace("Mi", "Mo")
        .replace("Gi", "Go")
        .replace("Ti", "To")
        .replace(" B", " o")
        .replace("B/s", "o/s")
}

/// Duree rclone (1h2m3s, 52s, 1d2h) en francais
pub fn rclone_dur(s: &str) -> String {
    if s == "-" || s.is_empty() {
        return "—".into();
    }
    s.replace('d', " j ")
        .replace('h', " h ")
        .replace('m', " min ")
        .replace('s', " s")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace(" j ", " j ")
}

/// Nombre avec separateur de milliers : 431176 -> "431 176" (en anglais "431,176")
pub fn count(n: u64) -> String {
    let sep = if crate::i18n::is_english() { ',' } else { '\u{202F}' };
    let d = n.to_string();
    let mut out = String::with_capacity(d.len() + d.len() / 3);
    for (i, c) in d.chars().enumerate() {
        if i > 0 && (d.len() - i) % 3 == 0 {
            out.push(sep);
        }
        out.push(c);
    }
    out
}

pub fn duration(secs: i64) -> String {
    let s = secs.max(0);
    if s < 60 {
        format!("{s} s")
    } else if s < 3600 {
        tf("{0} min", &[&(s / 60)])
    } else if s < 86400 {
        format!("{} h {:02}", s / 3600, (s % 3600) / 60)
    } else {
        tf("{0} j {1} h", &[&(s / 86400), &((s % 86400) / 3600)])
    }
}

pub fn ago(ts: i64, now: i64) -> String {
    let d = now - ts;
    if d < 0 {
        return tr("à l'instant").into();
    }
    if d < 45 {
        tr("à l'instant").into()
    } else {
        tf("il y a {0}", &[&(duration(d))])
    }
}

pub fn date(ts: i64) -> String {
    match Local.timestamp_opt(ts, 0).single() {
        Some(t) => {
            let today = Local::now().date_naive();
            let d = t.date_naive();
            if d == today {
                tf("aujourd'hui {0}", &[&(t.format("%H:%M"))])
            } else if Some(d) == today.pred_opt() {
                tf("hier {0}", &[&(t.format("%H:%M"))])
            } else {
                t.format("%d/%m/%Y %H:%M").to_string()
            }
        }
        None => "?".into(),
    }
}

/// "2026/10/18 12:00:00" (journal rclone) -> timestamp local
pub fn parse_rclone_ts(s: &str) -> Option<i64> {
    let t = chrono::NaiveDateTime::parse_from_str(s.get(..19)?, "%Y/%m/%d %H:%M:%S").ok()?;
    Local.from_local_datetime(&t).single().map(|d| d.timestamp())
}

/// "2026-10-18 03:30" (fichier .status) -> timestamp local
pub fn parse_status_ts(s: &str) -> Option<i64> {
    let t = chrono::NaiveDateTime::parse_from_str(s.trim(), "%Y-%m-%d %H:%M").ok()?;
    Local.from_local_datetime(&t).single().map(|d| d.timestamp())
}


/// Raccourcit les chemins OMV /srv/dev-disk-by-uuid-xxxx/Dossier -> …/Dossier
pub fn short_path(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("/srv/dev-disk-by-uuid-") {
        if let Some(i) = rest.find('/') {
            return format!("…{}", &rest[i..]);
        }
        return tf("disque {0}", &[&(&rest[..rest.len().min(8)])]);
    }
    p.to_string()
}

/// Horaire nas-backup en clair : "03:30/135;15:00" -> "lun, mer, ven 03:30 · tous les jours 15:00"
pub fn schedule_human(s: &str) -> String {
    if s == "manuel" || s.is_empty() {
        return tr("Manuel").into();
    }
    let names = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"].map(tr);
    s.split(';')
        .map(|sl| match sl.split_once('/') {
            Some((t, d)) => {
                let days: Vec<&str> = d.chars().filter_map(|c| c.to_digit(10)).filter(|n| (1..=7).contains(n)).map(|n| names[n as usize - 1]).collect();
                let label = match d {
                    "12345" => tr("en semaine").to_string(),
                    "67" => tr("le week-end").to_string(),
                    _ => days.join(", "),
                };
                tf("{0} {1}", &[&label, &t])
            }
            None => tf("chaque jour {0}", &[&sl]),
        })
        .collect::<Vec<_>>()
        .join(" · ")
}

/// Prochaine execution d'un horaire nas-backup (plusieurs creneaux, jours)
pub fn next_run_sched(s: &str) -> Option<String> {
    use chrono::{Datelike, Duration};
    if s == "manuel" {
        return None;
    }
    let now = Local::now().naive_local();
    let mut best: Option<chrono::NaiveDateTime> = None;
    for sl in s.split(';') {
        let (t, d) = sl.split_once('/').unwrap_or((sl, "1234567"));
        let (h, m) = t.split_once(':')?;
        let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
        for add in 0..8 {
            let day = now.date() + Duration::days(add);
            let dow = day.weekday().number_from_monday();
            if !d.contains(char::from_digit(dow, 10)?) {
                continue;
            }
            let at = day.and_hms_opt(h, m, 0)?;
            if at > now {
                if best.map(|b| at < b).unwrap_or(true) {
                    best = Some(at);
                }
                break;
            }
        }
    }
    let b = best?;
    let days = (b.date() - now.date()).num_days();
    let jour = match days {
        0 => tr("aujourd'hui").to_string(),
        1 => tr("demain").to_string(),
        _ => tr(["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"][b.weekday().num_days_from_monday() as usize]).to_string(),
    };
    Some(tf("{0} {1}", &[&jour, &(b.format("%H:%M"))]))
}

/// Limite de debit rclone en clair
pub fn bw_human(s: &str) -> String {
    let s = s.trim();
    if let Some(v) = s.strip_suffix('M').filter(|v| v.parse::<f64>().is_ok()) {
        return tf("{0} Mo/s", &[&(v.replace('.', ","))]);
    }
    if let Some(v) = s.strip_prefix("08:00,").and_then(|r| r.strip_suffix("M 23:00,off")) {
        return tf("{0} Mo/s de 8 h à 23 h, sans limite la nuit", &[&(v.replace('.', ","))]);
    }
    s.to_string()
}

pub fn now() -> i64 {
    Local::now().timestamp()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn units() {
        assert_eq!(rclone_units("864.000 MiB / 4.000 GiB, 21%, 68.400 MiB/s"), "864 Mo / 4,0 Go, 21%, 68,4 Mo/s");
        assert_eq!(rclone_units("0 B / 0 B, -, 0 B/s"), "0 o / 0 o, -, 0 o/s");
        assert_eq!(rclone_dur("1m52s"), "1 min 52 s");
        assert_eq!(rclone_dur("1h2m3s"), "1 h 2 min 3 s");
        assert_eq!(bytes(1288490188), "1,2 Go");
        assert_eq!(short_path("/srv/dev-disk-by-uuid-7cd5/Photos/2024"), "…/Photos/2024");
        assert_eq!(schedule_human("03:30/135;15:00"), "lun, mer, ven 03:30 · chaque jour 15:00");
        assert_eq!(schedule_human("03:30/67"), "le week-end 03:30");
        assert!(next_run_sched("03:30").is_some());
        assert!(next_run_sched("manuel").is_none());
        assert_eq!(count(0), "0");
        assert_eq!(count(999), "999");
        assert_eq!(count(431176), "431\u{202F}176");
        assert_eq!(count(1234567), "1\u{202F}234\u{202F}567");
    }

    #[test]
    fn avancement_migration() {
        // format envoye par l'etat du Synology (script 2.1+) ; champs vides -> None
        let j = r#"{"etape": 1, "phase": "", "pct": 95, "avancement": {"pct": 95, "fichiers": 431176, "ref_fichiers": 452310,
                   "ref_octets": 102000000000, "envoye": 104000000000, "total_rclone": 106000000000, "provisoire": true,
                   "surplus": 2000000000, "vitesse": null, "fich_min": null, "eta": null, "essais": 1, "erreurs": 3}}"#;
        let e: crate::model::Etape = serde_json::from_str(j).unwrap();
        let a = e.avancement.unwrap();
        assert_eq!((a.fichiers, a.ref_fichiers, a.surplus, a.eta), (431176, Some(452310), 2000000000, None));
        assert!(a.provisoire);
        // ancien script : pas d'avancement detaille
        let e: crate::model::Etape = serde_json::from_str(r#"{"etape": 1, "pct": 98}"#).unwrap();
        assert!(e.avancement.is_none());
    }
}

/// Ligne de statistiques rclone en francais ("…, ETA 21m32s" -> "…, reste 21 min 32 s")
pub fn stats_line(s: &str) -> String {
    let u = rclone_units(s);
    match u.rfind("ETA ") {
        Some(i) => {
            let (head, tail) = u.split_at(i);
            let eta = tail[4..].split_whitespace().next().unwrap_or("");
            format!("{head}reste {}", rclone_dur(eta))
        }
        None => u,
    }
}
