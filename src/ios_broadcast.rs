//! Remotless: view-only screen sharing from an iPhone/iPad.
//!
//! The Remotless server (rendezvous registration, connections, video) runs inside the ReplayKit
//! Broadcast Upload Extension (flutter/ios/RemotlessBroadcast), because iOS suspends the main
//! app a few seconds after the user leaves it, while the extension keeps running for as long as
//! the broadcast does. The extension's Swift code calls the C functions below:
//!
//!   remotless_bc_start(dir, share_json, callback)   once, when the broadcast starts
//!   remotless_bc_push_frame(bgra, len, w, h, stride) for every frame it keeps
//!   remotless_bc_authorize(conn_id, accept)          the user's answer from the app
//!   remotless_bc_disconnect_all()                    "Stop sharing" for the technician
//!   remotless_bc_stop()                              when the broadcast ends
//!
//! `callback` receives JSON events ({"name": ...}) that the extension forwards to the app through
//! the App Group, where the user accepts or denies the technician and sees who is watching.
//! No input is ever injected (iOS has no API for it): the server tells the technician that the
//! keyboard/mouse, clipboard, files, audio and the rest are off. See docs/ios-screen-share.md.

use crate::ui_cm_interface::{self, Client, ConnectionManager, InvokeUiCM};
use hbb_common::{
    config::{self, Config},
    log,
    password_security,
    tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender},
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, RwLock,
    },
};

pub type EventCallback = extern "C" fn(event: *const c_char);

lazy_static::lazy_static! {
    static ref CALLBACK: RwLock<Option<EventCallback>> = RwLock::new(None);
    static ref DEVICE_NAME: RwLock<String> = RwLock::new("iPhone".to_owned());
    static ref EMIT_LOCK: Mutex<()> = Mutex::new(());
}
static STARTED: AtomicBool = AtomicBool::new(false);

/// Everything a technician could change or use besides watching the screen: all off on iOS.
const VIEW_ONLY_OPTIONS: &[(&str, &str)] = &[
    ("enable-keyboard", "N"),
    ("enable-clipboard", "N"),
    ("enable-file-transfer", "N"),
    ("enable-audio", "N"),
    ("enable-tunnel", "N"),
    ("enable-remote-restart", "N"),
    ("enable-record-session", "N"),
    ("enable-block-input", "N"),
    ("enable-privacy-mode", "N"),
    ("enable-camera", "N"),
    ("enable-terminal", "N"),
    ("allow-remote-config-modification", "N"),
    ("enable-lan-discovery", "N"),
    ("direct-server", "N"),
    // The one-time password from the app, or the user's click in the app.
    ("verification-method", "use-temporary-password"),
    ("approve-mode", ""),
    ("stop-service", ""),
];

/// The options the app may pass on (its server settings); anything else is ignored.
const SERVER_OPTIONS: &[&str] = &[
    "custom-rendezvous-server",
    "relay-server",
    "api-server",
    "key",
    "allow-websocket",
];

pub fn device_name() -> String {
    DEVICE_NAME.read().unwrap().clone()
}

fn emit(event: Value) {
    let cb = *CALLBACK.read().unwrap();
    if let Some(cb) = cb {
        if let Ok(s) = CString::new(event.to_string()) {
            let _lock = EMIT_LOCK.lock().unwrap();
            cb(s.as_ptr());
        }
    }
}

unsafe fn c_str(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

/// Starts the server inside the extension.
///
/// * `dir`: the extension's own data folder inside the App Group container (config, keys).
/// * `share_json`: written by the app's Share screen tab:
///   `{"id": "...", "password": "...", "device_name": "...", "options": {"api-server": ...}}`.
/// * `callback`: receives JSON events, see `IosHandler`.
///
/// Returns 0 when started, 1 if it was already running, -1 if `share_json` is unusable.
#[no_mangle]
pub unsafe extern "C" fn remotless_bc_start(
    dir: *const c_char,
    share_json: *const c_char,
    callback: Option<EventCallback>,
) -> i32 {
    *CALLBACK.write().unwrap() = callback;
    let dir = c_str(dir);
    let share: Value = match serde_json::from_str(&c_str(share_json)) {
        Ok(v) => v,
        Err(e) => {
            emit(json!({"name": "error", "text": format!("bad share config: {e}")}));
            return -1;
        }
    };
    if STARTED.swap(true, Ordering::SeqCst) {
        apply_share(&share);
        emit(json!({"name": "started", "id": Config::get_id()}));
        return 1;
    }
    if !dir.is_empty() {
        *config::APP_DIR.write().unwrap() = dir;
    }
    crate::load_custom_client();
    apply_share(&share);
    let id = Config::get_id();
    log::info!("Remotless iOS screen sharing starting, id {id}");
    emit(json!({"name": "started", "id": id}));
    std::thread::spawn(|| {
        crate::start_server(true);
        STARTED.store(false, Ordering::SeqCst);
    });
    0
}

fn apply_share(share: &Value) {
    if let Some(name) = share.get("device_name").and_then(|v| v.as_str()) {
        if !name.is_empty() {
            *DEVICE_NAME.write().unwrap() = name.to_owned();
        }
    }
    // Share the app's Remotless ID, so the technician types the number the app shows.
    if let Some(id) = share.get("id").and_then(|v| v.as_str()) {
        if !id.is_empty() && id != Config::get_id() {
            Config::set_id(id);
        }
    }
    if let Some(opts) = share.get("options").and_then(|v| v.as_object()) {
        for key in SERVER_OPTIONS {
            let v = opts.get(*key).and_then(|v| v.as_str()).unwrap_or_default();
            if Config::get_option(key) != v {
                Config::set_option(key.to_string(), v.to_owned());
            }
        }
    }
    for (k, v) in VIEW_ONLY_OPTIONS {
        if Config::get_option(k) != *v {
            Config::set_option(k.to_string(), v.to_string());
        }
    }
    let password = share
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_owned();
    // An empty password still allows the click-to-accept path from the app.
    *password_security::TEMPORARY_PASSWORD.write().unwrap() = password;
}

/// One frame from ReplayKit, already scaled down and converted to BGRA by the extension.
#[no_mangle]
pub unsafe extern "C" fn remotless_bc_push_frame(
    data: *const u8,
    len: usize,
    width: u32,
    height: u32,
    stride: u32,
) {
    if data.is_null() || len == 0 {
        return;
    }
    let buf = std::slice::from_raw_parts(data, len);
    scrap::ios::push_frame(buf, width as _, height as _, stride as _);
}

/// The user's answer to a technician who connected without the one-time password.
#[no_mangle]
pub extern "C" fn remotless_bc_authorize(conn_id: i32, accept: bool) {
    if accept {
        ui_cm_interface::authorize(conn_id);
    } else {
        ui_cm_interface::close(conn_id);
    }
}

/// Ends every session (the user tapped "Stop" for the technician in the app).
#[no_mangle]
pub extern "C" fn remotless_bc_disconnect_all() {
    for id in connection_ids() {
        ui_cm_interface::close(id);
    }
}

/// The broadcast ended: drop the sessions and stop answering the rendezvous server.
#[no_mangle]
pub extern "C" fn remotless_bc_stop() {
    remotless_bc_disconnect_all();
    Config::set_option("stop-service".to_owned(), "Y".to_owned());
    crate::rendezvous_mediator::RendezvousMediator::restart();
    scrap::ios::clear();
    emit(json!({"name": "stopped"}));
}

fn connection_ids() -> Vec<i32> {
    let clients: HashMap<i32, Value> =
        serde_json::from_str::<Vec<Value>>(&ui_cm_interface::get_clients_state())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|c| Some((c.get("id")?.as_i64()? as i32, c)))
            .collect();
    clients.into_keys().collect()
}

/// The connection manager of the extension: forwards to Swift, which tells the app.
#[derive(Clone)]
struct IosHandler;

impl InvokeUiCM for IosHandler {
    fn add_connection(&self, client: &Client) {
        // authorized == false: the technician has no password, the user must accept in the app.
        emit(json!({
            "name": "add_connection",
            "client": serde_json::to_value(client).unwrap_or(Value::Null),
        }));
    }

    fn remove_connection(&self, id: i32, close: bool) {
        emit(json!({"name": "remove_connection", "id": id, "close": close}));
    }

    fn new_message(&self, id: i32, text: String) {
        emit(json!({"name": "chat", "id": id, "text": text}));
    }

    fn change_theme(&self, _dark: String) {}

    fn change_language(&self) {}

    fn show_elevation(&self, _show: bool) {}

    fn update_voice_call_state(&self, _client: &Client) {}

    fn file_transfer_log(&self, _action: &str, _log: &str) {}
}

/// Called by `Connection` for each technician, as Android's Flutter connection manager is.
pub fn start_channel(
    rx: UnboundedReceiver<crate::ipc::Data>,
    tx: UnboundedSender<crate::ipc::Data>,
) {
    let cm = ConnectionManager {
        ui_handler: IosHandler,
    };
    std::thread::spawn(move || ui_cm_interface::start_listen(cm, rx, tx));
}
