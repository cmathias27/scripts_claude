//! Editeurs d'horaire (jours / heures) et de limite de debit des sauvegardes.

use eframe::egui::{self, RichText};

#[derive(Clone, Debug, PartialEq)]
pub struct SchedEdit {
    /// 0 manuel, 1 tous les jours, 2 certains jours, 3 avance (texte)
    pub mode: u8,
    /// heures separees par des virgules : "03:30, 15:00"
    pub times: String,
    /// lundi .. dimanche
    pub days: [bool; 7],
    pub raw: String,
}

impl Default for SchedEdit {
    fn default() -> Self {
        Self { mode: 1, times: "03:30".into(), days: [true; 7], raw: String::new() }
    }
}

fn valid_time(t: &str) -> bool {
    let b = t.as_bytes();
    b.len() == 5
        && b[2] == b':'
        && b.iter().enumerate().all(|(i, c)| i == 2 || c.is_ascii_digit())
        && t[..2].parse::<u32>().map(|v| v < 24).unwrap_or(false)
        && t[3..].parse::<u32>().map(|v| v < 60).unwrap_or(false)
}

/// Meme regle que valid_sched de nas-backup
pub fn valid_sched(s: &str) -> bool {
    if s == "manuel" {
        return true;
    }
    !s.is_empty()
        && s.split(';').all(|sl| match sl.split_once('/') {
            Some((t, d)) => valid_time(t) && !d.is_empty() && d.chars().all(|c| ('1'..='7').contains(&c)),
            None => valid_time(sl),
        })
}

impl SchedEdit {
    pub fn parse(s: &str) -> Self {
        let mut e = SchedEdit { raw: s.to_string(), ..Default::default() };
        if s == "manuel" {
            e.mode = 0;
            return e;
        }
        let slots: Vec<&str> = s.split(';').collect();
        let day_sets: Vec<Option<&str>> = slots.iter().map(|sl| sl.split_once('/').map(|(_, d)| d)).collect();
        let times: Vec<&str> = slots.iter().map(|sl| sl.split('/').next().unwrap_or("")).collect();
        e.times = times.join(", ");
        if day_sets.iter().all(|d| d.is_none()) {
            e.mode = 1;
        } else if day_sets.iter().all(|d| d.is_some() && *d == day_sets[0]) {
            e.mode = 2;
            let d = day_sets[0].unwrap_or("");
            for i in 0..7 {
                e.days[i] = d.contains(char::from_digit(i as u32 + 1, 10).unwrap_or('0'));
            }
        } else {
            e.mode = 3;
        }
        e
    }

    /// Horaire au format nas-backup, ou message d'erreur
    pub fn build(&self) -> Result<String, String> {
        let times: Vec<String> = self
            .times
            .split([',', ';', ' '])
            .map(|t| t.trim())
            .filter(|t| !t.is_empty())
            .map(|t| if t.len() == 4 && t.as_bytes()[1] == b':' { format!("0{t}") } else { t.to_string() })
            .collect();
        let s = match self.mode {
            0 => "manuel".to_string(),
            1 | 2 => {
                if times.is_empty() || !times.iter().all(|t| valid_time(t)) {
                    return Err("Heure invalide (format HH:MM, ex : 03:30 ; plusieurs séparées par des virgules).".into());
                }
                if self.mode == 1 || self.days.iter().all(|d| *d) {
                    times.join(";")
                } else {
                    let d: String = (0..7).filter(|i| self.days[*i]).map(|i| char::from_digit(i as u32 + 1, 10).unwrap_or('1')).collect();
                    if d.is_empty() {
                        return Err("Choisis au moins un jour.".into());
                    }
                    times.iter().map(|t| format!("{t}/{d}")).collect::<Vec<_>>().join(";")
                }
            }
            _ => self.raw.trim().to_string(),
        };
        if valid_sched(&s) {
            Ok(s)
        } else {
            Err("Horaire invalide.".into())
        }
    }

    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.radio_value(&mut self.mode, 0, "Manuel");
                ui.radio_value(&mut self.mode, 1, "Tous les jours");
                ui.radio_value(&mut self.mode, 2, "Certains jours");
                if ui.radio_value(&mut self.mode, 3, "Avancé").clicked() && self.raw.is_empty() {
                    self.raw = self.build().unwrap_or_default();
                }
            });
            match self.mode {
                1 | 2 => {
                    if self.mode == 2 {
                        ui.horizontal(|ui| {
                            for (i, n) in ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"].iter().enumerate() {
                                ui.toggle_value(&mut self.days[i], *n);
                            }
                        });
                    }
                    ui.horizontal(|ui| {
                        ui.label("à");
                        ui.add(egui::TextEdit::singleline(&mut self.times).desired_width(150.0).hint_text("03:30, 15:00"));
                        ui.label(RichText::new("plusieurs heures séparées par des virgules").small().weak());
                    });
                }
                3 => {
                    ui.add(egui::TextEdit::singleline(&mut self.raw).desired_width(260.0).hint_text("03:30/135;22:00"));
                    ui.label(RichText::new("HH:MM ou HH:MM/JOURS (1 = lundi … 7 = dimanche), séparés par ;").small().weak());
                }
                _ => {}
            }
            if let Ok(s) = self.build() {
                if self.mode != 0 {
                    ui.label(RichText::new(crate::fmt::schedule_human(&s)).small().weak());
                }
            }
        });
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct BwEdit {
    /// 0 aucune, 1 toujours, 2 en journee seulement (8 h - 23 h), 3 personnalisee
    pub mode: u8,
    /// Mo/s
    pub value: String,
    pub raw: String,
}

impl BwEdit {
    pub fn parse(s: &str) -> Self {
        let s = s.trim();
        if s.is_empty() || s == "off" {
            return BwEdit::default();
        }
        if let Some(v) = s.strip_suffix('M').filter(|v| v.parse::<f64>().is_ok()) {
            return BwEdit { mode: 1, value: v.to_string(), raw: s.into() };
        }
        if let Some(v) = s.strip_prefix("08:00,").and_then(|r| r.strip_suffix("M 23:00,off")) {
            return BwEdit { mode: 2, value: v.to_string(), raw: s.into() };
        }
        BwEdit { mode: 3, value: String::new(), raw: s.into() }
    }

    pub fn build(&self) -> Result<String, String> {
        let v = || -> Result<String, String> {
            let x: f64 = self.value.trim().replace(',', ".").parse().map_err(|_| "Débit invalide (en Mo/s, ex : 5).".to_string())?;
            if x <= 0.0 {
                return Err("Débit invalide (en Mo/s, ex : 5).".into());
            }
            Ok(format!("{}", (x * 10.0).round() / 10.0))
        };
        match self.mode {
            0 => Ok(String::new()),
            1 => Ok(format!("{}M", v()?)),
            2 => Ok(format!("08:00,{}M 23:00,off", v()?)),
            _ => {
                let r = self.raw.trim();
                if r.chars().all(|c| c.is_ascii_alphanumeric() || ":., -".contains(c)) {
                    Ok(r.to_string())
                } else {
                    Err("Limite de débit invalide.".into())
                }
            }
        }
    }

    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.radio_value(&mut self.mode, 0, "Aucune");
                ui.radio_value(&mut self.mode, 1, "Toujours");
                ui.radio_value(&mut self.mode, 2, "En journée (8 h – 23 h)");
                ui.radio_value(&mut self.mode, 3, "Avancée");
            });
            match self.mode {
                1 | 2 => {
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut self.value).desired_width(60.0).hint_text("5"));
                        ui.label("Mo/s");
                        if self.mode == 2 {
                            ui.label(RichText::new("pleine vitesse la nuit").small().weak());
                        }
                    });
                }
                3 => {
                    ui.add(egui::TextEdit::singleline(&mut self.raw).desired_width(260.0).hint_text("08:00,2M 23:00,off"));
                    ui.label(RichText::new("Format --bwlimit de rclone").small().weak());
                }
                _ => {}
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn horaires() {
        for s in ["manuel", "03:30", "03:30;15:00", "03:30/135", "03:30/67;22:00/67"] {
            assert_eq!(SchedEdit::parse(s).build().unwrap(), s);
        }
        let e = SchedEdit::parse("03:30/135;15:00");
        assert_eq!(e.mode, 3);
        let mut e = SchedEdit::default();
        e.mode = 2;
        e.days = [true, false, true, false, true, false, false];
        e.times = "3:30, 15:00".into();
        assert_eq!(e.build().unwrap(), "03:30/135;15:00/135");
        e.times = "25:00".into();
        assert!(e.build().is_err());
        assert!(!valid_sched("03:30/8"));
    }
    #[test]
    fn debit() {
        for s in ["", "5M", "08:00,2.5M 23:00,off", "10M:1M"] {
            assert_eq!(BwEdit::parse(s).build().unwrap(), s);
        }
        assert_eq!(BwEdit { mode: 1, value: "2,5".into(), raw: String::new() }.build().unwrap(), "2.5M");
    }
}
