//! Mise en forme (francais) : tailles, durees, dates.

use chrono::{Local, TimeZone};

pub fn bytes(b: u64) -> String {
    let units = ["o", "Ko", "Mo", "Go", "To"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{} {}", b, units[0])
    } else {
        format!("{:.1} {}", v, units[i]).replace('.', ",")
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

pub fn duration(secs: i64) -> String {
    let s = secs.max(0);
    if s < 60 {
        format!("{s} s")
    } else if s < 3600 {
        format!("{} min", s / 60)
    } else if s < 86400 {
        format!("{} h {:02}", s / 3600, (s % 3600) / 60)
    } else {
        format!("{} j {} h", s / 86400, (s % 86400) / 3600)
    }
}

pub fn ago(ts: i64, now: i64) -> String {
    let d = now - ts;
    if d < 0 {
        return "à l'instant".into();
    }
    if d < 45 {
        "à l'instant".into()
    } else {
        format!("il y a {}", duration(d))
    }
}

pub fn date(ts: i64) -> String {
    match Local.timestamp_opt(ts, 0).single() {
        Some(t) => {
            let today = Local::now().date_naive();
            let d = t.date_naive();
            if d == today {
                format!("aujourd'hui {}", t.format("%H:%M"))
            } else if Some(d) == today.pred_opt() {
                format!("hier {}", t.format("%H:%M"))
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

/// Prochaine execution d'un horaire quotidien "HH:MM"
pub fn next_run(sched: &str) -> Option<String> {
    let (h, m) = sched.split_once(':')?;
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    let now = Local::now();
    let today = now.date_naive().and_hms_opt(h, m, 0)?;
    if today > now.naive_local() {
        Some(format!("aujourd'hui {:02}:{:02}", h, m))
    } else {
        Some(format!("demain {:02}:{:02}", h, m))
    }
}

/// Raccourcit les chemins OMV /srv/dev-disk-by-uuid-xxxx/Dossier -> …/Dossier
pub fn short_path(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("/srv/dev-disk-by-uuid-") {
        if let Some(i) = rest.find('/') {
            return format!("…{}", &rest[i..]);
        }
        return format!("disque {}", &rest[..rest.len().min(8)]);
    }
    p.to_string()
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
