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
    codex_home: Option<String>,
    c_overrides: Vec<(String, Value)>,
}
fn overrides(cmdline: &str) -> Overrides {
    let tokens = shlex::split(cmdline)
        .unwrap_or_else(|| cmdline.split_whitespace().map(str::to_owned).collect());
    overrides_from_arguments(&tokens)
}

fn overrides_from_arguments(tokens: &[String]) -> Overrides {
    let mut result = Overrides::default();
    let mut dedicated = Vec::new();
    let mut i = 1;
    while i < tokens.len() {
        if tokens[i] == "--" {
            break;
        }
        if [
            "--search",
            "--yolo",
            "--dangerously-bypass-approvals-and-sandbox",
        ]
        .contains(&tokens[i].as_str())
        {
            if tokens[i] == "--search" {
                dedicated.push(("web_search".into(), json!("live")));
            } else {
                dedicated.push(("approval_policy".into(), json!("never")));
                dedicated.push(("sandbox_mode".into(), json!("danger-full-access")));
            }
            i += 1;
            continue;
        }
        let token = &tokens[i];
        let (flag, inline) = if token.len() > 2
            && ["-c", "-p", "-C", "-m", "-s", "-a"]
                .iter()
                .any(|flag| token.starts_with(flag))
        {
            (
                &token[..2],
                Some(
                    token[2..]
                        .strip_prefix('=')
                        .unwrap_or(&token[2..])
                        .to_owned(),
                ),
            )
        } else {
            token
                .split_once('=')
                .map(|(a, b)| (a, Some(b.to_owned())))
                .unwrap_or((token.as_str(), None))
        };
        if [
            "--profile",
            "-p",
            "--cd",
            "-C",
            "--config",
            "-c",
            "--model",
            "-m",
            "--sandbox",
            "-s",
            "--ask-for-approval",
            "-a",
            "--enable",
            "--disable",
        ]
        .contains(&flag)
        {
            let value = inline.clone().or_else(|| tokens.get(i + 1).cloned());
            if let Some(value) = value {
                match flag {
                    "--profile" | "-p" => result.profile = Some(value),
                    "--cd" | "-C" => result.cd = Some(value),
                    "--config" | "-c" => {
                        if let Some((key, raw)) = value.split_once('=') {
                            if key.trim().is_empty() {
                                i += if inline.is_some() { 1 } else { 2 };
                                continue;
                            }
                            let value = config::scalar(raw);
                            if key.trim() == "codex_home" {
                                result.codex_home = value.as_str().map(str::to_owned);
                            }
                            result.c_overrides.push((key.trim().to_owned(), value));
                        }
                    }
                    "--model" | "-m" => dedicated.push(("model".into(), json!(value))),
                    "--sandbox" | "-s" => dedicated.push(("sandbox_mode".into(), json!(value))),
                    "--ask-for-approval" | "-a" => {
                        dedicated.push(("approval_policy".into(), json!(value)))
                    }
                    "--enable" | "--disable" => {
                        dedicated.push((format!("features.{value}"), json!(flag == "--enable")))
                    }
                    _ => {}
                }
                i += if inline.is_some() { 1 } else { 2 };
                continue;
            }
        }
        i += 1;
    }
    // Dedicated clap fields override arbitrary config values, independent of argument order.
    result.c_overrides.extend(dedicated);
    result
}
pub fn scan() -> Result<Vec<RawProcess>, String> {
    #[cfg(target_os = "macos")]
    if let Some(processes) = native_scan() {
        return Ok(processes);
    }
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
fn native_arguments(pid: u32) -> Option<(Vec<String>, BTreeMap<String, String>)> {
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
        let mut arguments = Vec::new();
        for _ in 0..argc {
            let length = data.get(position..)?.iter().position(|b| *b == 0)?;
            arguments.push(
                std::str::from_utf8(data.get(position..position + length)?)
                    .ok()?
                    .to_owned(),
            );
            position += length + 1;
        }
        let mut result = BTreeMap::new();
        for entry in data.get(position..)?.split(|b| *b == 0) {
            if let Ok(entry) = std::str::from_utf8(entry) {
                if let Some((k, v)) = entry.split_once('=') {
                    result.insert(k.into(), v.into());
                }
            }
        }
        Some((arguments, result))
    }
}
#[cfg(target_os = "macos")]
fn native_env(pid: u32) -> Option<BTreeMap<String, String>> {
    native_arguments(pid)
        .map(|(_, env)| env)
        .filter(|env| !env.is_empty())
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
    let (cwd, error) = if let Some(cwd) = native_cwd(process.pid) {
        (Some(cwd), None)
    } else {
        match util::command(
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
        }
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
    let mut warnings: Vec<String> = report["warnings"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
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

#[cfg(target_os = "macos")]
fn native_cwd(pid: u32) -> Option<String> {
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>();
    let mut info = std::mem::MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
    // libproc returns the cwd without launching lsof for every process and refresh.
    // Only interpret the buffer when the kernel returned the complete structure.
    let bytes = unsafe {
        libc::proc_pidinfo(
            i32::try_from(pid).ok()?,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            info.as_mut_ptr().cast(),
            i32::try_from(size).ok()?,
        )
    };
    if usize::try_from(bytes).ok()? != size {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let path: Vec<u8> = info
        .pvi_cdir
        .vip_path
        .iter()
        .flatten()
        .take_while(|c| **c != 0)
        .map(|c| *c as u8)
        .collect();
    String::from_utf8(path).ok().filter(|p| p.starts_with('/'))
}

#[cfg(not(target_os = "macos"))]
fn native_cwd(_pid: u32) -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn native_scan() -> Option<Vec<RawProcess>> {
    use std::ffi::CStr;
    // Enumerate IDs and names first; fetch arguments/owner/start time only for
    // Codex. This avoids ps formatting every process's entire command line.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return None;
    }
    let mut pids = vec![0_i32; count as usize + 256];
    let size = i32::try_from(pids.len() * std::mem::size_of::<i32>()).ok()?;
    let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), size) };
    if count <= 0 || count as usize >= pids.len() {
        return None;
    }
    pids.truncate(count as usize);
    pids.sort_unstable();
    let mut result = Vec::new();
    for pid in pids.into_iter().filter(|pid| *pid > 0) {
        let mut name = [0_u8; 1024];
        let length = unsafe { libc::proc_name(pid, name.as_mut_ptr().cast(), name.len() as u32) };
        if length <= 0 || name.split(|b| *b == 0).next()? != b"codex" {
            continue;
        }
        let (arguments, _) = native_arguments(pid as u32)?;
        let first = arguments.first()?;
        if Path::new(first)
            .file_name()
            .is_none_or(|name| name != "codex")
        {
            continue;
        }
        let size = std::mem::size_of::<libc::proc_bsdinfo>();
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let length = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size as i32,
            )
        };
        if length as usize != size {
            return None;
        }
        let info = unsafe { info.assume_init() };
        let owner = unsafe { libc::getpwuid(info.pbi_uid) };
        let user = if owner.is_null() {
            info.pbi_uid.to_string()
        } else {
            unsafe { CStr::from_ptr((*owner).pw_name) }
                .to_string_lossy()
                .into_owned()
        };
        let seconds =
            (chrono::Utc::now().timestamp().max(0) as u64).saturating_sub(info.pbi_start_tvsec);
        let etime = if seconds >= 86400 {
            format!(
                "{}-{:02}:{:02}:{:02}",
                seconds / 86400,
                seconds / 3600 % 24,
                seconds / 60 % 60,
                seconds % 60
            )
        } else if seconds >= 3600 {
            format!(
                "{:02}:{:02}:{:02}",
                seconds / 3600,
                seconds / 60 % 60,
                seconds % 60
            )
        } else {
            format!("{:02}:{:02}", seconds / 60, seconds % 60)
        };
        let cmdline = arguments
            .iter()
            .map(|s| shlex::try_quote(s).ok().map(|s| s.into_owned()))
            .collect::<Option<Vec<_>>>()?
            .join(" ");
        result.push(RawProcess {
            pid: pid as u32,
            user,
            etime,
            cmdline,
        });
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_short_options_keep_their_values() {
        let result = overrides(
            "codex -preview -C'/path with spaces' -cmodel=generic -mselected -sread-only -aon-request",
        );
        assert_eq!(result.profile.as_deref(), Some("review"));
        assert_eq!(result.cd.as_deref(), Some("/path with spaces"));
        assert_eq!(
            result.c_overrides,
            vec![
                ("model".into(), json!("generic")),
                ("model".into(), json!("selected")),
                ("sandbox_mode".into(), json!("read-only")),
                ("approval_policy".into(), json!("on-request"))
            ]
        );
    }

    #[test]
    fn long_config_alias_supports_repeatable_toml_values_and_spaces() {
        let parsed = overrides(
            "codex --config 'model=with spaces' -c 'features.apps=false' --config='items=[1, 2]'",
        );
        assert_eq!(
            parsed.c_overrides,
            vec![
                ("model".into(), json!("with spaces")),
                ("features.apps".into(), json!(false)),
                ("items".into(), json!([1, 2]))
            ]
        );
    }
    #[test]
    fn dedicated_flags_take_precedence_and_end_of_options_is_respected() {
        let parsed = overrides(
            "codex -p review --cd='/project with spaces' -m selected --config model=generic --search --disable apps -- --config model=prompt",
        );
        assert_eq!(parsed.profile.as_deref(), Some("review"));
        assert_eq!(parsed.cd.as_deref(), Some("/project with spaces"));
        assert_eq!(
            parsed.c_overrides,
            vec![
                ("model".into(), json!("generic")),
                ("model".into(), json!("selected")),
                ("web_search".into(), json!("live")),
                ("features.apps".into(), json!(false))
            ]
        );
    }
    #[test]
    fn argument_roundtrip_keeps_prompt_and_config_as_distinct_values() {
        let arguments = [
            "codex",
            "exec",
            "a prompt containing --config model=wrong",
            "--config",
            "model='with spaces'",
        ];
        let command = arguments
            .iter()
            .map(|argument| shlex::try_quote(argument).unwrap().into_owned())
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(
            overrides(&command).c_overrides,
            vec![("model".into(), json!("with spaces"))]
        );
    }
}
