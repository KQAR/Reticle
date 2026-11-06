//! reticle-device: the host side of the iOS system channel on a REAL device.
//!
//! One invocation = one CoreDevice tunnel = one action, answered by a single JSON
//! line on stdout (`{"ok":true,…}` / `{"ok":false,"error":…}`). The Swift host
//! spawns it per `reticle system …` command; it holds no state between calls.
//!
//!   reticle-device <udid> probe
//!   reticle-device <udid> tree [wait_ms] [linger_ms]
//!   reticle-device <udid> tap <x> <y>          normalized 0..=65535
//!   reticle-device <udid> home
//!   reticle-device <udid> launch <bundle-id>   foregrounds without restarting
//!   reticle-device <udid> screenshot <out.png>
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
use std::time::{Duration, Instant};

pub type R<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// backboardd opens the virtual touchscreen a few hundred ms after the HID
/// connection is made; a report sent before that is queued, and dropped if the
/// connection closes first. Measured (iOS 27.0.1, USB, 76 taps): sending at once
/// and disconnecting at once lost 17/17; waiting OPEN or holding HOLD before
/// disconnecting each delivered every tap.
const MEDIA_SETTLE: Duration = Duration::from_millis(1000);
const OPEN: Duration = Duration::from_millis(500);
const HOLD: Duration = Duration::from_millis(300);

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let started = Instant::now();
    // Every step has its own bound, but a device that stops answering mid-call
    // must not leave the CLI waiting forever.
    let ran = tokio::time::timeout(Duration::from_secs(60), run(&args))
        .await
        .unwrap_or_else(|_| Err("the device stopped answering (60 s)".into()));
    let out = match ran {
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

async fn run(a: &[String]) -> R<Json> {
    let usage = "usage: reticle-device <udid> <probe|tree|tap|home|launch|screenshot> …";
    let (udid, op) = match a {
        [u, op, ..] => (u.as_str(), op.as_str()),
        _ => return Err(usage.into()),
    };
    let num = |i: usize| -> R<u64> { Ok(a.get(i).ok_or(usage)?.parse()?) };
    let mut d = connect(udid).await?;
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
            let wait = Duration::from_millis(num(2).unwrap_or(8000));
            let linger = Duration::from_millis(num(3).unwrap_or(1500));
            let t0 = Instant::now();
            let tree = ax::read(&mut d.adapter, &d.rsd, wait, linger)
                .await?
                .ok_or_else(|| format!("no accessibility tree within {} ms", wait.as_millis()))?;
            let mut out = tree.json();
            out["readMs"] = (t0.elapsed().as_millis() as u64).into();
            // The tree names a root only by pid; say which app that pid is.
            let pids: Vec<u64> = out["apps"].as_array().into_iter().flatten().filter_map(|a| a["pid"].as_u64()).collect();
            let owners = bundle_ids(&mut d, &pids).await?;
            for app in out["apps"].as_array_mut().into_iter().flatten() {
                if let Some(owner) = app["pid"].as_u64().and_then(|p| owners.get(&p)) {
                    app["bundleId"] = owner.clone().into();
                }
            }
            Ok(out)
        }
        "tap" => {
            let (x, y) = (num(2)?, num(3)?);
            if x > 65535 || y > 65535 {
                return Err("tap coordinates are normalized to 0..=65535".into());
            }
            let stream = MediaStream::start(&mut d).await?;
            let mut hid = UniversalHidServiceClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
            tokio::time::sleep(OPEN).await;
            hid.tap(x as u16, y as u16).await?;
            tokio::time::sleep(HOLD).await;
            drop(hid);
            stream.stop().await;
            Ok(json!({}))
        }
        "home" => {
            let stream = MediaStream::start(&mut d).await?;
            let mut indigo = IndigoHidClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
            tokio::time::sleep(OPEN).await;
            // Consumer page 0x0C, usage 0x40 (Menu) is the Home button.
            indigo.send_button(0x0C, 0x40, ButtonState::Down).await?;
            tokio::time::sleep(Duration::from_millis(80)).await;
            indigo.send_button(0x0C, 0x40, ButtonState::Up).await?;
            tokio::time::sleep(HOLD).await;
            drop(indigo);
            stream.stop().await;
            Ok(json!({}))
        }
        "launch" => {
            let bundle = a.get(2).ok_or(usage)?;
            let mut remote: RemoteServerClient<Box<dyn ReadWrite>> = RemoteServerClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
            let mut control = ProcessControlClient::new(&mut remote).await?;
            // KillExisting=false: a running app is brought forward as it is.
            let pid = control.launch_app(bundle.as_str(), None, None, false, false).await?;
            Ok(json!({"pid": pid}))
        }
        "screenshot" => {
            let path = a.get(2).ok_or(usage)?;
            let mut shot: ScreenCaptureServiceClient<Box<dyn ReadWrite>> = ScreenCaptureServiceClient::connect_rsd(&mut d.adapter, &mut d.rsd).await?;
            let png = shot.take_screenshot(None, ImageFormat::Png).await?;
            std::fs::write(path, &png)?;
            Ok(json!({"bytes": png.len()}))
        }
        _ => Err(usage.into()),
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
