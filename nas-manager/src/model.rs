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
    /// pic de memoire de rclone (Mo)
    pub ram_max_mo: Option<i64>,
    /// sauvegardes versionnees : nombre de versions gardees
    pub versions: Option<i64>,
    /// resultat par destination (script 2.2+)
    pub destinations: Vec<DestBilan>,
}

/// Resultat d'une execution pour une destination
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct DestBilan {
    pub destination: String,
    pub chiffre: bool,
    pub code: i64,
    pub fichiers_envoyes: i64,
    pub volume_octets: i64,
    pub erreurs: i64,
    pub erreur: Option<String>,
    pub versions: Option<i64>,
    pub derniere_version: Option<i64>,
}

/// Destination d'une sauvegarde (jobs.conf)
#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct JobDest {
    pub nom: String,
    pub chiffre: bool,
}

/// Destination en cours de traitement (i sur n)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct DestProgress {
    pub i: i64,
    pub n: i64,
    pub nom: String,
}

/// Entretien hebdomadaire des versions
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Maintenance {
    pub fin: i64,
    pub code: i64,
    pub erreurs: String,
}

/// Etat d'une destination (dernier test : nas-check ou bouton Tester)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct DestState {
    pub ok: bool,
    pub verifie: i64,
    pub total: Option<u64>,
    pub utilise: Option<u64>,
    pub libre: Option<u64>,
    pub erreur: Option<String>,
}

/// Destination configuree sur la machine (remote rclone)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Destination {
    pub nom: String,
    /// type rclone : drive, onedrive, local, sftp...
    #[serde(rename = "type")]
    pub kind: String,
    pub libelle: String,
    pub cible: String,
    pub chiffre_pret: bool,
    pub etat: Option<DestState>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SecoursDest {
    pub ok: bool,
    pub date: i64,
    pub erreur: Option<String>,
}

/// Kit de secours (secours etat)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Secours {
    pub mot_de_passe: bool,
    pub nom: String,
    pub taille: Option<u64>,
    pub date: Option<i64>,
    pub empreinte: Option<String>,
    pub destinations: std::collections::BTreeMap<String, SecoursDest>,
}

/// Script installe sur une machine (nas-debian / nas-synology)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Agent {
    pub script: String,
    pub version: String,
    pub api: u32,
    /// "omv", "debian" ou "synology"
    pub machine: String,
    pub dsm: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Memory {
    pub total_mo: i64,
    pub dispo_mo: i64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct PerfEffective {
    pub profil: String,
    pub mo: i64,
    pub options: String,
}

/// Reglage memoire de rclone d'une machine (`reglages voir`)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Perf {
    pub profil: String,
    pub mo: String,
    pub transferts: String,
    pub verifs: String,
    pub tampon: String,
    pub effectif: PerfEffective,
    pub ram_total_mo: i64,
    pub ram_dispo_mo: i64,
    /// Synology : adresse de l'OMV et de Home Assistant
    pub omv: String,
    pub ha: String,
    pub webhook: String,
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
    /// memoire de rclone propre a la sauvegarde ("" = reglage de la machine)
    pub memoire: String,
    /// memoire utilisee par rclone pendant l'execution (Mo)
    pub ram_mo: Option<i64>,
    pub simulation: Option<Simulation>,
    pub verification: Option<Verification>,
    /// destinations (script 2.2+ ; avant : Google Drive seul)
    pub destinations: Vec<JobDest>,
    /// sauvegardes versionnees : jours:semaines:mois:annees
    pub rotation: String,
    pub dest_en_cours: Option<DestProgress>,
    pub entretien: Option<Maintenance>,
}

impl Job {
    pub fn versions(&self) -> bool {
        self.mode == "versions"
    }
    /// destinations (anciennes collectes : Google Drive)
    pub fn dests(&self) -> Vec<JobDest> {
        if self.destinations.is_empty() {
            vec![JobDest { nom: "gdrive".into(), chiffre: self.chiffre }]
        } else {
            self.destinations.clone()
        }
    }
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Verification {
    pub etat: String,
    pub fin: i64,
    pub identiques: i64,
    pub differents: i64,
    pub manquants: i64,
    pub en_trop: i64,
    pub erreurs: i64,
    /// etat par destination : « gdrive:ok;usb:ecarts »
    pub destinations: String,
    /// « versions » : controle des depots restic
    #[serde(rename = "type")]
    pub kind: String,
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
    pub element: String,
    /// sauvegarde versionnee : version restauree
    pub version: String,
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
pub struct RtDir {
    pub chemin: String,
    pub existe: bool,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct RtPause {
    pub depuis: i64,
    pub raison: String,
}

/// Sauvegarde temps reel (temps-reel.conf + etat)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct RtJob {
    pub nom: String,
    pub dossiers: Vec<RtDir>,
    pub destination: String,
    /// directe, corbeille ou copie
    pub suppression: String,
    pub corbeille: u32,
    pub exclusions: String,
    pub types: String,
    pub delai: u32,
    pub rattrapage: u32,
    pub anomalie: u32,
    pub memoire: String,
    pub debit: String,
    pub chiffre: bool,
    pub actif: bool,
    pub demarrage_auto: bool,
    pub rattrapage_en_cours: bool,
    pub pause: Option<RtPause>,
    pub envois_aujourdhui: i64,
    pub volume_aujourdhui: i64,
    pub suppressions_aujourdhui: i64,
    pub echecs_aujourdhui: i64,
    pub dernier_envoi: Option<i64>,
    pub derniere_erreur: Option<String>,
    pub evenements: Vec<String>,
    pub ram_mo: Option<i64>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Health {
    pub gdrive: bool,
    pub quota_pct: Option<f64>,
    pub used_go: Option<f64>,
    pub total_go: Option<f64>,
    pub checked: Option<String>,
    /// remote Google Drive configure (script 2.2+)
    pub gdrive_configure: Option<bool>,
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
    /// verification automatique : "JOURS HH:MM" ou vide
    pub verif_auto: String,
    pub sauvegardes: Vec<Job>,
    pub restauration: Option<Restore>,
    pub cameras: Cameras,
    pub sante: Option<Health>,
    pub alertes: Vec<Alert>,
    pub alertes_installees: bool,
    pub nas_check_en_cours: bool,
    pub suivi_ha: bool,
    pub memoire: Memory,
    pub agent: Option<Agent>,
    /// version gardee en .bak (retour arriere possible)
    pub agent_bak: String,
    /// anciens scripts encore en place (avant migration)
    pub anciens: Vec<String>,
    pub migration_requise: bool,
    pub perf: Option<Perf>,
    pub temps_reel: Vec<RtJob>,
    /// sauvegarde temps reel reprise de l'ancienne synchro des cameras
    pub cam_job: String,
    /// destinations configurees (script 2.2+)
    pub destinations: Vec<Destination>,
    pub secours: Option<Secours>,
}

impl OmvStatus {
    pub fn any_job_running(&self) -> bool {
        self.sauvegardes.iter().any(|j| j.en_cours)
    }
    pub fn any_rt_catchup(&self) -> bool {
        self.temps_reel.iter().any(|j| j.rattrapage_en_cours)
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
    pub avancement: Option<Avancement>,
}

/// Avancement detaille d'un transfert (script 2.1+), par rapport a la taille reelle de la source
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Avancement {
    pub pct: Option<i64>,
    pub fichiers: u64,
    pub ref_fichiers: Option<u64>,
    pub ref_octets: Option<u64>,
    pub envoye: u64,
    pub total_rclone: u64,
    /// le total annonce par rclone grossit encore (parcours de la source en cours)
    pub provisoire: bool,
    /// octets envoyes au-dela de la taille de la source (nouveaux essais), au moins
    pub surplus: u64,
    pub vitesse: Option<u64>,
    pub fich_min: Option<u64>,
    pub eta: Option<i64>,
    pub essais: u64,
    pub erreurs: u64,
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
    pub memoire: Memory,
    pub agent: Option<Agent>,
    pub agent_bak: String,
    pub anciens: Vec<String>,
    pub migration_requise: bool,
    pub perf: Option<Perf>,
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
