//! Reveil des machines par le reseau (Wake-on-LAN) depuis le PC : paquet magique
//! (6 x FF puis 16 fois l'adresse MAC) en UDP, ports 9 et 7, en diffusion.

use std::net::{Ipv4Addr, ToSocketAddrs, UdpSocket};

/// Adresse MAC valide (00:11:22:AA:BB:CC, tirets acceptes)
pub fn valid_mac(s: &str) -> bool {
    parse_mac(s).is_some()
}

pub fn parse_mac(s: &str) -> Option<[u8; 6]> {
    let parts: Vec<&str> = s.trim().split([':', '-']).collect();
    if parts.len() != 6 {
        return None;
    }
    let mut out = [0u8; 6];
    for (i, p) in parts.iter().enumerate() {
        if p.len() != 2 {
            return None;
        }
        out[i] = u8::from_str_radix(p, 16).ok()?;
    }
    Some(out)
}

/// Forme normalisee : 00:11:22:AA:BB:CC
pub fn normalize(s: &str) -> String {
    match parse_mac(s) {
        Some(m) => m.iter().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":"),
        None => s.trim().to_string(),
    }
}

pub fn packet(mac: [u8; 6]) -> Vec<u8> {
    let mut p = vec![0xFFu8; 6];
    for _ in 0..16 {
        p.extend_from_slice(&mac);
    }
    p
}

/// Envoie le paquet de reveil ; `host` (adresse de la machine, facultative) ajoute la
/// diffusion de son reseau (/24) et l'adresse elle-meme. Renvoie le nombre d'envois.
pub fn send(mac: &str, host: &str) -> Result<usize, String> {
    let m = parse_mac(mac).ok_or_else(|| crate::i18n::tf("adresse MAC invalide : {0}", &[&mac]))?;
    let pkt = packet(m);
    let sock = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    sock.set_broadcast(true).map_err(|e| e.to_string())?;
    let mut targets: Vec<Ipv4Addr> = vec![Ipv4Addr::BROADCAST];
    if !host.trim().is_empty() {
        if let Ok(addrs) = (host.trim(), 9).to_socket_addrs() {
            for a in addrs {
                if let std::net::IpAddr::V4(ip) = a.ip() {
                    let o = ip.octets();
                    targets.push(Ipv4Addr::new(o[0], o[1], o[2], 255));
                    targets.push(ip);
                }
            }
        }
    }
    targets.dedup();
    let mut n = 0;
    for t in &targets {
        for port in [9u16, 7] {
            if sock.send_to(&pkt, (*t, port)).is_ok() {
                n += 1;
            }
        }
    }
    if n == 0 {
        Err(crate::i18n::tr("envoi du paquet de réveil impossible").into())
    } else {
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adresses_mac() {
        assert!(valid_mac("00:11:22:aa:BB:cc") && valid_mac("00-11-22-AA-BB-CC"));
        assert!(!valid_mac("00:11:22:aa:bb") && !valid_mac("0:11:22:aa:bb:cc") && !valid_mac("zz:11:22:aa:bb:cc") && !valid_mac(""));
        assert_eq!(normalize(" 00-11-22-aa-bb-cc "), "00:11:22:AA:BB:CC");
    }
    #[test]
    fn paquet_magique() {
        let p = packet([0, 0x11, 0x22, 0xAA, 0xBB, 0xCC]);
        assert_eq!(p.len(), 102);
        assert_eq!(&p[..6], &[0xFF; 6]);
        assert_eq!(&p[96..], &[0, 0x11, 0x22, 0xAA, 0xBB, 0xCC]);
    }
    #[test]
    fn envoi_local() {
        let r = UdpSocket::bind("127.0.0.1:0").unwrap();
        r.set_read_timeout(Some(std::time::Duration::from_secs(3))).unwrap();
        // envoi direct a l'adresse (le port 9 est remplace par celui du recepteur pour le test)
        let s = UdpSocket::bind("0.0.0.0:0").unwrap();
        s.send_to(&packet(parse_mac("00:11:22:AA:BB:CC").unwrap()), r.local_addr().unwrap()).unwrap();
        let mut buf = [0u8; 200];
        let (n, _) = r.recv_from(&mut buf).unwrap();
        assert_eq!(n, 102);
        assert!(send("00:11:22:AA:BB:CC", "127.0.0.1").unwrap() >= 2);
        assert!(send("pas une mac", "").is_err());
    }
}
