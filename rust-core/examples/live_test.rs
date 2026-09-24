//! Live-test harness: drives the real `core_cmd_*` FFI against a linked
//! store, exactly like the Swift app does.
//!
//! READ-ONLY commands (safe anytime, sqlite only, no network, no loop):
//!   cargo run --example live_test -- <db> whoami
//!   cargo run --example live_test -- <db> roster
//!   cargo run --example live_test -- <db> thread <id> <limit>
//!
//! NETWORK commands (quit the app first — they open a second websocket and
//! start the sync loop in this process):
//!   cargo run --example live_test -- <db> send <thread-id> <body...>
//!   cargo run --example live_test -- <db> fetch-attachment <thread> <ts> <index>
//!   cargo run --example live_test -- <db> request-contacts
//!
//! Default db when omitted: ~/Library/Application Support/CuztomSignal/signal.db

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use cuztom_signal_core::{
    core_cmd_delete_local, core_cmd_fetch_attachment, core_cmd_init, core_cmd_is_linked,
    core_cmd_profile, core_cmd_request_contacts, core_cmd_roster, core_cmd_send,
    core_cmd_send_attachment, core_cmd_send_delete, core_cmd_send_reaction, core_cmd_thread,
    core_cmd_whoami, core_free_string, core_last_error,
};

fn err() -> String {
    unsafe {
        let p = core_last_error();
        if p.is_null() {
            return "unknown".to_string();
        }
        CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("no NULs in test args")
}

fn take_string(ptr: *mut c_char, what: &str) -> String {
    if ptr.is_null() {
        eprintln!("{what} failed: {}", err());
        std::process::exit(1);
    }
    let s = unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
    unsafe { core_free_string(ptr) };
    s
}

fn default_db() -> String {
    let home = std::env::var("HOME").expect("HOME");
    format!("{home}/Library/Application Support/CuztomSignal/signal.db")
}

fn usage() -> ! {
    eprintln!("usage: live_test [db] <whoami|roster|thread <id> <limit>|send <thread> <body...>|send-attachment <thread> <path> [caption]|fetch-attachment <thread> <ts> <index>|send-delete <thread> <ts>|send-reaction <thread> <ts> <author> <emoji>|profile <uuid>|request-contacts>");
    std::process::exit(2);
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
    }
    // Optional leading db path (ends in .db), else default.
    let db = if args[0].ends_with(".db") {
        args.remove(0)
    } else {
        default_db()
    };
    if args.is_empty() {
        usage();
    }

    let rc = unsafe { core_cmd_init(cstr(&db).as_ptr()) };
    if rc < 0 {
        eprintln!("init failed: {}", err());
        std::process::exit(1);
    }
    println!("init: {}", if rc == 1 { "linked" } else { "fresh" });
    println!("is_linked: {}", unsafe { core_cmd_is_linked() });

    match args[0].as_str() {
        "whoami" => {
            println!("{}", take_string(unsafe { core_cmd_whoami() }, "whoami"));
        }
        "roster" => {
            let json = take_string(unsafe { core_cmd_roster() }, "roster");
            // Print compact summary + full JSON length (full blob on request).
            let v: serde_json::Value = serde_json::from_str(&json).expect("valid roster json");
            let contacts = v["contacts"].as_array().map(|a| a.len()).unwrap_or(0);
            let groups = v["groups"].as_array().map(|a| a.len()).unwrap_or(0);
            let messages = v["messages"].as_array().map(|a| a.len()).unwrap_or(0);
            println!("roster: {contacts} contacts, {groups} groups, {messages} messages ({} bytes)", json.len());
            for c in v["contacts"].as_array().cloned().unwrap_or_default() {
                println!("  contact {} name={:?} phone={:?}", c["id"], c["name"], c["phone"]);
            }
            for g in v["groups"].as_array().cloned().unwrap_or_default() {
                println!("  group {} title={:?}", g["id"], g["title"]);
            }
            for m in v["messages"].as_array().cloned().unwrap_or_default() {
                let atts = m["attachments"].as_array().map(|a| a.len()).unwrap_or(0);
                println!(
                    "  msg {} sender={} ts={} atts={} body={:?}",
                    m["thread"], m["sender"], m["ts"], atts, m["body"].as_str().unwrap_or("")
                );
            }
        }
        "thread" => {
            if args.len() < 3 {
                usage();
            }
            let limit: u64 = args[2].parse().expect("limit");
            let json = take_string(
                unsafe { core_cmd_thread(cstr(&args[1]).as_ptr(), limit, u64::MAX) },
                "thread",
            );
            let v: serde_json::Value = serde_json::from_str(&json).expect("valid thread json");
            let msgs = v["messages"].as_array().cloned().unwrap_or_default();
            println!("thread {}: {} messages", args[1], msgs.len());
            for m in msgs {
                println!("  ts={} sender={} body={:?}", m["ts"], m["sender"], m["body"].as_str().unwrap_or(""));
            }
        }
        "send" => {
            if args.len() < 3 {
                usage();
            }
            let body = args[2..].join(" ");
            let ts = unsafe { core_cmd_send(cstr(&args[1]).as_ptr(), cstr(&body).as_ptr()) };
            if ts < 0 {
                eprintln!("send failed: {}", err());
                std::process::exit(1);
            }
            println!("sent to {} ts={ts}", args[1]);
        }
        "send-attachment" => {
            if args.len() < 3 {
                usage();
            }
            let caption = if args.len() > 3 { args[3..].join(" ") } else { String::new() };
            let ts = unsafe {
                core_cmd_send_attachment(
                    cstr(&args[1]).as_ptr(),
                    cstr(&args[2]).as_ptr(),
                    cstr(&caption).as_ptr(),
                )
            };
            if ts < 0 {
                eprintln!("send-attachment failed: {}", err());
                std::process::exit(1);
            }
            println!("attachment sent to {} ts={ts}", args[1]);
        }
        "send-delete" => {
            if args.len() < 3 {
                usage();
            }
            let target: u64 = args[2].parse().expect("ts");
            let ts = unsafe { core_cmd_send_delete(cstr(&args[1]).as_ptr(), target) };
            if ts < 0 {
                eprintln!("send-delete failed: {}", err());
                std::process::exit(1);
            }
            println!("tombstone sent to {} ts={ts}", args[1]);
        }
        "send-reaction" => {
            if args.len() < 5 {
                usage();
            }
            let target: u64 = args[2].parse().expect("ts");
            let ts = unsafe {
                core_cmd_send_reaction(
                    cstr(&args[1]).as_ptr(),
                    target,
                    cstr(&args[3]).as_ptr(),
                    cstr(&args[4]).as_ptr(),
                    0,
                )
            };
            if ts < 0 {
                eprintln!("send-reaction failed: {}", err());
                std::process::exit(1);
            }
            println!("reaction sent to {} ts={ts}", args[1]);
        }
        "profile" => {
            if args.len() < 2 {
                usage();
            }
            println!("{}", take_string(unsafe { core_cmd_profile(cstr(&args[1]).as_ptr()) }, "profile"));
        }
        "delete-local" => {
            if args.len() < 3 {
                usage();
            }
            let sts: u64 = args[2].parse().expect("sts");
            let rc = unsafe { core_cmd_delete_local(cstr(&args[1]).as_ptr(), sts) };
            println!("delete-local: {rc}");
        }
        "fetch-attachment" => {
            if args.len() < 4 {
                usage();
            }
            let ts: u64 = args[2].parse().expect("ts");
            let index: u64 = args[3].parse().expect("index");
            let path = take_string(
                unsafe { core_cmd_fetch_attachment(cstr(&args[1]).as_ptr(), ts, index) },
                "fetch-attachment",
            );
            println!("saved: {path}");
        }
        "request-contacts" => {
            let rc = unsafe { core_cmd_request_contacts() };
            if rc != 0 {
                eprintln!("request-contacts failed: {}", err());
                std::process::exit(1);
            }
            println!("contact sync requested");
        }
        _ => usage(),
    }
}
