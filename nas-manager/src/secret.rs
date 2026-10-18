//! Memorisation du mot de passe sudo : chiffre avec DPAPI (lie au compte Windows).
//! Hors Windows, rien n'est memorise.



pub fn can_store() -> bool {
    cfg!(windows)
}

#[cfg(windows)]
pub fn protect(plain: &str) -> Option<String> {
    use base64::Engine;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut data = plain.as_bytes().to_vec();
    let input = CRYPT_INTEGER_BLOB {
        cbData: data.len() as u32,
        pbData: data.as_mut_ptr(),
    };
    let mut out = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // SAFETY: appel DPAPI documente ; la memoire de sortie est liberee par LocalFree.
    unsafe {
        let ok = CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        );
        if ok == 0 || out.pbData.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(out.pbData as _);
        Some(base64::engine::general_purpose::STANDARD.encode(bytes))
    }
}

#[cfg(windows)]
pub fn unprotect(stored: &str) -> Option<String> {
    use base64::Engine;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut data = base64::engine::general_purpose::STANDARD
        .decode(stored.trim())
        .ok()?;
    let input = CRYPT_INTEGER_BLOB {
        cbData: data.len() as u32,
        pbData: data.as_mut_ptr(),
    };
    let mut out = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // SAFETY: idem protect()
    unsafe {
        let ok = CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out,
        );
        if ok == 0 || out.pbData.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(out.pbData as _);
        String::from_utf8(bytes).ok()
    }
}

#[cfg(not(windows))]
pub fn protect(_plain: &str) -> Option<String> {
    None
}

#[cfg(not(windows))]
pub fn unprotect(_stored: &str) -> Option<String> {
    let _ = base64::engine::general_purpose::STANDARD;
    None
}
