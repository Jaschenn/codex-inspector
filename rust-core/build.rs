use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.lock");
    // Derive the table from the locked tokenizer dependency rather than downloading or
    // maintaining a second vocabulary. Rank is implicit in record order; every byte is retained.
    let encoding = tiktoken_rs::o200k_base().expect("load official o200k_base vocabulary");
    let mut vocabulary = Vec::new();
    for rank in 0..199_998 {
        let token = encoding
            .decode_bytes(&[rank])
            .expect("decode vocabulary rank");
        let length = u16::try_from(token.len()).expect("token length fits in u16");
        vocabulary.extend_from_slice(&length.to_le_bytes());
        vocabulary.extend_from_slice(&token);
    }
    let compressed =
        zstd::stream::encode_all(vocabulary.as_slice(), 19).expect("compress embedded vocabulary");
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo build output"));
    fs::write(output.join("o200k_base.bin.zst"), compressed).expect("write embedded vocabulary");
}
