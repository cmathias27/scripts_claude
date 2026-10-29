//! Editeurs d'horaire (jours / heures) et de limite de debit des sauvegardes.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use eframe::egui::{self, RichText};
pub use crate::fmt::parse_day_night;
use crate::fmt::valid_time;

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
                    return Err(tr("Heure invalide (format HH:MM, ex : 03:30 ; plusieurs séparées par des virgules).").into());
                }
                if self.mode == 1 || self.days.iter().all(|d| *d) {
                    times.join(";")
                } else {
                    let d: String = (0..7).filter(|i| self.days[*i]).map(|i| char::from_digit(i as u32 + 1, 10).unwrap_or('1')).collect();
                    if d.is_empty() {
                        return Err(tr("Choisis au moins un jour.").into());
                    }
                    times.iter().map(|t| format!("{t}/{d}")).collect::<Vec<_>>().join(";")
                }
            }
            _ => self.raw.trim().to_string(),
        };
        if valid_sched(&s) {
            Ok(s)
        } else {
            Err(tr("Horaire invalide.").into())
        }
    }

    pub fn ui(&mut self, ui: &mut egui::Ui) {
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.radio_value(&mut self.mode, 0, tr("Manuel"));
                ui.radio_value(&mut self.mode, 1, tr("Tous les jours"));
                ui.radio_value(&mut self.mode, 2, tr("Certains jours"));
                if ui.radio_value(&mut self.mode, 3, tr("Avancé")).clicked() && self.raw.is_empty() {
                    self.raw = self.build().unwrap_or_default();
                }
            });
            match self.mode {
                1 | 2 => {
                    if self.mode == 2 {
                        ui.horizontal(|ui| {
                            for (i, n) in [tr("Lun"), tr("Mar"), tr("Mer"), tr("Jeu"), tr("Ven"), tr("Sam"), tr("Dim")].iter().enumerate() {
                                ui.toggle_value(&mut self.days[i], *n);
                            }
                        });
                    }
                    ui.horizontal(|ui| {
                        ui.label(tr("à"));
                        ui.add(egui::TextEdit::singleline(&mut self.times).desired_width(150.0).hint_text("03:30, 15:00"));
                        ui.label(RichText::new(tr("plusieurs heures séparées par des virgules")).small().weak());
                    });
                }
                3 => {
                    ui.add(egui::TextEdit::singleline(&mut self.raw).desired_width(260.0).hint_text("03:30/135;22:00"));
                    ui.label(RichText::new(tr("HH:MM ou HH:MM/JOURS (1 = lundi … 7 = dimanche), séparés par ;")).small().weak());
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

#[derive(Clone, Debug, PartialEq)]
pub struct BwEdit {
    /// 0 reglage de la machine (ou aucune limite hors NAS Debian), 1 toujours,
    /// 2 selon l'heure (jour / nuit), 3 personnalisee, 4 sans limite
    pub mode: u8,
    /// Mo/s (toujours, ou en journee)
    pub value: String,
    /// debut et fin de la journee (HH:MM)
    pub day_start: String,
    pub day_end: String,
    /// Mo/s la nuit (vide = sans limite)
    pub night: String,
    pub raw: String,
}

impl Default for BwEdit {
    fn default() -> Self {
        Self { mode: 0, value: String::new(), day_start: "08:00".into(), day_end: "23:00".into(), night: String::new(), raw: String::new() }
    }
}

/// Debit en Mo/s lisible par rclone ("2.5"), ou erreur
fn mo_s(v: &str) -> Result<String, String> {
    let x: f64 = v.trim().replace(',', ".").parse().map_err(|_| tr("Débit invalide (en Mo/s, ex : 5).").to_string())?;
    if x <= 0.0 || x > 100_000.0 {
        return Err(tr("Débit invalide (en Mo/s, ex : 5).").into());
    }
    Ok(format!("{}", (x * 10.0).round() / 10.0))
}


impl BwEdit {
    pub fn parse(s: &str) -> Self {
        let s = s.trim();
        if s.is_empty() {
            return BwEdit::default();
        }
        if s == "off" {
            return BwEdit { mode: 4, raw: s.into(), ..Default::default() };
        }
        if let Some(v) = s.strip_suffix('M').filter(|v| v.parse::<f64>().is_ok()) {
            return BwEdit { mode: 1, value: v.to_string(), raw: s.into(), ..Default::default() };
        }
        if let Some((t1, day, t2, night)) = parse_day_night(s) {
            return BwEdit { mode: 2, value: day, day_start: t1, day_end: t2, night, raw: s.into() };
        }
        BwEdit { mode: 3, raw: s.into(), ..Default::default() }
    }

    pub fn build(&self) -> Result<String, String> {
        match self.mode {
            0 => Ok(String::new()),
            4 => Ok("off".into()),
            1 => Ok(format!("{}M", mo_s(&self.value)?)),
            2 => {
                let norm = |t: &str| {
                    let t = t.trim();
                    if t.len() == 4 && t.as_bytes()[1] == b':' { format!("0{t}") } else { t.to_string() }
                };
                let (t1, t2) = (norm(&self.day_start), norm(&self.day_end));
                if !valid_time(&t1) || !valid_time(&t2) || t1 == t2 {
                    return Err(tr("Heures de la journée invalides (format HH:MM, début et fin différents).").into());
                }
                let night = if self.night.trim().is_empty() { "off".to_string() } else { format!("{}M", mo_s(&self.night)?) };
                Ok(format!("{t1},{}M {t2},{night}", mo_s(&self.value)?))
            }
            _ => {
                let r = self.raw.trim();
                if !r.is_empty() && r.chars().all(|c| c.is_ascii_alphanumeric() || ":., -".contains(c)) {
                    Ok(r.to_string())
                } else {
                    Err(tr("Limite de débit invalide.").into())
                }
            }
        }
    }

    /// Editeur ; `machine` : le choix « vide » suit le réglage de la machine (NAS Debian),
    /// sinon il veut dire « aucune limite »
    pub fn ui_with(&mut self, ui: &mut egui::Ui, machine: bool) {
        ui.vertical(|ui| {
            ui.horizontal_wrapped(|ui| {
                if machine {
                    ui.radio_value(&mut self.mode, 0, tr("Réglage de la machine"));
                    ui.radio_value(&mut self.mode, 4, tr("Sans limite"));
                } else {
                    if self.mode == 4 {
                        self.mode = 0;
                    }
                    ui.radio_value(&mut self.mode, 0, tr("Aucune"));
                }
                ui.radio_value(&mut self.mode, 1, tr("Toujours"));
                ui.radio_value(&mut self.mode, 2, tr("Selon l'heure"));
                ui.radio_value(&mut self.mode, 3, tr("Avancée"));
            });
            match self.mode {
                1 => {
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut self.value).desired_width(60.0).hint_text("5"));
                        ui.label("Mo/s");
                    });
                }
                2 => day_night_ui(ui, &mut self.day_start, &mut self.day_end, &mut self.value, &mut self.night),
                3 => {
                    ui.add(egui::TextEdit::singleline(&mut self.raw).desired_width(260.0).hint_text("08:00,2M 23:00,off"));
                    ui.label(RichText::new(tr("Format --bwlimit de rclone")).small().weak());
                }
                _ => {}
            }
            if self.mode == 0 && machine {
                ui.label(RichText::new(tr("Limite commune de la machine (page Installation > Débit selon l'heure).")).small().weak());
            }
        });
    }

    pub fn ui(&mut self, ui: &mut egui::Ui) {
        self.ui_with(ui, false)
    }
}

/// Champs « de HH:MM à HH:MM : X Mo/s, la nuit : Y Mo/s (vide = sans limite) »
pub fn day_night_ui(ui: &mut egui::Ui, start: &mut String, end: &mut String, day: &mut String, night: &mut String) {
    ui.horizontal(|ui| {
        ui.label(tr("De"));
        ui.add(egui::TextEdit::singleline(start).desired_width(48.0).hint_text("08:00"));
        ui.label(tr("à"));
        ui.add(egui::TextEdit::singleline(end).desired_width(48.0).hint_text("23:00"));
        ui.label(":");
        ui.add(egui::TextEdit::singleline(day).desired_width(48.0).hint_text("2"));
        ui.label("Mo/s");
    });
    ui.horizontal(|ui| {
        ui.label(tr("Le reste du temps :"));
        ui.add(egui::TextEdit::singleline(night).desired_width(48.0).hint_text(tr("aucune")));
        ui.label(tr("Mo/s (vide = sans limite)"));
    });
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
        for s in ["", "off", "5M", "08:00,2.5M 23:00,off", "07:30,1M 22:00,10M", "10M:1M"] {
            assert_eq!(BwEdit::parse(s).build().unwrap(), s);
        }
        assert_eq!(BwEdit { mode: 1, value: "2,5".into(), ..Default::default() }.build().unwrap(), "2.5M");
        let e = BwEdit::parse("08:00,2M 23:00,off");
        assert_eq!((e.mode, e.day_start.as_str(), e.value.as_str(), e.day_end.as_str(), e.night.as_str()), (2, "08:00", "2", "23:00", ""));
        let e = BwEdit { mode: 2, value: "3".into(), day_start: "7:00".into(), day_end: "21:30".into(), night: "8".into(), raw: String::new() };
        assert_eq!(e.build().unwrap(), "07:00,3M 21:30,8M");
        assert!(BwEdit { day_end: "07:00".into(), ..e.clone() }.build().is_err());
        assert!(BwEdit { value: "0".into(), ..e }.build().is_err());
        assert_eq!(BwEdit::parse("Mon-08:00,1M").mode, 3);
    }
}
