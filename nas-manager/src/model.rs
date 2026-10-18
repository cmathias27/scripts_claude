//! Etat renvoye par les scripts de collecte (JSON).

use serde::Deserialize;

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Progress {
    pub octets_faits: String,
    pub octets_total: String,
    pub pct: Option<i64>,
    pub vitesse: String,
    pub reste: String,
    pub fichiers_faits: Option<i64>,
    pub fichiers_total: Option<i64>,
    pub verifs_faites: Option<i64>,
    pub verifs_total: Option<i64>,
    pub erreurs: Option<i64>,
    pub duree: Option<String>,
    pub en_cours: Vec<CurFile>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct CurFile {
    pub fichier: String,
    pub pct: i64,
    pub taille: String,
    pub vitesse: String,
    pub reste: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Bilan {
    pub debut: i64,
    pub fin: i64,
    pub duree_min: f64,
    pub code: i64,
    pub fichiers_envoyes: i64,
    pub nouveaux: i64,
    pub remplaces: i64,
    pub retires: i64,
    pub erreurs: i64,
    pub volume_octets: i64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Job {
    pub nom: String,
    pub source: String,
    pub dossier: String,
    pub mode: String,
    pub chiffre: bool,
    pub horaire: String,
    pub corbeille: u32,
    pub source_existe: bool,
    pub dernier_etat: Option<String>,
    pub derniere_execution: Option<String>,
    pub dernier_succes: Option<i64>,
    pub bilan: Option<Bilan>,
    pub en_cours: bool,
    pub debut: Option<i64>,
    pub avancement: Option<Progress>,
    pub derniere_erreur: Option<String>,
    pub debit: String,
    pub simulation: Option<Simulation>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Simulation {
    pub etat: String,
    pub fin: i64,
    pub envois: i64,
    pub suppressions: i64,
    pub octets: u64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct CopyQueueItem {
    pub source: String,
    pub destination: String,
    pub dans_dossier: bool,
    pub deplacement: bool,
    pub debit: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Restore {
    pub etat: String,
    pub nom: String,
    pub cible: String,
    pub debut: String,
    pub fin: String,
    pub code: String,
    pub avancement: Option<Progress>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Cameras {
    pub installe: bool,
    pub actif: bool,
    pub demarrage_auto: bool,
    pub dossier: String,
    pub rattrapage_en_cours: bool,
    pub alerte_rattrapage: bool,
    pub actif_depuis: String,
    pub envois_aujourdhui: i64,
    pub dernier_envoi: Option<String>,
    pub erreurs_aujourdhui: i64,
    pub derniere_erreur: Option<String>,
    pub evenements: Vec<String>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Health {
    pub gdrive: bool,
    pub quota_pct: Option<f64>,
    pub used_go: Option<f64>,
    pub total_go: Option<f64>,
    pub checked: Option<String>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Alert {
    pub tag: String,
    pub depuis: i64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Disk {
    pub point: String,
    pub taille: u64,
    pub utilise: u64,
    pub libre: u64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct OmvStatus {
    pub erreur: Option<String>,
    pub serveur: String,
    pub maintenant: i64,
    pub uptime_s: Option<i64>,
    pub charge: Option<String>,
    pub disques: Vec<Disk>,
    pub nb_installe: bool,
    pub nb_api: u32,
    pub arret_demande: bool,
    pub sauvegardes: Vec<Job>,
    pub restauration: Option<Restore>,
    pub cameras: Cameras,
    pub sante: Option<Health>,
    pub alertes: Vec<Alert>,
    pub alertes_installees: bool,
    pub nas_check_en_cours: bool,
    pub suivi_ha: bool,
}

impl OmvStatus {
    pub fn any_job_running(&self) -> bool {
        self.sauvegardes.iter().any(|j| j.en_cours)
    }
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct CopyProgress {
    pub fait: String,
    pub pct: i64,
    pub vitesse: String,
    pub reste: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Copie {
    pub installe: bool,
    pub api: u32,
    pub cle_omv: bool,
    pub source: Option<String>,
    pub destination: Option<String>,
    pub mode: Option<String>,
    pub total: u64,
    pub nb_fichiers: u64,
    pub debut: i64,
    pub en_cours: bool,
    pub code: Option<String>,
    pub avancement: Option<CopyProgress>,
    pub erreurs: Vec<String>,
    pub historique: Vec<String>,
    pub debit: String,
    pub file: Vec<CopyQueueItem>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct OcisConf {
    pub url: String,
    pub locale: String,
    pub utilisateur: String,
    pub mode: String,
    pub certificat_accepte: bool,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct QueueItem {
    pub source: String,
    pub libelle: String,
    pub espace_id: String,
    pub espace: String,
    pub sous_dossier: String,
    pub total: u64,
    pub suppression: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Etape {
    pub etape: i64,
    pub source: String,
    pub libelle: String,
    pub espace: String,
    pub total: u64,
    pub suppression: String,
    pub reprise: i64,
    pub phase: String,
    pub ligne: String,
    pub pct: Option<i64>,
    pub ram_mo: Option<i64>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct MigResult {
    pub n: i64,
    pub etat: String,
    pub libelle: String,
    pub espace: String,
    pub detail: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Migration {
    pub installe: bool,
    pub api: u32,
    pub config: Option<OcisConf>,
    pub file: Vec<QueueItem>,
    pub en_cours: bool,
    pub nb: i64,
    pub debut: i64,
    pub etape: Option<Etape>,
    pub resultats: Vec<MigResult>,
    pub bilan: Option<String>,
    pub historique: Vec<String>,
    pub journal: Vec<String>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SynoStatus {
    pub erreur: Option<String>,
    pub serveur: String,
    pub maintenant: i64,
    pub copie: Copie,
    pub migration: Migration,
}

#[derive(Clone, Debug)]
pub struct Space {
    pub id: String,
    pub name: String,
    pub free: i64,
    pub quota: i64,
}

/// Une execution de sauvegarde (historique.jsonl)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Run {
    pub nom: String,
    pub etat: String,
    pub erreur: String,
    pub debut: i64,
    pub fin: i64,
    pub duree_min: f64,
    pub fichiers_envoyes: i64,
    pub retires: i64,
    pub erreurs: i64,
    pub volume_octets: i64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct DiskPoint {
    pub p: String,
    pub u: u64,
    pub s: u64,
}

/// Releve d'espace (espace.jsonl)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SpacePoint {
    pub t: i64,
    pub drive_go: Option<f64>,
    pub drive_total_go: Option<f64>,
    pub disques: Vec<DiskPoint>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct History {
    pub executions: Vec<Run>,
    pub espace: Vec<SpacePoint>,
}
