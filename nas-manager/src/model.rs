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
    /// en veille, reveil configure (pas d'alerte)
    pub veille: bool,
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

/// Estimation d'un envoi complet (`nas-debian estimer`, script 2.6+)
#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct NasEstimate {
    pub fichiers: u64,
    pub octets: u64,
    /// debit vers la destination (octets / s) : historique des sauvegardes, ou envoi de test
    pub debit_mesure: u64,
    /// historique, test, aucune
    pub methode: String,
    pub limite: String,
    /// debit moyen sur 24 h, limite de debit comprise
    pub debit_effectif: u64,
    pub duree_s: Option<i64>,
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
    /// Synology : reveil de l'OMV avant les copies (nas-synology 2.3+)
    pub omv_mac: String,
    pub omv_apres: String,
    /// limite de debit commune des sauvegardes (nas-debian 2.6+, format --bwlimit)
    pub debit: String,
    /// actions depuis Home Assistant autorisees (nas-debian 2.6+) et ecoute active
    pub ha_actions: bool,
    pub ha_actions_actif: bool,
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
    /// dernier test de restauration a blanc (script 2.4+)
    pub test: Option<RestoreTest>,
    pub test_en_cours: bool,
}

/// Un fichier du test de restauration
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct TestFile {
    pub destination: String,
    pub chemin: String,
    pub taille: u64,
    /// identique, different, absent ou erreur
    pub resultat: String,
    pub detail: String,
}

/// Test de restauration a blanc (fichiers au hasard restaures puis compares)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct RestoreTest {
    pub debut: i64,
    pub fin: i64,
    /// ok, ecarts, echec ou vide
    pub etat: String,
    pub nb: i64,
    pub identiques: i64,
    pub ecarts: i64,
    pub erreurs: i64,
    /// « gdrive:ok;usb:ecarts »
    pub destinations: String,
    pub message: String,
    pub fichiers: Vec<TestFile>,
}

/// Reveil (Wake-on-LAN) d'une destination
#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct ReveilDest {
    pub mac: String,
    pub adresse: String,
    pub attente: u32,
    /// rien, veille ou arret
    pub apres: String,
    pub ssh: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Reveil {
    /// cle publique pour la remise en veille (vide tant qu'elle n'existe pas)
    pub cle: String,
    pub destinations: std::collections::BTreeMap<String, ReveilDest>,
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
    /// retour a une date : date restauree (secondes, vide sinon)
    pub date: String,
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
    /// canaux de notification, seuils, rapport (script 2.3+)
    pub notif: Option<NotifConf>,
    /// sante des disques et du RAID (script 2.3+)
    pub sante_disques: Option<DiskHealth>,
    /// test de restauration automatique : "JOURS HH:MM NB" ou vide (script 2.4+)
    pub test_auto: String,
    /// reveil des destinations (script 2.4+)
    pub reveil: Option<Reveil>,
    /// migration de la machine vers oCIS et transferts oCIS -> machine (script 2.5+)
    pub migration: Option<Migration>,
    pub transferts: Option<Transferts>,
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

/// Dernier passage d'un transfert oCIS -> machine
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct TrResult {
    /// OK, ECHEC ou ARRETE
    pub etat: String,
    pub debut: i64,
    pub fin: i64,
    pub detail: String,
    pub fichiers: u64,
    pub octets: u64,
    pub supprimes: u64,
}

/// Transfert oCIS -> machine (transferts.conf + dernier passage)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Transfert {
    pub nom: String,
    pub espace_id: String,
    pub espace: String,
    pub sous_dossier: String,
    pub destination: String,
    /// copie ou miroir
    pub mode: String,
    pub corbeille: u32,
    /// manuel, une-fois ou HH:MM[/jours];...
    pub horaire: String,
    pub debit: String,
    pub dernier: Option<TrResult>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct TrRunning {
    pub nom: String,
    pub debut: i64,
    pub espace: String,
    pub sous_dossier: String,
    pub destination: String,
    pub mode: String,
    pub reprise: i64,
    pub avancement: Option<Avancement>,
    pub ram_mo: Option<i64>,
}

/// Transferts oCIS -> machine (nas-debian 2.5+, nas-synology 2.4+)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Transferts {
    pub installe: bool,
    /// connexion oCIS configuree sur la machine
    pub config: bool,
    pub transferts: Vec<Transfert>,
    pub file: Vec<String>,
    pub en_cours: Option<TrRunning>,
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
    /// sante des disques et du RAID (nas-synology 2.2+)
    pub sante_disques: Option<DiskHealth>,
    /// alertes en cours (disques, RAID)
    pub alertes: Vec<Alert>,
    /// transferts oCIS -> Synology (nas-synology 2.4+)
    pub transferts: Option<Transferts>,
}

#[derive(Clone, Debug)]
pub struct Space {
    pub id: String,
    pub name: String,
    pub free: i64,
    pub quota: i64,
    /// project ou personal
    pub kind: String,
}

/// Lignes « id|nom|webDavUrl|libre|quota[|type] » des scripts
pub fn parse_spaces(txt: &str) -> Vec<Space> {
    txt.lines()
        .filter_map(|l| {
            let p: Vec<&str> = l.split('|').collect();
            (p.len() >= 5).then(|| Space {
                id: p[0].to_string(),
                name: p[1].to_string(),
                free: p[3].trim().parse().unwrap_or(-1),
                quota: p[4].trim().parse().unwrap_or(0),
                kind: p.get(5).map(|k| k.trim().to_string()).unwrap_or_else(|| "project".into()),
            })
        })
        .collect()
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

// ---------------- Sante des disques (SMART, RAID) ----------------
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SmartDisk {
    pub dev: String,
    pub modele: String,
    pub serie: String,
    pub taille: Option<u64>,
    #[serde(rename = "type")]
    pub kind: String,
    pub smart_ok: Option<bool>,
    pub temp: Option<i64>,
    pub heures: Option<i64>,
    pub realloues: Option<i64>,
    pub en_attente: Option<i64>,
    pub irreparables: Option<i64>,
    pub crc: Option<i64>,
    pub usure: Option<i64>,
    pub veille: bool,
    /// ok, attention ou critique
    pub etat: String,
    pub raisons: Vec<String>,
    pub tag: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct RaidArray {
    pub nom: String,
    #[serde(rename = "type")]
    pub kind: String,
    /// ok, degrade, reconstruction ou arrete
    pub etat: String,
    pub disques: Vec<String>,
    pub en_panne: Vec<String>,
    pub avancement: Option<f64>,
    pub operation: Option<String>,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct DiskHealth {
    pub verifie: i64,
    pub machine: String,
    /// smartctl present
    pub smart: bool,
    pub disques: Vec<SmartDisk>,
    pub raid: Vec<RaidArray>,
}

impl DiskHealth {
    /// (critiques, a surveiller) : disques et grappes RAID
    pub fn problems(&self) -> (usize, usize) {
        let crit = self.disques.iter().filter(|d| d.etat == "critique").count()
            + self.raid.iter().filter(|r| r.etat != "ok").count();
        let att = self.disques.iter().filter(|d| d.etat == "attention").count();
        (crit, att)
    }
}

// ---------------- Notifications ----------------
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Canal {
    pub cible: String,
    /// tout ou critique
    pub niveau: String,
    pub jeton: bool,
    pub serveur: String,
    pub port: String,
    pub securite: String,
    pub utilisateur: String,
    pub destinataire: String,
    pub expediteur: String,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct RapportConf {
    /// hebdo, mensuel ou non
    pub frequence: String,
    /// 1 = lundi ... 7 = dimanche
    pub jour: u32,
    pub heure: String,
    pub canaux: Vec<String>,
}

impl Default for RapportConf {
    fn default() -> Self {
        Self { frequence: "non".into(), jour: 1, heure: "08:30".into(), canaux: vec![] }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct NotifConf {
    pub canaux: std::collections::BTreeMap<String, Canal>,
    pub rappel_h: u32,
    pub quota_pct: u32,
    pub retard_h: u32,
    /// derniers envois en echec
    pub erreurs: Vec<String>,
    pub rapport: RapportConf,
}

impl Default for NotifConf {
    fn default() -> Self {
        Self { canaux: Default::default(), rappel_h: 12, quota_pct: 90, retard_h: 50, erreurs: vec![], rapport: RapportConf::default() }
    }
}
