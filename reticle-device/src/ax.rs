//! The device's own cross-process accessibility tree (remoteAX), read over DTX.
//!
//! Wire shape, measured on iOS 27.0.1: every DTX message's first auxiliary value
//! is an NSKeyedArchive whose root is NSData holding a SECOND archive. A tree
//! arrives as an `AXPTranslatorResponse` with `associatedRequestType == 11` whose
//! `resultData.treeDump` is a list of further responses:
//!
//! * type 4 — an application root (`objectID`, `pid`)
//! * type 5 — one element: `associatedTranslationObject.objectID` plus a
//!   dictionary of integer attribute -> value (see `apply`)
//!
//! The first dump carries elements, frames and labels; a second one ~0.5 s later
//! adds the element types and identifiers for the same object ids (and on a
//! system modal, sometimes nothing comes). So a reader keeps folding dumps in
//! after the first tree until they stop changing it or go quiet.

use futures::FutureExt;
use idevice::{
    ReadWrite,
    dvt::message::{Aux, AuxValue, Message, MessageHeader, PayloadHeader},
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use plist::Value;
use serde_json::{Map, Value as Json, json};
use std::collections::BTreeMap;
use std::panic::AssertUnwindSafe;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

use crate::R;

pub const SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteAXService";

// ---- archive access ---------------------------------------------------------

/// One NSKeyedArchive, UIDs left in place and resolved on access. A generic
/// NSObject decoder would lose the translation-object graph the ids live in.
pub struct Archive {
    objects: Vec<Value>,
    root: Value,
}

impl Archive {
    pub fn parse(bytes: &[u8]) -> Option<Archive> {
        let v = Value::from_reader(std::io::Cursor::new(bytes)).ok()?;
        let d = v.as_dictionary()?;
        Some(Archive { objects: d.get("$objects")?.as_array()?.clone(), root: d.get("$top")?.as_dictionary()?.get("root")?.clone() })
    }

    fn resolve<'a>(&'a self, v: &'a Value) -> &'a Value {
        match v {
            Value::Uid(u) => self.objects.get(u.get() as usize).unwrap_or(v),
            _ => v,
        }
    }

    pub fn root(&self) -> &Value {
        self.resolve(&self.root)
    }

    /// An object's own field, or — for an archived NSDictionary — the value
    /// under that string key.
    fn field<'a>(&'a self, v: &'a Value, name: &str) -> Option<&'a Value> {
        let d = self.resolve(v).as_dictionary()?;
        if let Some(x) = d.get(name) {
            return Some(self.resolve(x));
        }
        self.entries(v).into_iter().find(|(k, _)| k.as_string() == Some(name)).map(|(_, x)| x)
    }

    pub fn data<'a>(&'a self, v: &'a Value) -> Option<&'a [u8]> {
        let v = self.resolve(v);
        v.as_data().or_else(|| self.field(v, "NS.data")?.as_data())
    }

    /// Object ids exceed i64, so integers are read unsigned-first.
    fn uint(&self, v: &Value) -> Option<u64> {
        match self.resolve(v) {
            Value::Integer(i) => i.as_unsigned().or_else(|| i.as_signed().map(|s| s as u64)),
            Value::Boolean(b) => Some(*b as u64),
            Value::Real(r) if *r >= 0.0 => Some(*r as u64),
            _ => None,
        }
    }

    fn text(&self, v: &Value) -> Option<String> {
        let v = self.resolve(v);
        match v {
            Value::String(s) => Some(s.clone()),
            Value::Integer(i) => Some(i.to_string()),
            Value::Real(r) => Some(r.to_string()),
            Value::Dictionary(_) => ["NS.string", "NS.rectval", "NS.pointval", "NS.sizeval"]
                .iter()
                .find_map(|k| self.field(v, k).and_then(|s| s.as_string().map(str::to_owned))),
            _ => None,
        }
    }

    fn array<'a>(&'a self, v: &'a Value) -> Vec<&'a Value> {
        match self.resolve(v) {
            Value::Array(items) => items.iter().map(|x| self.resolve(x)).collect(),
            d @ Value::Dictionary(_) => self
                .field(d, "NS.objects")
                .and_then(Value::as_array)
                .map(|items| items.iter().map(|x| self.resolve(x)).collect())
                .unwrap_or_default(),
            _ => vec![],
        }
    }

    fn entries<'a>(&'a self, v: &'a Value) -> Vec<(&'a Value, &'a Value)> {
        let Some(d) = self.resolve(v).as_dictionary() else { return vec![] };
        let keys = d.get("NS.keys").map(|x| self.resolve(x)).and_then(Value::as_array);
        let vals = d.get("NS.objects").map(|x| self.resolve(x)).and_then(Value::as_array);
        match (keys, vals) {
            (Some(k), Some(o)) => k.iter().zip(o).map(|(k, o)| (self.resolve(k), self.resolve(o))).collect(),
            _ => vec![],
        }
    }
}

/// Numbers out of a Foundation geometry string: "{{0, 0}, {428, 926}}".
fn numbers(s: &str) -> Vec<f64> {
    s.split(|c: char| !(c.is_ascii_digit() || matches!(c, '.' | '-' | 'e' | 'E' | '+')))
        .filter_map(|t| t.parse::<f64>().ok())
        .filter(|n| n.is_finite())
        .collect()
}

// ---- tree -------------------------------------------------------------------

#[derive(Default)]
pub struct Node {
    attrs: Map<String, Json>,
    children: Vec<u64>,
    visible_children: Vec<u64>,
}

#[derive(Default)]
pub struct Tree {
    pub nodes: BTreeMap<u64, Node>,
    /// Application roots in the order the device reported them, with their pid.
    pub apps: Vec<(u64, Option<u64>)>,
    /// How many subscriptions it took to get the tree.
    pub subscriptions: u32,
}

impl Tree {
    /// Fold one inner archive in. Returns whether it carried a tree dump.
    pub fn absorb(&mut self, a: &Archive) -> bool {
        let root = a.root();
        if a.field(root, "associatedRequestType").and_then(|v| a.uint(v)) != Some(11) {
            return false;
        }
        let Some(dump) = a.field(root, "resultData").and_then(|r| a.field(r, "treeDump")) else {
            return false;
        };
        for response in a.array(dump) {
            let Some(data) = a.field(response, "resultData") else { continue };
            match a.field(response, "associatedRequestType").and_then(|v| a.uint(v)) {
                Some(4) => {
                    let Some(id) = a.field(data, "objectID").and_then(|v| a.uint(v)) else { continue };
                    let pid = a.field(data, "pid").and_then(|v| a.uint(v));
                    if !self.apps.iter().any(|(r, _)| *r == id) {
                        self.apps.push((id, pid));
                    }
                }
                Some(5) => {
                    let Some(id) =
                        a.field(response, "associatedTranslationObject").and_then(|o| a.field(o, "objectID")).and_then(|v| a.uint(v))
                    else {
                        continue;
                    };
                    let node = self.nodes.entry(id).or_default();
                    for (key, value) in a.entries(data) {
                        if let Some(attribute) = a.uint(key) {
                            apply(a, node, attribute, value);
                        }
                    }
                }
                _ => {}
            }
        }
        true
    }

    /// At least one application root with something under it.
    pub fn ready(&self) -> bool {
        self.apps.iter().any(|(id, _)| self.nodes.contains_key(id)) && self.nodes.len() > 1
    }

    pub fn json(&self) -> Json {
        let apps: Vec<Json> = self.apps.iter().map(|(id, pid)| json!({"id": id.to_string(), "pid": pid})).collect();
        let nodes: Map<String, Json> = self
            .nodes
            .iter()
            .map(|(id, n)| {
                let mut o = n.attrs.clone();
                // On-screen children when the device names them; the full list
                // otherwise. The full list on SpringBoard includes every page.
                let kids = if n.visible_children.is_empty() { &n.children } else { &n.visible_children };
                o.insert("children".into(), json!(kids.iter().map(u64::to_string).collect::<Vec<_>>()));
                (id.to_string(), Json::Object(o))
            })
            .collect();
        json!({"apps": apps, "nodes": nodes})
    }
}

/// Attribute ids, measured: 3/33 label (33 wins), 6 bundle id, 25 identifier,
/// 42 placeholder, 53 value, 8 children, 9 visible children, 21 frame,
/// 27 enabled, 61 element type (XCUIElementType numbering), 77 traits.
fn apply(a: &Archive, node: &mut Node, attribute: u64, value: &Value) {
    let text_field = match attribute {
        33 => Some("label"),
        3 if !node.attrs.contains_key("label") => Some("label"),
        6 => Some("bundleId"),
        25 => Some("identifier"),
        42 => Some("placeholder"),
        53 => Some("value"),
        _ => None,
    };
    if let Some(name) = text_field {
        if let Some(t) = a.text(value).filter(|t| !t.is_empty()) {
            node.attrs.insert(name.into(), t.into());
        }
        return;
    }
    match attribute {
        8 | 9 => {
            let ids =
                a.array(value).into_iter().filter_map(|v| a.uint(v).or_else(|| a.field(v, "objectID").and_then(|x| a.uint(x)))).collect();
            if attribute == 8 { node.children = ids } else { node.visible_children = ids }
        }
        21 => {
            let n = a.text(value).map(|s| numbers(&s)).unwrap_or_default();
            if n.len() == 4 {
                node.attrs.insert("frame".into(), json!(n));
            }
        }
        27 => {
            if let Some(b) = a.uint(value) {
                node.attrs.insert("enabled".into(), (b != 0).into());
            }
        }
        61 | 77 => {
            if let Some(n) = a.uint(value) {
                node.attrs.insert((if attribute == 61 { "elementType" } else { "traits" }).into(), n.into());
            }
        }
        _ => {}
    }
}

// ---- DTX session ------------------------------------------------------------

async fn call(s: &mut Box<dyn ReadWrite>, id: u32, selector: &str, arg: Value, reply: bool) -> R<()> {
    let m = Message::new(
        MessageHeader::new(0, 1, id, 0, 0, reply),
        PayloadHeader::method_invocation(),
        Some(Aux::from_values(vec![AuxValue::archived_value(arg)])),
        Some(selector.into()),
    );
    s.write_all(&m.serialize()).await?;
    Ok(())
}

/// Answer a message that expects a reply; the daemon stops sending otherwise.
/// Header words: 16 identifier, 20 conversation index, 28 expects-reply.
async fn acknowledge(s: &mut Box<dyn ReadWrite>, m: &Message) -> R<()> {
    let h = m.message_header.serialize();
    let word = |o: usize| u32::from_le_bytes(h[o..o + 4].try_into().unwrap());
    if word(28) == 0 {
        return Ok(());
    }
    let ack = Message::new(
        MessageHeader::new(0, 1, word(16), word(20) + 1, -m.message_header.channel, false),
        PayloadHeader::default(),
        None,
        None,
    );
    s.write_all(&ack.serialize()).await?;
    Ok(())
}

/// How long one subscription may stay silent before it is dropped and opened
/// again. Measured: the first tree arrives about 1.1 s after subscribing.
const RESUBSCRIBE: Duration = Duration::from_secs(3);

/// After a tree, how long a silence ends the read. Measured: the follow-up dump
/// comes ~0.5 s after the first.
const QUIET: Duration = Duration::from_millis(800);

/// Read the tree. A subscription that yields no tree within `RESUBSCRIBE`, or
/// whose DTX stream the parser cannot read, is dropped and opened again until
/// `wait` runs out; what earlier subscriptions folded in is kept. Once a tree is
/// there, dumps keep being folded in until one adds nothing, none comes for
/// `QUIET`, or `linger` passes. `None` when
/// no tree arrived within `wait`.
pub async fn read(adapter: &mut AdapterHandle, rsd: &RsdHandshake, wait: Duration, linger: Duration) -> R<Option<Tree>> {
    let port = rsd.services.get(SERVICE).ok_or("remoteAX is not advertised (developer disk image not mounted?)")?.port;
    let deadline = Instant::now() + wait;
    let mut tree = Tree::default();
    let mut last_error = None;
    while Instant::now() < deadline {
        tree.subscriptions += 1;
        let window = deadline.min(Instant::now() + RESUBSCRIBE);
        match subscribe(adapter, port, &mut tree, window, linger).await {
            Ok(true) => return Ok(Some(tree)),
            Ok(false) => {}
            Err(e) => last_error = Some(e),
        }
    }
    match last_error {
        Some(e) => Err(format!("no accessibility tree within {} ms: {e}", wait.as_millis()).into()),
        None => Ok(None),
    }
}

/// One subscription. `Ok(true)` once a tree arrived (whatever happened after);
/// `Ok(false)` when `window` passed without one.
async fn subscribe(adapter: &mut AdapterHandle, port: u16, tree: &mut Tree, window: Instant, linger: Duration) -> R<bool> {
    let mut s: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
    let mut caps = plist::Dictionary::new();
    caps.insert("com.apple.private.DTXBlockCompression".into(), 0.into());
    caps.insert("com.apple.private.DTXConnection".into(), 1.into());
    call(&mut s, 1, "_notifyOfPublishedCapabilities:", Value::Dictionary(caps), false).await?;
    call(&mut s, 2, "clientNeedsAccessibility:", true.into(), true).await?;

    let mut first: Option<Instant> = None;
    let mut last = Instant::now();
    let result: R<()> = async {
        loop {
            let until = first.map_or(window, |at| (at + linger).min(last + QUIET));
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(());
            }
            // The parser slices on lengths read off the wire and panics on a short
            // or malformed message; a panic is one more reason to resubscribe.
            let read = AssertUnwindSafe(Message::from_reader(&mut s)).catch_unwind();
            let m = match tokio::time::timeout(left, read).await {
                Err(_) => return Ok(()),
                Ok(Err(_)) => return Err("the remoteAX stream could not be parsed".into()),
                Ok(Ok(m)) => m?,
            };
            acknowledge(&mut s, &m).await?;
            let Some(AuxValue::Array(bytes)) = m.aux.as_ref().and_then(|a| a.values.first()) else { continue };
            let Some(outer) = Archive::parse(bytes) else { continue };
            let Some(inner) = outer.data(outer.root()).and_then(Archive::parse) else { continue };
            let before = first.map(|_| tree.json());
            if !tree.absorb(&inner) {
                continue;
            }
            last = Instant::now();
            match before {
                None if tree.ready() => first = Some(Instant::now()),
                Some(before) if before == tree.json() => return Ok(()),
                _ => {}
            }
        }
    }
    .await;
    let _ = call(&mut s, 3, "clientNeedsAccessibility:", false.into(), true).await;
    let _ = s.shutdown().await;
    if first.is_some() {
        return Ok(true);
    }
    result.map(|_| false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::{Dictionary, Uid};

    /// Build a keyed archive from a list of objects; index 1 is the root.
    fn archive(objects: Vec<Value>) -> Archive {
        let mut top = Dictionary::new();
        top.insert("root".into(), Value::Uid(Uid::new(1)));
        let mut d = Dictionary::new();
        d.insert("$objects".into(), Value::Array(objects));
        d.insert("$top".into(), Value::Dictionary(top));
        let mut bytes = vec![];
        Value::Dictionary(d).to_writer_binary(&mut bytes).unwrap();
        Archive::parse(&bytes).unwrap()
    }

    fn dict(pairs: &[(&str, Value)]) -> Value {
        Value::Dictionary(pairs.iter().map(|(k, v)| ((*k).to_owned(), v.clone())).collect())
    }

    fn uid(i: u64) -> Value {
        Value::Uid(Uid::new(i))
    }

    #[test]
    fn folds_an_app_root_and_an_element_with_its_attributes() {
        // 1 response(11) -> 2 {treeDump: 3} -> 3 [4, 7]
        // 4 response(4) -> 5 app object (id 900, pid 42)
        // 7 response(5) on 5 -> 8 attribute dict
        let objects = vec![
            Value::String("$null".into()),
            dict(&[("associatedRequestType", 11.into()), ("resultData", uid(2))]),
            dict(&[("NS.keys", Value::Array(vec![uid(9)])), ("NS.objects", Value::Array(vec![uid(3)]))]),
            dict(&[("NS.objects", Value::Array(vec![uid(4), uid(7)]))]),
            dict(&[("associatedRequestType", 4.into()), ("resultData", uid(5))]),
            dict(&[("objectID", uid(6)), ("pid", 42.into())]),
            Value::Integer(12155897930250627322u64.into()),
            dict(&[("associatedRequestType", 5.into()), ("associatedTranslationObject", uid(5)), ("resultData", uid(8))]),
            dict(&[
                ("NS.keys", Value::Array(vec![uid(10), uid(11), uid(12), uid(13), uid(14)])),
                ("NS.objects", Value::Array(vec![uid(15), uid(16), uid(17), uid(18), uid(19)])),
            ]),
            Value::String("treeDump".into()),
            Value::Integer(33.into()),
            Value::Integer(21.into()),
            Value::Integer(61.into()),
            Value::Integer(27.into()),
            Value::Integer(8.into()),
            Value::String("Allow".into()),
            dict(&[("NS.rectval", uid(20)), ("NS.special", 3.into())]),
            Value::Integer(9.into()),
            Value::Boolean(false),
            dict(&[("NS.objects", Value::Array(vec![uid(5)]))]),
            Value::String("{{10, 20.5}, {300, 44}}".into()),
        ];
        let mut tree = Tree::default();
        assert!(tree.absorb(&archive(objects)));
        assert_eq!(tree.apps, vec![(12155897930250627322, Some(42))]);
        let out = tree.json();
        let node = &out["nodes"]["12155897930250627322"];
        assert_eq!(node["label"], "Allow");
        assert_eq!(node["frame"], json!([10.0, 20.5, 300.0, 44.0]));
        assert_eq!(node["elementType"], 9);
        assert_eq!(node["enabled"], false);
        assert_eq!(node["children"], json!(["12155897930250627322"]));
    }

    #[test]
    fn ignores_a_response_that_is_not_a_tree() {
        let objects = vec![Value::String("$null".into()), dict(&[("associatedRequestType", 2.into()), ("resultData", uid(0))])];
        let mut tree = Tree::default();
        assert!(!tree.absorb(&archive(objects)));
        assert!(!tree.ready());
    }

    #[test]
    fn reads_foundation_geometry_strings() {
        assert_eq!(numbers("{{0, 0}, {428, 926}}"), vec![0.0, 0.0, 428.0, 926.0]);
        assert_eq!(numbers("{-1.5, 2e1}"), vec![-1.5, 20.0]);
    }
}
