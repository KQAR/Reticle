//! reticle-device: the host side of the iOS system channel on a REAL device.
//!
//! Every call answers with a single JSON line on stdout (`{"ok":true,…}` /
//! `{"ok":false,"error":…}`):
//!
//!   reticle-device <udid> probe
//!   reticle-device <udid> tree [wait_ms] [linger_ms]
//!   reticle-device <udid> tap <x> <y>          normalized 0..=65535
//!   reticle-device <udid> home
//!   reticle-device <udid> launch <bundle-id>   foregrounds without restarting
//!   reticle-device <udid> screenshot <out.png>
//!   reticle-device <udid> stop                 end the resident session
//!
//! The first call starts a RESIDENT session for that device (`serve`, detached)
//! and every later call is forwarded to it over a unix socket. The session holds
//! the tunnel, the display media stream and both HID connections. Then a tap is
//! one report on a connection backboardd already opened, rather than a new
//! connection that creates five virtual HID services and has to wait for them.
//! The session exits after IDLE without a request, or on the first error. The
//! next call then starts a fresh one. `RETICLE_DEVICE_ONESHOT=1` skips it and
//! opens a tunnel per call.
//!
//! Needs developer mode and a mounted developer disk image; no app on the device.

mod ax;

use idevice::{
    IdeviceService, ReadWrite, RsdService,
    core_device::{
        CallInfoBlob, DisplayServiceClient, build_screen_audio_offer, build_screen_video_offer,
        build_start_audio_parameters, build_start_video_parameters,
        ImageFormat, ScreenCaptureServiceClient,
        hid::{ButtonState, IndigoHidClient, UniversalHidServiceClient},
    },
    core_device_proxy::CoreDeviceProxy,
    dvt::{application_listing::ApplicationListingClient, device_info::DeviceInfoClient, process_control::ProcessControlClient, remote_server::RemoteServerClient},
    rsd::RsdHandshake,
    tcp::handle::{AdapterHandle, UdpSocketHandle},
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use serde_json::{Value as Json, json};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

pub type R<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// backboardd opens the virtual touchscreen a few hundred ms after the HID
/// connection is made; a report sent before that is queued, and dropped if the
/// connection closes first. Measured (iOS 27.0.1, USB, 76 taps): sending at once
/// and disconnecting at once lost 17/17; waiting OPEN or holding HOLD before
/// disconnecting each delivered every tap. A resident session pays OPEN once.
const MEDIA_SETTLE: Duration = Duration::from_millis(1000);
const OPEN: Duration = Duration::from_millis(500);
const HOLD: Duration = Duration::from_millis(300);
/// One request's bound, and how long a resident session waits for the next one.
const CALL: Duration = Duration::from_secs(60);
const IDLE: Duration = Duration::from_secs(120);

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let [udid, op] = args.as_slice() {
        if op == "serve" {
            if let Err(e) = serve(udid).await {
                eprintln!("reticle-device serve: {e}");
                std::process::exit(1);
            }
            return;
        }
    }
    let started = Instant::now();
    let out = match dispatch(&args).await {
        Ok(mut v) => {
            v["ok"] = true.into();
            v["ms"] = (started.elapsed().as_millis() as u64).into();
            v
        }
        Err(e) => json!({"ok": false, "error": e.to_string()}),
    };
    println!("{out}");
    if out["ok"] != true {
        std::process::exit(1);
    }
}

const USAGE: &str = "usage: reticle-device <udid> <probe|tree|tap|home|launch|screenshot|stop> …";

async fn dispatch(args: &[String]) -> R<Json> {
    let (udid, op) = match args {
        [u, op, ..] => (u.as_str(), op.as_str()),
        _ => return Err(USAGE.into()),
    };
    let resident = std::env::var("RETICLE_DEVICE_ONESHOT").as_deref() != Ok("1");
    match op {
        "stop" => Ok(json!({"stopped": stop(udid).await})),
        "probe" => one_shot(udid, &args[1..]).await,
        _ if resident => match forward(udid, &args[1..]).await {
            Ok(Some(answer)) => answer,
            // No session could be reached or started: do it in this process.
            Ok(None) | Err(_) => one_shot(udid, &args[1..]).await,
        },
        _ => one_shot(udid, &args[1..]).await,
    }
}

async fn one_shot(udid: &str, request: &[String]) -> R<Json> {
    tokio::time::timeout(CALL, async {
        let mut s = Session { d: connect(udid).await?, stream: None, touch: None, buttons: None };
        let out = s.run(request).await;
        // A one-shot connection must outlive its last report, or the report is lost.
        if s.touch.is_some() || s.buttons.is_some() {
            tokio::time::sleep(HOLD).await;
        }
        s.touch = None;
        s.buttons = None;
        if let Some(stream) = s.stream.take() {
            stream.stop().await;
        }
        out
    })
    .await
    .unwrap_or_else(|_| Err("the device stopped answering (60 s)".into()))
}

// ---- resident session --------------------------------------------------------

fn socket_path(udid: &str) -> PathBuf {
    std::env::temp_dir().join(format!("reticle-device-{udid}.sock"))
}

/// Send `request` to the device's resident session, starting one if none is
/// listening. `Ok(None)` when no session could be reached.
async fn forward(udid: &str, request: &[String]) -> R<Option<R<Json>>> {
    let path = socket_path(udid);
    let conn = match UnixStream::connect(&path).await {
        Ok(c) => c,
        Err(_) => {
            std::process::Command::new(std::env::current_exe()?)
                .args([udid, "serve"])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()?;
            // Tunnel + media stream + both HID connections + OPEN: ~2-3 s.
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                if let Ok(c) = UnixStream::connect(&path).await {
                    break c;
                }
                if Instant::now() > deadline {
                    return Ok(None);
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    };
    let (r, mut w) = conn.into_split();
    w.write_all(format!("{}\n", serde_json::to_string(request)?).as_bytes()).await?;
    let mut line = String::new();
    tokio::time::timeout(CALL + Duration::from_secs(5), BufReader::new(r).read_line(&mut line)).await??;
    if line.is_empty() {
        return Ok(None); // the session died mid-request
    }
    let mut answer: Json = serde_json::from_str(&line)?;
    if answer["ok"] == true {
        answer.as_object_mut().map(|o| o.remove("ok"));
        Ok(Some(Ok(answer)))
    } else {
        Ok(Some(Err(answer["error"].as_str().unwrap_or("failed").to_owned().into())))
    }
}

async fn stop(udid: &str) -> bool {
    let Ok(mut conn) = UnixStream::connect(socket_path(udid)).await else { return false };
    let _ = conn.write_all(b"[\"stop\"]\n").await;
    let mut line = String::new();
    let _ = tokio::time::timeout(Duration::from_secs(5), BufReader::new(conn).read_line(&mut line)).await;
    true
}

async fn serve(udid: &str) -> R<()> {
    let path = socket_path(udid);
    if UnixStream::connect(&path).await.is_ok() {
        return Ok(()); // another session already owns this device
    }
    let _ = std::fs::remove_file(&path);
    let mut s = Session { d: connect(udid).await?, stream: None, touch: None, buttons: None };
    // Open both HID connections up front, so no request pays OPEN.
    s.touch().await?;
    s.buttons().await?;
    let listener = UnixListener::bind(&path)?;
    let result: R<()> = async {
        loop {
            let Ok(accepted) = tokio::time::timeout(IDLE, listener.accept()).await else { return Ok(()) };
            let (conn, _) = accepted?;
            let (r, mut w) = conn.into_split();
            let mut line = String::new();
            BufReader::new(r).read_line(&mut line).await?;
            let request: Vec<String> = serde_json::from_str(&line).unwrap_or_default();
            if request.first().map(String::as_str) == Some("stop") {
                w.write_all(b"{\"ok\":true}\n").await?;
                return Ok(());
            }
            let started = Instant::now();
            let out = tokio::time::timeout(CALL, s.run(&request))
                .await
                .unwrap_or_else(|_| Err("the device stopped answering (60 s)".into()));
            let (answer, fatal) = match out {
                Ok(mut v) => {
                    v["ok"] = true.into();
                    v["resident"] = true.into();
                    v["sessionMs"] = (started.elapsed().as_millis() as u64).into();
                    (v, false)
                }
                // Any failure may have left a connection half-dead; a fresh
                // session is cheaper than diagnosing which one.
                Err(e) => (json!({"ok": false, "error": e.to_string()}), true),
            };
            w.write_all(format!("{answer}\n").as_bytes()).await?;
            if fatal {
                return Ok(());
            }
        }
    }
    .await;
    let _ = std::fs::remove_file(&path);
    s.touch = None;
    s.buttons = None;
    if let Some(stream) = s.stream.take() {
        stream.stop().await;
    }
    result
}

// ---- actions -----------------------------------------------------------------

struct Device {
    adapter: AdapterHandle,
    rsd: RsdHandshake,
}

async fn connect(udid: &str) -> R<Device> {
    let mut mux = UsbmuxdConnection::default().await?;
    let dev = mux
        .get_device(udid)
        .await
        .map_err(|e| format!("device {udid} is not attached over USB: {e}"))?;
    let provider = dev.to_provider(UsbmuxdAddr::from_env_var()?, "reticle-device");
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .map_err(|e| format!("CoreDevice tunnel refused ({e}); is the device unlocked, trusted, and in developer mode?"))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let rsd = RsdHandshake::new(adapter.connect(rsd_port).await?).await?;
    Ok(Device { adapter, rsd })
}

/// One tunnel and whatever HID connections have been opened on it.
struct Session {
    d: Device,
    stream: Option<MediaStream>,
    touch: Option<UniversalHidServiceClient<Box<dyn ReadWrite>>>,
    buttons: Option<IndigoHidClient<Box<dyn ReadWrite>>>,
}

impl Session {
    async fn media(&mut self) -> R<()> {
        if self.stream.is_none() {
            self.stream = Some(MediaStream::start(&mut self.d).await?);
        }
        Ok(())
    }

    async fn touch(&mut self) -> R<&mut UniversalHidServiceClient<Box<dyn ReadWrite>>> {
        if self.touch.is_none() {
            self.media().await?;
            self.touch = Some(UniversalHidServiceClient::connect_rsd(&mut self.d.adapter, &mut self.d.rsd).await?);
            tokio::time::sleep(OPEN).await;
        }
        Ok(self.touch.as_mut().unwrap())
    }

    async fn buttons(&mut self) -> R<&mut IndigoHidClient<Box<dyn ReadWrite>>> {
        if self.buttons.is_none() {
            self.media().await?;
            self.buttons = Some(IndigoHidClient::connect_rsd(&mut self.d.adapter, &mut self.d.rsd).await?);
            tokio::time::sleep(OPEN).await;
        }
        Ok(self.buttons.as_mut().unwrap())
    }

    /// `request` is the command line after the udid: `[op, args…]`.
    async fn run(&mut self, request: &[String]) -> R<Json> {
        let op = request.first().map(String::as_str).ok_or(USAGE)?;
        let num = |i: usize| -> R<u64> { Ok(request.get(i).ok_or(USAGE)?.parse()?) };
        let d = &mut self.d;
        match op {
            "probe" => {
                let has = |name: &str| d.rsd.services.contains_key(name);
                Ok(json!({"services": {
                    "display": has(&DisplayServiceClient::rsd_service_name()),
                    "touch": has(&UniversalHidServiceClient::rsd_service_name()),
                    "buttons": has(&IndigoHidClient::rsd_service_name()),
                    "accessibility": has(ax::SERVICE),
                    "screenshot": has(&ScreenCaptureServiceClient::rsd_service_name()),
                    "instruments": has(&RemoteServerClient::rsd_service_name()),
                }}))
            }
            "tree" => {
                let wait = Duration::from_millis(num(1).unwrap_or(8000));
                let linger = Duration::from_millis(num(2).unwrap_or(1500));
                let t0 = Instant::now();
                let tree = ax::read(&mut d.adapter, &d.rsd, wait, linger)
                    .await?
                    .ok_or_else(|| format!("no accessibility tree within {} ms", wait.as_millis()))?;
                let mut out = tree.json();
                out["readMs"] = (t0.elapsed().as_millis() as u64).into();
                // The tree names a root only by pid; say which app that pid is.
                let pids: Vec<u64> = out["apps"].as_array().into_iter().flatten().filter_map(|a| a["pid"].as_u64()).collect();
                let owners = bundle_ids(d, &pids).await?;
                for app in out["apps"].as_array_mut().into_iter().flatten() {
                    if let Some(owner) = app["pid"].as_u64().and_then(|p| owners.get(&p)) {
                        app["bundleId"] = owner.clone().into();
                    }
                }
                Ok(out)
            }
            "tap" => {
                let (x, y) = (num(1)?, num(2)?);
                if x > 65535 || y > 65535 {
                    return Err("tap coordinates are normalized to 0..=65535".into());
                }
                self.touch().await?.tap(x as u16, y as u16).await?;
                Ok(json!({}))
            }
            "home" => {
                let b = self.buttons().await?;
                // Consumer page 0x0C, usage 0x40 (Menu) is the Home button.
                b.send_button(0x0C, 0x40, ButtonState::Down).await?;
                tokio::time::sleep(Duration::from_millis(80)).await;
                b.send_button(0x0C, 0x40, ButtonState::Up).await?;
                Ok(json!({}))
            }
            "launch" => {
                let bundle = request.get(1).ok_or(USAGE)?;
                let mut remote: RemoteServerClient<Box<dyn ReadWrite>> = RemoteServerClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
                let mut control = ProcessControlClient::new(&mut remote).await?;
                // KillExisting=false: a running app is brought forward as it is.
                let pid = control.launch_app(bundle.as_str(), None, None, false, false).await?;
                Ok(json!({"pid": pid}))
            }
            "screenshot" => {
                let path = request.get(1).ok_or(USAGE)?;
                let mut shot: ScreenCaptureServiceClient<Box<dyn ReadWrite>> = ScreenCaptureServiceClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
                let png = shot.take_screenshot(None, ImageFormat::Png).await?;
                std::fs::write(path, &png)?;
                Ok(json!({"bytes": png.len()}))
            }
            _ => Err(USAGE.into()),
        }
    }
}

/// Bundle id for each of `pids`, through the instruments service: the pid's
/// executable, matched against the installed apps' bundle paths. SpringBoard is
/// not an installed app, so it is recognised by its executable. (CoreDevice's
/// own process list was measured to hang on a device whose app service had
/// wedged, while instruments kept answering.)
async fn bundle_ids(d: &mut Device, pids: &[u64]) -> R<std::collections::HashMap<u64, String>> {
    let mut remote: RemoteServerClient<Box<dyn ReadWrite>> = RemoteServerClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
    let mut exes = vec![];
    {
        let mut info = DeviceInfoClient::new(&mut remote).await?;
        for &pid in pids {
            exes.push((pid, info.execname_for_pid(pid as u32).await?));
        }
    }
    let installed = ApplicationListingClient::new(&mut remote).await?.installed_applications().await?;
    let mut out = std::collections::HashMap::new();
    for (pid, exe) in exes {
        let bundle = if exe.ends_with("/SpringBoard.app/SpringBoard") {
            Some("com.apple.springboard".to_owned())
        } else {
            installed.iter().find_map(|app| {
                let path = app.get("BundlePath")?.as_string()?.trim_end_matches('/');
                exe.starts_with(&format!("{path}/")).then(|| app.get("CFBundleIdentifier")?.as_string().map(str::to_owned))?
            })
        };
        if let Some(b) = bundle {
            out.insert(pid, b);
        }
    }
    Ok(out)
}

/// backboardd dispatches reports from the CoreDevice HID services only while a
/// display media stream is open. The RTP is never read; the stream is the gate.
///
/// Adapted from idevice tools/src/coredevice_stream.rs (MIT, jkcoxson/idevice).
struct MediaStream {
    client: DisplayServiceClient<Box<dyn ReadWrite>>,
    _sockets: (UdpSocketHandle, UdpSocketHandle),
}

impl MediaStream {
    async fn start(d: &mut Device) -> R<MediaStream> {
        let mut client = DisplayServiceClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
        let audio = d.adapter.bind_udp(0).await?;
        let video = d.adapter.bind_udp(0).await?;
        let (host, peer) = (d.adapter.host_ip().to_string(), d.adapter.peer_ip().to_string());
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let id = || uuid::Uuid::new_v4().to_string().to_uppercase();
        let offer = build_screen_audio_offer(&id(), &info)?;
        client
            .start_media_stream(build_start_audio_parameters(&host, audio.local_port(), &peer, 50000, offer, 140, session))
            .await?;
        let offer = build_screen_video_offer(&id(), &info, uuid::Uuid::new_v4().as_u128() as u32)?;
        client
            .start_media_stream(build_start_video_parameters(&host, video.local_port(), &peer, 50001, offer, 140, 1, session))
            .await?;
        tokio::time::sleep(MEDIA_SETTLE).await;
        Ok(MediaStream { client, _sockets: (audio, video) })
    }

    async fn stop(mut self) {
        let _ = self.client.stop_media_stream().await;
    }
}
