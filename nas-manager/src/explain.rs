//! Explication en francais des erreurs courantes (rclone, rsync, SSH, oCIS)
//! avec la marche a suivre.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::theme::{ERR, WARN};
use eframe::egui::{self, RichText};

pub struct Explanation {
    pub cause: &'static str,
    pub remedy: &'static str,
    /// Commande a lancer sur le NAS, le cas echeant
    pub command: Option<&'static str>,
    /// Se resout tout seul (reprise automatique)
    pub transient: bool,
}

const RULES: &[(&[&str], Explanation)] = &[
    (
        &["invalid_grant", "token expired", "couldn't fetch token", "oauth2: cannot fetch token", "token has been expired or revoked"],
        Explanation {
            cause: "L'autorisation Google Drive de rclone a expiré ou a été révoquée.",
            remedy: "Sur l'OMV, relancer l'autorisation de rclone (un navigateur est nécessaire, une seule fois). Les sauvegardes reprendront ensuite normalement.",
            command: Some("rclone config reconnect gdrive:"),
            transient: false,
        },
    ),
    (
        &["storagequotaexceeded", "storage quota has been exceeded", "quota exceeded", "insufficient storage", " 507"],
        Explanation {
            cause: "L'espace de stockage est plein.",
            remedy: "Libérer de la place (corbeille du Drive, anciennes sauvegardes, durée de corbeille plus courte) ou augmenter le stockage. Pour oCIS : espace > ⋯ > Modifier le quota > « Pas de restriction ».",
            command: None,
            transient: false,
        },
    ),
    (
        &["userratelimitexceeded", "ratelimitexceeded", "rate limit exceeded", "user rate limit", "too many requests", " 429"],
        Explanation {
            cause: "Google limite le débit (au plus environ 750 Go envoyés par jour et par compte).",
            remedy: "Rien à faire : rclone ralentit et réessaie. Si la limite quotidienne est atteinte, la suite partira à la prochaine exécution.",
            command: None,
            transient: true,
        },
    ),
    (
        &["source introuvable", "directory not found", "dossier source introuvable", "no such file or directory"],
        Explanation {
            cause: "Le dossier source n'existe plus ou le disque n'est pas monté.",
            remedy: "Vérifier dans OpenMediaVault (Stockage > Systèmes de fichiers) que le disque est bien monté, ou corriger le dossier de la sauvegarde.",
            command: None,
            transient: false,
        },
    ),
    (
        &["no such host", "dial tcp", "i/o timeout", "network is unreachable", "connection reset", "connection refused", "temporary failure in name resolution", "tls handshake timeout"],
        Explanation {
            cause: "Connexion réseau ou Internet interrompue pendant le transfert.",
            remedy: "Vérifier la connexion Internet du NAS. Le transfert reprendra là où il s'est arrêté à la prochaine exécution (ou en le relançant).",
            command: None,
            transient: true,
        },
    ),
    (
        &[" 401", "(401)", "unauthorized", "jeton refuse"],
        Explanation {
            cause: "Identifiants refusés (jeton d'application oCIS expiré ou révoqué).",
            remedy: "Créer un nouveau jeton (docker exec <conteneur-ocis> ocis auth-app create --user-name=<compte> --expiration=2160h) puis le saisir dans « Modifier la connexion ».",
            command: None,
            transient: false,
        },
    ),
    (
        &["out of memory", "cannot allocate memory", "oom", "memoire insuffisante", "signal 9"],
        Explanation {
            cause: "Le NAS a manqué de mémoire pendant le transfert.",
            remedy: "La migration repasse automatiquement à un seul fichier à la fois. Fermer les applications gourmandes du NAS si cela se répète.",
            command: None,
            transient: true,
        },
    ),
    (
        &["permission denied", "operation not permitted", "access denied"],
        Explanation {
            cause: "Droits insuffisants sur un fichier ou un dossier.",
            remedy: "Vérifier les droits du dossier concerné (page Copie → OMV > Réparer les droits pour l'OMV).",
            command: None,
            transient: false,
        },
    ),
    (
        &["corrupted on transfer", "hash differ", "checksum"],
        Explanation {
            cause: "Un fichier a été altéré pendant l'envoi.",
            remedy: "Relancer la sauvegarde : le fichier sera renvoyé.",
            command: None,
            transient: true,
        },
    ),
    (
        &["no space left on device"],
        Explanation {
            cause: "Le disque de destination (ou le disque système du NAS) est plein.",
            remedy: "Libérer de la place sur le disque concerné (page Tableau de bord > Serveur OMV).",
            command: None,
            transient: false,
        },
    ),
    (
        &["file name too long", "name too long"],
        Explanation {
            cause: "Un nom de fichier est trop long pour la destination (souvent à cause du chiffrement des noms).",
            remedy: "Raccourcir le nom ou le chemin du fichier indiqué dans l'erreur.",
            command: None,
            transient: false,
        },
    ),
];

pub fn explain(text: &str) -> Option<&'static Explanation> {
    let low = text.to_lowercase();
    RULES
        .iter()
        .find(|(pats, _)| pats.iter().any(|p| low.contains(p)))
        .map(|(_, e)| e)
}

/// Encadre « Pourquoi ? / Que faire ? » sous une erreur
pub fn show(ui: &mut egui::Ui, error_text: &str) {
    let Some(e) = explain(error_text) else {
        ui.label(RichText::new(error_text).small().monospace().color(ERR));
        return;
    };
    let col = if e.transient { WARN } else { ERR };
    egui::Frame::new()
        .fill(col.gamma_multiply(0.10))
        .stroke(egui::Stroke::new(1.0, col.gamma_multiply(0.5)))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new(tf("Pourquoi ? {0}", &[&tr(e.cause)])).strong());
            ui.label(tf("Que faire ? {0}", &[&tr(e.remedy)]));
            if let Some(c) = e.command {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(c).monospace());
                    if ui.small_button(tr("\u{E1CA} Copier")).clicked() {
                        ui.ctx().copy_text(c.to_string());
                    }
                });
            }
            ui.label(RichText::new(error_text).small().monospace().weak());
        });
}

#[cfg(test)]
mod tests {
    use super::explain;
    #[test]
    fn erreurs_courantes() {
        assert!(explain("Failed to copy: googleapi: Error 403: User Rate Limit Exceeded").unwrap().transient);
        assert!(explain("oauth2: cannot fetch token: 400 Bad Request {\"error\": \"invalid_grant\"}").unwrap().command.is_some());
        assert!(explain("Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded").is_some());
        assert!(explain("tout va bien").is_none());
    }
}
