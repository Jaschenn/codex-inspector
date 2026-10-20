use crate::{config, util};
use regex::Regex;
use serde::Serialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path};

pub struct RawProcess {
    pub pid: u32,
    user: String,
    etime: String,
    cmdline: String,
}
#[derive(Default, Serialize)]
struct Overrides {
    profile: Option<String>,
    cd: Option<String>,
    config_path: Option<String>,
    codex_home: Option<String>,
    c_overrides: Vec<(String, Value)>,
}
fn overrides(cmdline: &str) -> Overrides {
    let tokens = shlex::split(cmdline)
        .unwrap_or_else(|| cmdline.split_whitespace().map(str::to_owned).collect());
    let mut result = Overrides::default();
    let mut i = 1;
    while i < tokens.len() {
        let (flag, inline) = tokens[i]
            .split_once('=')
            .map(|(a, b)| (a, Some(b.to_owned())))
            .unwrap_or((&tokens[i], None));
        if ["--profile", "--cd", "-C", "--config", "-c"].contains(&flag) {
            let value = inline.clone().or_else(|| tokens.get(i + 1).cloned());
            if let Some(value) = value {
                match flag {
                    "--profile" => result.profile = Some(value),
                    "--cd" | "-C" => result.cd = Some(value),
                    "--config" => result.config_path = Some(value),
                    "-c" => {
                        if let Some((key, raw)) = value.split_once('=') {
                            let value = config::scalar(raw);
                            if key.trim() == "codex_home" {
                                result.codex_home = value.as_str().map(str::to_owned);
                            }
                            result.c_overrides.push((key.trim().to_owned(), value));
                        }
                    }
                    _ => {}
                }
                i += if inline.is_some() { 1 } else { 2 };
                continue;
            }
        }
        i += 1;
    }
    result
}
pub fn scan() -> Result<Vec<RawProcess>, String> {
    let (ok, output, error) = util::command("/bin/ps", &["-axo", "pid=,user=,etime=,command="])?;
    if !ok {
        return Err(format!("无法列出进程: {error}"));
    }
    let pattern = Regex::new(r"^\s*(\d+)\s+(\S+)\s+(\S+)\s+(.*)$").map_err(|e| e.to_string())?;
    let mut result = Vec::new();
    for line in output.lines() {
        let Some(caps) = pattern.captures(line) else {
            continue;
        };
        let cmd = &caps[4];
        let first = cmd.split_whitespace().next().unwrap_or("");
        if Path::new(first)
            .file_name()
            .is_some_and(|n| n == "codex" || n == "codex.exe")
        {
            if let Ok(pid) = caps[1].parse() {
                result.push(RawProcess {
                    pid,
                    user: caps[2].into(),
                    etime: caps[3].into(),
                    cmdline: cmd.into(),
                });
            }
        }
    }
    Ok(result)
}
#[cfg(target_os = "macos")]
fn native_env(pid: u32) -> Option<BTreeMap<String, String>> {
    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        i32::try_from(pid).ok()?,
    ];
    let mut size: libc::size_t = 0;
    // sysctl writes only into the sized buffer below; process arguments are local, read-only evidence.
    unsafe {
        if libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        ) != 0
            || size < 4
        {
            return None;
        }
        let mut data = vec![0_u8; size];
        if libc::sysctl(
            mib.as_mut_ptr(),
            3,
            data.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        data.truncate(size);
        let argc = i32::from_ne_bytes(data.get(..4)?.try_into().ok()?);
        if argc < 0 {
            return None;
        }
        let mut position = 4 + data.get(4..)?.iter().position(|b| *b == 0)? + 1;
        while data.get(position) == Some(&0) {
            position += 1;
        }
        for _ in 0..argc {
            position += data.get(position..)?.iter().position(|b| *b == 0)? + 1;
        }
        let mut result = BTreeMap::new();
        for entry in data.get(position..)?.split(|b| *b == 0) {
            if let Ok(entry) = std::str::from_utf8(entry) {
                if let Some((k, v)) = entry.split_once('=') {
                    result.insert(k.into(), v.into());
                }
            }
        }
        if result.is_empty() {
            None
        } else {
            Some(result)
        }
    }
}
#[cfg(not(target_os = "macos"))]
fn native_env(_pid: u32) -> Option<BTreeMap<String, String>> {
    None
}
fn env(pid: u32) -> (BTreeMap<String, String>, &'static str) {
    if let Some(env) = native_env(pid) {
        return (env, "ok");
    }
    let output = util::command("/bin/ps", &["eww", "-p", &pid.to_string()])
        .map(|(_, o, _)| o)
        .unwrap_or_default();
    let mut result = BTreeMap::new();
    for token in output.lines().nth(1).unwrap_or("").split_whitespace() {
        if let Some((k, v)) = token.split_once('=') {
            if k.chars()
                .enumerate()
                .all(|(i, c)| c == '_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
                && !k.is_empty()
            {
                result.insert(k.into(), v.into());
            }
        }
    }
    let status = if result.is_empty() {
        "unavailable"
    } else {
        "partial"
    };
    (result, status)
}
pub fn inspect(process: &RawProcess) -> Result<Value, String> {
    let (cwd, error) = match util::command(
        "/usr/sbin/lsof",
        &["-a", "-p", &process.pid.to_string(), "-d", "cwd", "-Fn"],
    ) {
        Ok((true, out, _)) => match out.lines().find_map(|l| l.strip_prefix('n')) {
            Some(s) => (Some(s.to_owned()), None),
            None => (None, Some("lsof 未返回 cwd 条目".to_owned())),
        },
        Ok((false, _, err)) => (
            None,
            Some(format!("lsof 读取失败(可能是权限不足或进程已退出): {err}")),
        ),
        Err(err) => (None, Some(err)),
    };
    let (env, status) = env(process.pid);
    let overrides = overrides(&process.cmdline);
    let home = overrides
        .codex_home
        .as_ref()
        .or_else(|| env.get("CODEX_HOME"))
        .map(|s| util::expand(s))
        .unwrap_or_else(|| util::home().join(".codex"));
    let effective = overrides
        .cd
        .as_ref()
        .or(cwd.as_ref())
        .map(|s| util::expand(s))
        .unwrap_or(std::env::current_dir().map_err(|e| e.to_string())?);
    let mut report = config::report(
        &home,
        &effective,
        overrides.profile.as_deref(),
        &overrides.c_overrides,
    );
    let mut warnings = Vec::new();
    if let Some(error) = &error {
        warnings.push(format!("cwd: {error}"));
    }
    if status != "ok" {
        warnings.push(
            if status == "partial" {
                "环境变量读取不完整(值含空格的变量可能被截断)"
            } else {
                "环境变量读取失败,可能受系统权限限制"
            }
            .into(),
        );
    }
    if report["is_git_repo"] == true && report["trust_level"] == "unknown" {
        warnings.push("该项目是 git 仓库,但全局配置没有 trust 记录，项目层配置可能不会生效".into());
    }
    report["pid"] = json!(process.pid);
    report["user"] = json!(process.user);
    report["etime"] = json!(process.etime);
    report["cmdline"] = json!(process.cmdline);
    report["cwd"] = json!(cwd);
    report["cwd_error"] = json!(error);
    report["env_status"] = json!(status);
    report["cli_overrides"] = serde_json::to_value(overrides).map_err(|e| e.to_string())?;
    report["warnings"] = json!(warnings);
    Ok(report)
}
