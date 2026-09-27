//! Bounded NDJSON worker. Paths are data, never shell fragments. The inventory
//! stays in the app; only explicitly discovered candidates cross this boundary.
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void, CString};
use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::os::macos::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc, Arc,
};
use std::time::{Duration, Instant};

const MAX_LINE: usize = 8 * 1024 * 1024;
const MAX_ITEMS: usize = 20_000;
const FAMILIES: &str = include_str!("../../integration/mole/families.txt");

#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    dev: u64,
    ino: u64,
    modified: i64,
    nanos: i64,
    changed: i64,
    changed_nanos: i64,
    length: u64,
    uid: u32,
    mode: u32,
}
fn identity(path: &Path) -> Result<Identity, String> {
    let m = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if m.file_type().is_symlink() || m.st_flags() & 0x40000000 != 0 {
        return Err("Symlink or cloud placeholder; inspect in Finder".into());
    }
    Ok(Identity {
        dev: m.st_dev() as u64,
        ino: m.st_ino(),
        modified: m.st_mtime(),
        nanos: m.st_mtime_nsec(),
        changed: m.st_ctime(),
        changed_nanos: m.st_ctime_nsec(),
        length: m.st_size(),
        uid: m.st_uid(),
        mode: m.st_mode() as u32,
    })
}
#[derive(Clone)]
struct Candidate {
    path: PathBuf,
    lineage: Vec<(PathBuf, Identity)>,
    kind: String,
}

/// Bind every ancestor as well as the target: replacing an ancestor with a
/// symlink cannot redirect a later move outside the approved containment root.
fn snapshot(
    path: &Path,
    home: &Path,
    root: &Path,
    exclusions: &[PathBuf],
) -> Result<Vec<(PathBuf, Identity)>, String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err("Expected an absolute path without traversal components".into());
    }
    if path == home || path == root || !path.starts_with(home) || !path.starts_with(root) {
        return Err("Outside the scanned, user-owned cleanup scope".into());
    }
    if exclusions
        .iter()
        .any(|p| path.starts_with(p) || p.starts_with(path))
    {
        return Err("Excluded by your cleanup preferences".into());
    }
    let mut lineage = Vec::new();
    for p in path.ancestors() {
        let i = identity(p)?;
        if p == path && i.uid != unsafe { libc::getuid() } {
            return Err("Not owned by this user".into());
        }
        lineage.push((p.to_path_buf(), i));
    }
    Ok(lineage)
}
fn same(lineage: &[(PathBuf, Identity)]) -> Result<(), String> {
    for (index, (path, expected)) in lineage.iter().enumerate() {
        let actual = identity(path)?;
        // Parent mtimes change when unrelated siblings are created; identity/ownership
        // of parents matters, while target metadata is part of the approved snapshot.
        let matches = if index == 0 {
            actual == *expected
        } else {
            (actual.dev, actual.ino, actual.uid, actual.mode)
                == (expected.dev, expected.ino, expected.uid, expected.mode)
        };
        if !matches {
            return Err("The file or an ancestor changed; rescan before cleanup".into());
        }
    }
    Ok(())
}
fn field<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Missing {key}"))
}
fn emit(id: &Value, event: &str, body: Value) {
    println!("{}", json!({"version":1,"id":id,"event":event,"body":body}));
    let _ = io::stdout().flush();
}
/// A private per-probe temp root keeps Mole state separate without changing HOME.
struct ProbeTemp(PathBuf);
impl ProbeTemp {
    fn new() -> Result<Self, String> {
        let pattern = std::env::temp_dir().join("burrowbolt-probe.XXXXXX");
        let mut bytes = CString::new(pattern.as_os_str().as_encoded_bytes())
            .map_err(|e| e.to_string())?
            .into_bytes_with_nul();
        if unsafe { libc::mkdtemp(bytes.as_mut_ptr().cast()) }.is_null() {
            return Err(io::Error::last_os_error().to_string());
        }
        Ok(Self(PathBuf::from(
            std::ffi::CStr::from_bytes_with_nul(&bytes)
                .unwrap()
                .to_string_lossy()
                .into_owned(),
        )))
    }
    fn command(&self, adapter: &Path, home: &Path) -> Command {
        let mut command = Command::new("/bin/bash");
        command
            .arg(adapter)
            .env_clear()
            .env("HOME", home)
            .env(
                "PATH",
                "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            )
            .env("TMPDIR", &self.0)
            .env("LANG", "en_US.UTF-8")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0);
        command
    }
}
impl Drop for ProbeTemp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn stop_child(child: &mut Child) -> Result<(), String> {
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    if child.try_wait().map_err(|e| e.to_string())?.is_some() {
        return Ok(());
    }
    child
        .kill()
        .map_err(|e| format!("Could not stop cleanup probe: {e}"))?;
    // kill succeeded; reap the direct owned child, never an unrelated process.
    child.wait().map_err(|e| e.to_string())?;
    Ok(())
}
fn guard(
    candidate: &Candidate,
    root: &Path,
    home: &Path,
    adapter: &Path,
    epoch: &AtomicU64,
    expected: u64,
) -> Result<(), String> {
    same(&candidate.lineage)?;
    if epoch.load(Ordering::Relaxed) != expected {
        return Err("Cancelled".into());
    }
    let temp = ProbeTemp::new()?;
    let mut child = temp
        .command(adapter, home)
        .arg(&candidate.path)
        .arg(&candidate.kind)
        .arg(root)
        .spawn()
        .map_err(|e| format!("Mole guard unavailable: {e}"))?;
    let stdout = child.stdout.take().unwrap();
    let (granted, signal) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        for line in io::BufReader::new(stdout).lines().take(2) {
            if matches!(line.as_deref(), Ok("allowed")) {
                let _ = granted.send(());
                break;
            }
        }
    });
    let start = Instant::now();
    loop {
        if signal.try_recv().is_ok() {
            stop_child(&mut child)?;
            return same(&candidate.lineage);
        }
        if epoch.load(Ordering::Relaxed) != expected || start.elapsed() > Duration::from_secs(15) {
            stop_child(&mut child)?;
            return Err("Guard cancelled or timed out; eligibility is unknown".into());
        }
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(s) if s.success() => {
                if signal.recv_timeout(Duration::from_millis(100)).is_ok() {
                    break;
                }
                return Err("Mole did not produce an exact-item grant".into());
            }
            Some(s) => {
                return Err(format!(
                    "Mole refused this action (guard {}); it remains informational",
                    s.code().unwrap_or(-1)
                ))
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
    same(&candidate.lineage)
}

fn discover_family(
    family: &str,
    adapter: &Path,
    root: &Path,
    home: &Path,
    epoch: &AtomicU64,
    expected: u64,
) -> Result<Vec<(String, String, String)>, String> {
    if !FAMILIES.lines().any(|f| f == family) {
        return Err("Unknown cleanup family".into());
    }
    let temp = ProbeTemp::new()?;
    let mut child = temp
        .command(adapter, home)
        .arg("/")
        .arg(format!("discover:{family}"))
        .arg(root)
        .spawn()
        .map_err(|e| e.to_string())?;
    let output = child.stdout.take().unwrap();
    let (send, reader) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = output
            .take((MAX_LINE + 1) as u64)
            .read_to_end(&mut bytes)
            .map(|_| bytes);
        let _ = send.send(result);
    });
    let start = Instant::now();
    loop {
        if epoch.load(Ordering::Relaxed) != expected || start.elapsed() > Duration::from_secs(25) {
            stop_child(&mut child)?;
            return Err(
                "Discovery cancelled or timed out; partial family output was discarded".into(),
            );
        }
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) if status.success() => break,
            Some(_) => {
                stop_child(&mut child)?;
                return Err("Mole family probe failed; eligibility is unknown".into());
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
    stop_child(&mut child)?;
    let bytes = reader
        .recv_timeout(Duration::from_secs(1))
        .map_err(|_| "Incomplete family output")?
        .map_err(|e| e.to_string())?;
    if bytes.len() > MAX_LINE {
        return Err("Family output exceeds the bounded protocol limit".into());
    }
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.last() != Some(&0) {
        return Err("Incomplete discovery record".into());
    }
    let fields: Vec<_> = bytes[..bytes.len() - 1].split(|b| *b == 0).collect();
    if fields.len() % 3 != 0 {
        return Err("Malformed discovery record".into());
    }
    fields
        .chunks_exact(3)
        .map(|f| {
            Ok((
                String::from_utf8(f[0].to_vec()).map_err(|_| "Invalid path encoding")?,
                String::from_utf8(f[1].to_vec()).map_err(|_| "Invalid action encoding")?,
                String::from_utf8(f[2].to_vec()).map_err(|_| "Invalid description encoding")?,
            ))
        })
        .collect()
}

// Native Foundation Trash API works on macOS 14 without Homebrew or Finder automation.
#[link(name = "Foundation", kind = "framework")]
extern "C" {}
#[link(name = "objc")]
extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn objc_msgSend();
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}
unsafe fn sel(name: &str) -> *mut c_void {
    sel_registerName(CString::new(name).unwrap().as_ptr())
}
unsafe fn object(receiver: *mut c_void, name: &str) -> *mut c_void {
    let call: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        std::mem::transmute(objc_msgSend as *const ());
    call(receiver, sel(name))
}
#[cfg(not(test))]
fn trash(path: &Path) -> Result<String, String> {
    let path = CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| "Invalid path")?;
    unsafe {
        let pool = objc_autoreleasePoolPush();
        let string_call: unsafe extern "C" fn(
            *mut c_void,
            *mut c_void,
            *const c_char,
        ) -> *mut c_void = std::mem::transmute(objc_msgSend as *const ());
        let text = string_call(
            objc_getClass(c"NSString".as_ptr()),
            sel("stringWithUTF8String:"),
            path.as_ptr(),
        );
        let url_call: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const ());
        let url = url_call(
            objc_getClass(c"NSURL".as_ptr()),
            sel("fileURLWithPath:"),
            text,
        );
        let manager = object(objc_getClass(c"NSFileManager".as_ptr()), "defaultManager");
        let mut destination = std::ptr::null_mut();
        let mut error = std::ptr::null_mut();
        let call: unsafe extern "C" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut *mut c_void,
            *mut *mut c_void,
        ) -> i8 = std::mem::transmute(objc_msgSend as *const ());
        let ok = call(
            manager,
            sel("trashItemAtURL:resultingItemURL:error:"),
            url,
            &mut destination,
            &mut error,
        );
        let result = if ok != 0 && !destination.is_null() {
            let name = object(destination, "path");
            let bytes = object(name, "UTF8String") as *const c_char;
            Ok(std::ffi::CStr::from_ptr(bytes)
                .to_string_lossy()
                .into_owned())
        } else {
            Err("macOS could not move this item to Trash; nothing was permanently removed".into())
        };
        objc_autoreleasePoolPop(pool);
        result
    }
}

#[cfg(test)]
fn trash(path: &Path) -> Result<String, String> {
    let destination = path.parent().unwrap().join("fixture-trash");
    fs::create_dir_all(&destination).map_err(|e| e.to_string())?;
    let destination = destination.join(path.file_name().unwrap());
    fs::rename(path, &destination).map_err(|e| e.to_string())?;
    Ok(destination.to_string_lossy().into_owned())
}

struct Session {
    generation: String,
    epoch: u64,
    root: PathBuf,
    home: PathBuf,
    exclusions: Vec<PathBuf>,
    candidates: HashMap<String, Candidate>,
    plan: HashSet<String>,
    token: String,
    discovered: HashMap<String, String>,
    archives: HashMap<String, Candidate>,
    seen: HashSet<String>,
    receipts: HashMap<String, (PathBuf, Vec<(PathBuf, Identity)>)>,
}
impl Session {
    fn new() -> Self {
        Self {
            generation: String::new(),
            epoch: 0,
            root: PathBuf::new(),
            home: PathBuf::from(std::env::var_os("HOME").unwrap_or_default()),
            exclusions: Vec::new(),
            candidates: HashMap::new(),
            plan: HashSet::new(),
            token: String::new(),
            discovered: HashMap::new(),
            archives: HashMap::new(),
            seen: HashSet::new(),
            receipts: HashMap::new(),
        }
    }
    fn handle(
        &mut self,
        v: &Value,
        adapter: &Path,
        epoch: &AtomicU64,
        expected: u64,
    ) -> Result<(), String> {
        if v["version"] != 1 {
            return Err("Unsupported protocol version".into());
        }
        let id = &v["id"];
        match field(v, "op")? {
            "discover" | "discoverMore" => {
                if v["op"] == "discoverMore" {
                    self.require_generation(v, expected)?;
                } else {
                    self.generation = field(v, "generation")?.into();
                    self.epoch = expected;
                    self.root = fs::canonicalize(field(v, "root")?).map_err(|e| e.to_string())?;
                    self.home = fs::canonicalize(&self.home).map_err(|e| e.to_string())?;
                    self.candidates.clear();
                    self.archives.clear();
                    self.discovered.clear();
                    self.seen.clear();
                    self.plan.clear();
                    self.token.clear();
                    self.exclusions = v["exclusions"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(Value::as_str)
                                .map(PathBuf::from)
                                .collect()
                        })
                        .unwrap_or_default();
                }
                let items = v["items"].as_array().ok_or("Missing candidates")?;
                if items.len() > MAX_ITEMS {
                    return Err("Too many candidates in one request".into());
                }
                for item in items {
                    if epoch.load(Ordering::Relaxed) != expected {
                        return Err("Cancelled".into());
                    }
                    let key = field(item, "candidateID")?.to_owned();
                    if !self.seen.insert(key.clone()) {
                        return Err("Duplicate candidate ID".into());
                    }
                    let original = PathBuf::from(field(item, "path")?);
                    // Data-volume firmlinks are an inventory alias, not arbitrary symlinks.
                    let path = if let Ok(relative) = original.strip_prefix("/System/Volumes/Data") {
                        Path::new("/").join(relative)
                    } else {
                        original
                    };
                    let path_root = if self.root == Path::new("/System/Volumes/Data") {
                        Path::new("/")
                    } else {
                        &self.root
                    };
                    let kind = field(item, "category")?.to_owned();
                    let mut result = item.clone();
                    let outcome = if item["complete"] != true {
                        Err("Scan is incomplete; rescan with access before cleanup".into())
                    } else if !matches!(kind.as_str(), "project" | "installer" | "installer-zip") {
                        Err("Informational: requires a separately supported owner-specific cleanup rule".into())
                    } else {
                        snapshot(&path, &self.home, path_root, &self.exclusions)
                    };
                    match outcome {
                        Ok(lineage) => {
                            let candidate = Candidate {
                                path,
                                lineage,
                                kind,
                            };
                            // Expensive per-item guards run only when planning a selected set.
                            if candidate.kind == "installer-zip" {
                                result["action"] = json!("informational");
                                result["blockingReason"] =
                                    json!("ZIP contents await bounded installer inspection");
                                self.archives.insert(key, candidate);
                            } else {
                                result["action"] = json!("review");
                                self.candidates.insert(key, candidate);
                            }
                        }
                        Err(reason) => {
                            result["action"] = json!("informational");
                            result["blockingReason"] = json!(reason);
                        }
                    }
                    emit(id, "finding", result);
                }
                emit(id, "done", json!({"generation":self.generation}));
            }
            "inspectArchive" => {
                self.require_generation(v, expected)?;
                let key = field(v, "candidateID")?;
                let candidate = self
                    .archives
                    .remove(key)
                    .ok_or("No pending archive with this identity")?;
                let mut inspection = candidate.clone();
                inspection.kind = "inspect-zip".into();
                let outcome = guard(
                    &inspection,
                    &self.root,
                    &self.home,
                    adapter,
                    epoch,
                    expected,
                );
                match outcome {
                    Ok(()) => {
                        self.candidates.insert(key.into(), candidate);
                        emit(id, "finding", json!({"candidateID":key,"action":"review"}));
                    }
                    Err(reason) => emit(
                        id,
                        "finding",
                        json!({"candidateID":key,"action":"informational","blockingReason":reason}),
                    ),
                }
                emit(id, "done", json!({}));
            }
            "enrich" => {
                self.require_generation(v, expected)?;
                let family = field(v, "family")?;
                let records =
                    discover_family(family, adapter, &self.root, &self.home, epoch, expected)?;
                for (path, action, description) in records {
                    if action == "review" {
                        self.discovered
                            .insert(path.clone(), format!("family:{family}"));
                    }
                    emit(
                        id,
                        "finding",
                        json!({"path":path,"action":action,"description":description,"category":format!("family:{family}")}),
                    );
                }
                emit(id, "done", json!({"family":family}));
            }
            "measure" => {
                self.require_generation(v, expected)?;
                let items = v["items"].as_array().ok_or("Missing measured candidates")?;
                for item in items {
                    let key = field(item, "candidateID")?.to_owned();
                    let path = field(item, "path")?;
                    let Some(kind) = self.discovered.get(path).cloned() else {
                        continue;
                    };
                    if item["complete"] != true || item["category"].as_str() != Some(&kind) {
                        continue;
                    }
                    let root = if self.root == Path::new("/System/Volumes/Data") {
                        Path::new("/")
                    } else {
                        &self.root
                    };
                    if let Ok(lineage) =
                        snapshot(Path::new(path), &self.home, root, &self.exclusions)
                    {
                        self.candidates.insert(
                            key.clone(),
                            Candidate {
                                path: PathBuf::from(path),
                                lineage,
                                kind,
                            },
                        );
                        emit(id, "validated", json!({"candidateID":key}));
                    }
                }
                emit(id, "done", json!({}));
            }
            "plan" => {
                self.require_generation(v, expected)?;
                self.plan.clear();
                self.token.clear();
                let ids = v["candidateIDs"]
                    .as_array()
                    .ok_or("Missing candidate IDs")?;
                let mut paths = Vec::new();
                for key in ids {
                    let key = key.as_str().ok_or("Invalid candidate ID")?;
                    let candidate = self
                        .candidates
                        .get(key)
                        .ok_or("Candidate is not eligible for planning")?;
                    if paths.iter().any(|p: &PathBuf| {
                        candidate.path.starts_with(p) || p.starts_with(&candidate.path)
                    }) {
                        return Err(
                            "Overlapping candidates; choose a parent or its children".into()
                        );
                    }
                    paths.push(candidate.path.clone());
                    guard(candidate, &self.root, &self.home, adapter, epoch, expected)?;
                    self.plan.insert(key.into());
                }
                let mut random = [0u8; 24];
                fs::File::open("/dev/urandom")
                    .and_then(|mut f| f.read_exact(&mut random))
                    .map_err(|e| e.to_string())?;
                self.token = random.iter().map(|b| format!("{b:02x}")).collect();
                emit(
                    id,
                    "plan",
                    json!({"token":self.token,"generation":self.generation,"candidateIDs":self.plan,"action":"trash"}),
                );
                emit(id, "done", json!({}));
            }
            "apply" => {
                self.require_generation(v, expected)?;
                if self.token.is_empty() || field(v, "token")? != self.token {
                    return Err("Approval does not match this plan".into());
                }
                // A token is single-use, including partial failure or cancellation.
                let receipt_prefix = self.token.clone();
                self.token.clear();
                let ids = v["candidateIDs"]
                    .as_array()
                    .ok_or("Missing candidate IDs")?;
                let keys: Vec<&str> = ids
                    .iter()
                    .map(|i| i.as_str().ok_or("Invalid candidate ID"))
                    .collect::<Result<_, _>>()?;
                if keys.iter().collect::<HashSet<_>>().len() != keys.len() {
                    return Err("Duplicate selected ID".into());
                }
                if keys.iter().any(|i| !self.plan.contains(*i)) {
                    return Err("Selection is outside the approved plan".into());
                }
                for key in keys {
                    if epoch.load(Ordering::Relaxed) != expected {
                        return Err("Cancelled; remaining items were not touched".into());
                    }
                    let candidate = &self.candidates[key];
                    let outcome =
                        guard(candidate, &self.root, &self.home, adapter, epoch, expected)
                            .and_then(|_| {
                                if epoch.load(Ordering::Relaxed) != expected {
                                    Err("Cancelled".into())
                                } else {
                                    same(&candidate.lineage)
                                }
                            })
                            .and_then(|_| trash(&candidate.path));
                    let body = match outcome {
                        Ok(path) => {
                            let receipt = format!("{receipt_prefix}:{key}");
                            let destination = PathBuf::from(&path);
                            // These receipts exist only for successful moves from this worker.
                            if let Ok(lineage) = destination
                                .ancestors()
                                .map(|p| identity(p).map(|i| (p.to_path_buf(), i)))
                                .collect::<Result<Vec<_>, _>>()
                            {
                                self.receipts
                                    .insert(receipt.clone(), (destination, lineage));
                            }
                            json!({"candidateID":key,"status":"trashed","trashPath":path,"receipt":receipt})
                        }
                        Err(error) => json!({"candidateID":key,"status":"refused","error":error}),
                    };
                    emit(id, "result", body);
                }
                self.plan.clear();
                emit(id, "done", json!({}));
            }
            "empty" => {
                let ids = v["receipts"].as_array().ok_or("Missing Trash receipts")?;
                if v["confirmedPermanentRemoval"] != true {
                    return Err("Separate permanent-removal confirmation is required".into());
                }
                for receipt in ids {
                    if epoch.load(Ordering::Relaxed) != expected {
                        return Err("Cancelled; remaining Trash items were kept".into());
                    }
                    let receipt = receipt.as_str().ok_or("Invalid receipt")?;
                    let (path, lineage) = self
                        .receipts
                        .remove(receipt)
                        .ok_or("This worker did not trash the selected item")?;
                    let result = same(&lineage).and_then(|_| {
                        let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
                        if meta.is_dir() {
                            fs::remove_dir_all(&path)
                        } else {
                            fs::remove_file(&path)
                        }
                        .map_err(|e| e.to_string())
                    });
                    emit(
                        id,
                        "result",
                        match result {
                            Ok(()) => json!({"receipt":receipt,"status":"removed"}),
                            Err(message) => {
                                json!({"receipt":receipt,"status":"refused","error":message})
                            }
                        },
                    );
                }
                emit(id, "done", json!({}));
            }
            "cancel" => {
                self.epoch = expected;
                self.plan.clear();
                self.token.clear();
                emit(id, "done", json!({"cancelled":true}));
            }
            _ => return Err("Unknown operation".into()),
        }
        Ok(())
    }
    fn require_generation(&self, v: &Value, epoch: u64) -> Result<(), String> {
        if self.generation.is_empty()
            || field(v, "generation")? != self.generation
            || self.epoch != epoch
        {
            Err("Plan belongs to an obsolete or cancelled scan".into())
        } else {
            Ok(())
        }
    }
}
fn main() {
    if unsafe { libc::getuid() } == 0 {
        eprintln!("BurrowBolt never runs cleanup as root");
        std::process::exit(1);
    }
    let executable = std::env::current_exe().expect("worker executable");
    let adapter = executable.parent().unwrap().join("../Resources/adapter.sh");
    let epoch = Arc::new(AtomicU64::new(0));
    let reader_epoch = epoch.clone();
    let (send, recv) = mpsc::sync_channel(8);
    std::thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        loop {
            let mut line = Vec::new();
            let read = (&mut stdin)
                .take((MAX_LINE + 1) as u64)
                .read_until(b'\n', &mut line);
            if read.is_err() || line.is_empty() {
                reader_epoch.fetch_add(1, Ordering::Relaxed);
                break;
            }
            if line.len() > MAX_LINE {
                emit(
                    &Value::Null,
                    "error",
                    json!({"message":"Request exceeds size limit"}),
                );
                break;
            }
            let parsed: Result<Value, _> = serde_json::from_slice(&line);
            match parsed {
                Ok(v) => {
                    if v["op"] == "cancel" {
                        reader_epoch.fetch_add(1, Ordering::Relaxed);
                    }
                    let current = reader_epoch.load(Ordering::Relaxed);
                    if send.send((v, current)).is_err() {
                        break;
                    }
                }
                Err(_) => emit(&Value::Null, "error", json!({"message":"Invalid JSON"})),
            }
        }
    });
    let mut session = Session::new();
    for (v, expected) in recv {
        if let Err(message) = session.handle(&v, &adapter, &epoch, expected) {
            session.plan.clear();
            session.token.clear();
            emit(&v["id"], "error", json!({"message":message}));
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_rejects_replacement_symlink_and_containment_escape() {
        let root =
            std::env::temp_dir().join(format!("burrowbolt-worker-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let home = root.join("home");
        fs::create_dir_all(&home).unwrap();
        let path = home.join("installer.dmg");
        fs::write(&path, b"fixture").unwrap();
        let snap = snapshot(&path, &home, &home, &[]).unwrap();
        assert!(same(&snap).is_ok());
        assert!(snapshot(&root, &home, &home, &[]).is_err());
        assert!(snapshot(&path, &home, &home, &[path.clone()]).is_err());
        fs::rename(&path, home.join("original")).unwrap();
        fs::write(&path, b"replacement").unwrap();
        assert!(same(&snap).is_err());
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(home.join("original"), &path).unwrap();
        assert!(snapshot(&path, &home, &home, &[]).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn selected_apply_is_single_use_and_permanent_removal_requires_own_receipt() {
        let root =
            std::env::temp_dir().join(format!("burrowbolt-protocol-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let file = root.join("Installer with spaces.dmg");
        fs::write(&file, b"fixture").unwrap();
        let keep = root.join("keep.dmg");
        fs::write(&keep, b"keep").unwrap();
        let adapter = std::env::current_dir()
            .unwrap()
            .join("build/BurrowBolt.app/Contents/Resources/adapter.sh");
        assert!(
            adapter.is_file(),
            "Run ./build.sh before worker integration tests"
        );
        let epoch = AtomicU64::new(0);
        let mut s = Session::new();
        s.home = root.clone();
        s.handle(
            &json!({"version":1,"op":"discover","root":root,"generation":"test","items":[
                {"candidateID":"selected","path":file,"category":"installer","complete":true}
            ]}),
            &adapter,
            &epoch,
            0,
        )
        .unwrap();
        s.handle(
            &json!({"version":1,"op":"discoverMore","generation":"test","items":[
                {"candidateID":"kept","path":keep,"category":"installer","complete":true}
            ]}),
            &adapter,
            &epoch,
            0,
        )
        .unwrap();
        assert_eq!(s.candidates.len(), 2);
        s.handle(
            &json!({"version":1,"op":"plan","generation":"test","candidateIDs":["selected"]}),
            &adapter,
            &epoch,
            0,
        )
        .unwrap();
        let apply = json!({"version":1,"op":"apply","generation":"test","candidateIDs":["selected"],"token":s.token});
        s.handle(&apply, &adapter, &epoch, 0).unwrap();
        assert!(!file.exists());
        assert!(keep.exists());
        assert_eq!(s.receipts.len(), 1);
        assert!(s.handle(&apply, &adapter, &epoch, 0).is_err());
        let receipt = s.receipts.keys().next().unwrap().clone();
        assert!(s
            .handle(
                &json!({"version":1,"op":"empty","receipts":[receipt]}),
                &adapter,
                &epoch,
                0
            )
            .is_err());
        s.handle(&json!({"version":1,"op":"empty","receipts":[receipt],"confirmedPermanentRemoval":true}),&adapter,&epoch,0).unwrap();
        assert!(s.receipts.is_empty());
        assert!(keep.exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn stale_item_is_refused_without_losing_other_selected_results() {
        let root =
            std::env::temp_dir().join(format!("burrowbolt-partial-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let changed = root.join("changed.dmg");
        let good = root.join("good.dmg");
        fs::write(&changed, b"original").unwrap();
        fs::write(&good, b"good").unwrap();
        let adapter = std::env::current_dir()
            .unwrap()
            .join("build/BurrowBolt.app/Contents/Resources/adapter.sh");
        let mut s = Session::new();
        s.home = root.clone();
        let epoch = AtomicU64::new(0);
        s.handle(
            &json!({"version":1,"op":"discover","root":root,"generation":"partial","items":[
                {"candidateID":"changed","path":changed,"category":"installer","complete":true},
                {"candidateID":"good","path":good,"category":"installer","complete":true}
            ]}),
            &adapter,
            &epoch,
            0,
        )
        .unwrap();
        s.handle(&json!({"version":1,"op":"plan","generation":"partial","candidateIDs":["changed","good"]}),&adapter,&epoch,0).unwrap();
        fs::rename(&changed, root.join("preserved-original")).unwrap();
        fs::write(&changed, b"replacement").unwrap();
        s.handle(&json!({"version":1,"op":"apply","generation":"partial","token":s.token,"candidateIDs":["changed","good"]}),&adapter,&epoch,0).unwrap();
        assert_eq!(fs::read(&changed).unwrap(), b"replacement");
        assert!(!good.exists());
        assert_eq!(s.receipts.len(), 1);
        let receipt = s.receipts.keys().next().unwrap().clone();
        let destination = s.receipts[&receipt].0.clone();
        fs::remove_file(&destination).unwrap();
        std::os::unix::fs::symlink(&changed, &destination).unwrap();
        s.handle(&json!({"version":1,"op":"empty","receipts":[receipt],"confirmedPermanentRemoval":true}),&adapter,&epoch,0).unwrap();
        assert_eq!(fs::read(&changed).unwrap(), b"replacement");
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cancellation_stops_an_active_probe_promptly() {
        let temp = ProbeTemp::new().unwrap();
        let root = fs::canonicalize(&temp.0).unwrap();
        let path = root.join("installer.dmg");
        fs::write(&path, b"fixture").unwrap();
        let adapter = root.join("slow.sh");
        fs::write(&adapter, b"#!/bin/bash\n/bin/sleep 30\n").unwrap();
        let candidate = Candidate {
            path: path.clone(),
            kind: "installer".into(),
            lineage: snapshot(&path, &root, &root, &[]).unwrap(),
        };
        let epoch = Arc::new(AtomicU64::new(0));
        let signal = epoch.clone();
        let cancel = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(80));
            signal.store(1, Ordering::Relaxed);
        });
        let started = Instant::now();
        assert!(guard(&candidate, &root, &root, &adapter, &epoch, 0)
            .unwrap_err()
            .contains("cancelled"));
        assert!(started.elapsed() < Duration::from_secs(2));
        cancel.join().unwrap();
        assert!(path.exists());
    }
    #[test]
    fn cancelled_generations_and_missing_approval_fail_closed() {
        let mut s = Session::new();
        s.generation = "scan1".into();
        let epoch = AtomicU64::new(1);
        let v = json!({"version":1,"op":"apply","generation":"scan1","token":"unapproved","candidateIDs":[]});
        assert!(s.handle(&v, Path::new("/not-run"), &epoch, 1).is_err());
        assert!(s.handle(&v, Path::new("/not-run"), &epoch, 0).is_err());
    }
}
