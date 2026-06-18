// Standard TOTP (RFC 6238): HMAC-SHA1, 30s step, 6 digits.
use byteorder::{BigEndian, ReadBytesExt, WriteBytesExt};
use hmacsha1::{hmac_sha1, SHA1_DIGEST_BYTES};
use std::io::Cursor;
use std::time;

const DIGITS: u32 = 6;
const TIME_STEP: u64 = 30;

pub fn totp_offset(key: &[u8], slot_offset: i32) -> TotpSlot {
    let now = time::SystemTime::now()
        .duration_since(time::UNIX_EPOCH)
        .expect("Current time is before unix epoch");
    let slot = (now.as_secs() / TIME_STEP) as i64 + slot_offset as i64;

    let mut counter_bytes = vec![];
    counter_bytes.write_u64::<BigEndian>(slot as u64).unwrap();
    let hmac = hmac_sha1(key, &counter_bytes);
    let dyn_offset = (hmac[SHA1_DIGEST_BYTES - 1] & 0xf) as usize;
    let dyn_range = &hmac[dyn_offset..dyn_offset + 4];
    let mut rdr = Cursor::new(dyn_range);
    let s_num = rdr.read_u32::<BigEndian>().unwrap() & 0x7fffffff;
    let code = s_num % 10u32.pow(DIGITS);
    let secs_left = (TIME_STEP - now.as_secs() % TIME_STEP) as u32;
    TotpSlot { code, secs_left }
}

#[derive(Debug)]
pub struct TotpSlot {
    pub code: u32,
    pub secs_left: u32,
}

pub fn b32_decode(s: &str) -> anyhow::Result<Vec<u8>> {
    base32::decode(base32::Alphabet::RFC4648 { padding: true }, s)
        .ok_or_else(|| anyhow::anyhow!("failed to decode base32 secret"))
}

pub fn generate_code(secret_b32: &str) -> anyhow::Result<(String, u32)> {
    let key = b32_decode(secret_b32)?;
    let slot = totp_offset(key.as_slice(), 0);
    Ok((format!("{:06}", slot.code), slot.secs_left))
}
