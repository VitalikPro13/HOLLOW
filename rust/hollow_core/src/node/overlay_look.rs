//! The stream overlay LOOK manifest (`look_json`): one image per state plus
//! effects. Rust is the one parser: every other layer (the ask and answer, the
//! overlay server, Dart) reads the canonical JSON [`normalize`] returns.
//!
//! A look comes from other people, so it is bounded and shape-checked before use:
//! closed enums (an unknown value becomes the default), clamped numbers, unknown
//! keys dropped (an older client tolerates a newer look), a state that is not a
//! 64-hex hash or empty refuses the whole look.

use serde_json::{Map, Value};

/// Largest look body accepted, in bytes.
pub(crate) const MAX_LOOK_BYTES: usize = 4096;

/// The states a look may carry an image for, in canonical order.
pub(crate) const STATES: [&str; 6] = ["idle", "talking", "muted", "deafened", "blink", "loud"];

const TALKING: [&str; 5] = ["none", "bounce", "shake", "pop", "glow"];
const IDLE: [&str; 3] = ["none", "dim", "grayscale"];
const TRANSITION: [&str; 2] = ["instant", "crossfade"];
const SHADOW: [&str; 3] = ["none", "soft", "outline"];

/// One effect key: its wire name and how a raw value becomes a canonical one.
enum Effect {
    Choice(&'static str, &'static [&'static str], &'static str),
    Flag(&'static str, bool),
    Whole(&'static str, i64, i64, i64),
    Fraction(&'static str, f64, f64, f64),
}

/// Every effect key with its default, in canonical order.
const EFFECTS: [Effect; 9] = [
    Effect::Choice("talking", &TALKING, "bounce"),
    Effect::Flag("scale_with_voice", true),
    Effect::Choice("idle", &IDLE, "none"),
    Effect::Choice("transition", &TRANSITION, "crossfade"),
    Effect::Whole("hold_ms", 0, 600, 250),
    Effect::Whole("blink_every_s", 2, 12, 5),
    Effect::Fraction("loud_threshold", 0.50, 0.95, 0.75),
    Effect::Flag("mirror", false),
    Effect::Choice("shadow", &SHADOW, "none"),
];

impl Effect {
    fn key(&self) -> &'static str {
        match self {
            Effect::Choice(k, ..) | Effect::Flag(k, _) | Effect::Whole(k, ..) | Effect::Fraction(k, ..) => k,
        }
    }

    fn default_value(&self) -> Value {
        match self {
            Effect::Choice(_, _, d) => Value::from(*d),
            Effect::Flag(_, d) => Value::from(*d),
            Effect::Whole(.., d) => Value::from(*d),
            Effect::Fraction(.., d) => Value::from(*d),
        }
    }

    /// The canonical value for `raw`: in range, or the default.
    fn canonical(&self, raw: &Value) -> Value {
        match self {
            Effect::Choice(_, allowed, d) => {
                let v = raw.as_str().filter(|s| allowed.contains(s)).unwrap_or(d);
                Value::from(v)
            }
            Effect::Flag(_, d) => Value::from(raw.as_bool().unwrap_or(*d)),
            Effect::Whole(_, lo, hi, d) => {
                let v = raw.as_f64().filter(|f| f.is_finite()).map_or(*d, |f| f.round() as i64);
                Value::from(v.clamp(*lo, *hi))
            }
            Effect::Fraction(_, lo, hi, d) => {
                let v = raw.as_f64().filter(|f| f.is_finite()).unwrap_or(*d).clamp(*lo, *hi);
                // Two decimals: the slider's resolution, and one value has one spelling.
                Value::from((v * 100.0).round() / 100.0)
            }
        }
    }
}

/// Whether `s` names an image: empty, or 64 lowercase hex.
fn state_value_ok(s: &str) -> bool {
    s.is_empty() || (s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
}

/// A parsed look: the stamp, one entry per [`STATES`] and the effects map. In a
/// LOCAL look an empty state and an absent effect key mean "not overridden".
#[derive(Clone, Debug, PartialEq)]
struct Look {
    stamp: i64,
    states: [String; 6],
    effects: Map<String, Value>,
}

impl Look {
    fn to_json(&self) -> String {
        let mut states = Map::new();
        for (name, hash) in STATES.iter().zip(self.states.iter()) {
            states.insert((*name).to_string(), Value::from(hash.as_str()));
        }
        let mut effects = Map::new();
        for e in &EFFECTS {
            if let Some(v) = self.effects.get(e.key()) {
                effects.insert(e.key().to_string(), v.clone());
            }
        }
        // `serde_json::Map` keeps insertion order only with `preserve_order`, so the
        // canonical text is written out by hand: one look has exactly one spelling.
        let mut out = format!("{{\"v\":1,\"stamp\":{},\"states\":{{", self.stamp);
        for (i, name) in STATES.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("\"{name}\":\"{}\"", self.states[i]));
        }
        out.push_str("},\"effects\":{");
        let mut first = true;
        for e in &EFFECTS {
            if let Some(v) = effects.get(e.key()) {
                if !first {
                    out.push(',');
                }
                first = false;
                out.push_str(&format!("\"{}\":{}", e.key(), v));
            }
        }
        out.push_str("}}");
        out
    }
}

/// Parse and bound `json`. `fill` puts the default in for every absent effect key
/// (a shared look); a local look keeps them absent.
fn parse(json: &str, fill: bool) -> Result<Look, String> {
    if json.len() > MAX_LOOK_BYTES {
        return Err(format!("The look is over {MAX_LOOK_BYTES} bytes"));
    }
    let root: Value = serde_json::from_str(json).map_err(|_| "The look is not valid JSON".to_string())?;
    let root = root.as_object().ok_or("The look is not an object")?;
    let stamp = root
        .get("stamp")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0);
    let mut states: [String; 6] = Default::default();
    if let Some(given) = root.get("states") {
        let given = given.as_object().ok_or("The look's states are not an object")?;
        for (i, name) in STATES.iter().enumerate() {
            let Some(raw) = given.get(*name) else { continue };
            let hash = raw.as_str().ok_or_else(|| format!("The {name} image is not a hash"))?;
            if !state_value_ok(hash) {
                return Err(format!("The {name} image is not a hash"));
            }
            states[i] = hash.to_string();
        }
    }
    let given = root.get("effects").and_then(Value::as_object);
    let mut effects = Map::new();
    for e in &EFFECTS {
        match given.and_then(|g| g.get(e.key())) {
            Some(raw) => {
                effects.insert(e.key().to_string(), e.canonical(raw));
            }
            None if fill => {
                effects.insert(e.key().to_string(), e.default_value());
            }
            None => {}
        }
    }
    Ok(Look { stamp, states, effects })
}

/// The canonical JSON of a SHARED look (every effect key present), or why it is
/// refused.
pub(crate) fn normalize(json: &str) -> Result<String, String> {
    parse(json, true).map(|l| l.to_json())
}

/// The canonical JSON of a LOCAL look (a streamer's picks for one person): absent
/// effect keys stay absent, since they mean "not overridden".
pub(crate) fn normalize_local(json: &str) -> Result<String, String> {
    parse(json, false).map(|l| l.to_json())
}

/// The look a person is drawn with: their shared look (the defaults when we hold
/// none) with the local picks laid over it state by state and key by key.
/// Inputs that do not parse count as absent.
pub(crate) fn effective(shared: Option<&str>, local: Option<&str>) -> String {
    let mut look = shared
        .and_then(|s| parse(s, true).ok())
        .unwrap_or_else(|| parse("{}", true).expect("the empty look parses"));
    if let Some(local) = local.and_then(|l| parse(l, false).ok()) {
        for (mine, theirs) in look.states.iter_mut().zip(local.states.iter()) {
            if !theirs.is_empty() {
                mine.clone_from(theirs);
            }
        }
        for (key, value) in local.effects {
            look.effects.insert(key, value);
        }
    }
    look.to_json()
}

/// The image hashes a look names, each once.
pub(crate) fn hashes(json: &str) -> Vec<String> {
    let Ok(look) = parse(json, false) else { return Vec::new() };
    let mut out: Vec<String> = Vec::new();
    for h in look.states {
        if !h.is_empty() && !out.contains(&h) {
            out.push(h);
        }
    }
    out
}

/// The `stamp` of a look, 0 when it does not parse.
pub(crate) fn stamp(json: &str) -> i64 {
    parse(json, false).map_or(0, |l| l.stamp)
}

/// `json` with its stamp replaced; the look must already be canonical.
pub(crate) fn with_stamp(json: &str, stamp: i64) -> Result<String, String> {
    let mut look = parse(json, true)?;
    look.stamp = stamp.max(0);
    Ok(look.to_json())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(c: char) -> String {
        c.to_string().repeat(64)
    }

    fn effects_of(json: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(json).unwrap()["effects"].as_object().unwrap().clone()
    }

    #[test]
    fn a_look_normalizes_to_one_canonical_spelling() {
        let json = format!(
            r#"{{"stamp":5,"v":1,"effects":{{"talking":"pop"}},"states":{{"talking":"{}","idle":"{}"}}}}"#,
            h('b'),
            h('a')
        );
        let out = normalize(&json).unwrap();
        assert_eq!(
            out,
            format!(
                "{{\"v\":1,\"stamp\":5,\"states\":{{\"idle\":\"{}\",\"talking\":\"{}\",\"muted\":\"\",\"deafened\":\"\",\"blink\":\"\",\"loud\":\"\"}},\
                 \"effects\":{{\"talking\":\"pop\",\"scale_with_voice\":true,\"idle\":\"none\",\"transition\":\"crossfade\",\
                 \"hold_ms\":250,\"blink_every_s\":5,\"loud_threshold\":0.75,\"mirror\":false,\"shadow\":\"none\"}}}}",
                h('a'),
                h('b')
            )
        );
        assert_eq!(normalize(&out).unwrap(), out, "canonical text is a fixed point");
    }

    #[test]
    fn closed_enums_fall_back_to_their_default() {
        let out = normalize(
            r#"{"effects":{"talking":"explode","idle":"sepia","transition":"wipe","shadow":3,"mirror":"yes","scale_with_voice":null}}"#,
        )
        .unwrap();
        let e = effects_of(&out);
        assert_eq!(e["talking"], "bounce");
        assert_eq!(e["idle"], "none");
        assert_eq!(e["transition"], "crossfade");
        assert_eq!(e["shadow"], "none");
        assert_eq!(e["mirror"], false);
        assert_eq!(e["scale_with_voice"], true);
        for (k, v) in [("talking", "glow"), ("idle", "grayscale"), ("transition", "instant"), ("shadow", "outline")] {
            let out = normalize(&format!(r#"{{"effects":{{"{k}":"{v}"}}}}"#)).unwrap();
            assert_eq!(effects_of(&out)[k], v, "{k}={v} is a known value");
        }
    }

    #[test]
    fn numbers_are_clamped() {
        let e = effects_of(&normalize(r#"{"effects":{"hold_ms":9000,"blink_every_s":1,"loud_threshold":0.2}}"#).unwrap());
        assert_eq!((e["hold_ms"].as_i64(), e["blink_every_s"].as_i64(), e["loud_threshold"].as_f64()), (Some(600), Some(2), Some(0.5)));
        let e = effects_of(&normalize(r#"{"effects":{"hold_ms":-5,"blink_every_s":99,"loud_threshold":7}}"#).unwrap());
        assert_eq!((e["hold_ms"].as_i64(), e["blink_every_s"].as_i64(), e["loud_threshold"].as_f64()), (Some(0), Some(12), Some(0.95)));
        let e = effects_of(&normalize(r#"{"effects":{"hold_ms":"lots","loud_threshold":0.8333}}"#).unwrap());
        assert_eq!((e["hold_ms"].as_i64(), e["loud_threshold"].as_f64()), (Some(250), Some(0.83)));
        assert_eq!(stamp(&normalize(r#"{"stamp":-4}"#).unwrap()), 0, "a stamp is never negative");
    }

    #[test]
    fn unknown_keys_are_dropped() {
        let out = normalize(r#"{"v":7,"extra":{"x":1},"states":{"halo":"zz"},"effects":{"sparkle":true}}"#).unwrap();
        assert!(!out.contains("extra") && !out.contains("halo") && !out.contains("sparkle"), "{out}");
        assert!(out.starts_with("{\"v\":1,"), "a newer version is read as the one we know");
    }

    #[test]
    fn a_state_that_is_not_a_hash_refuses_the_look() {
        for bad in [
            "\"nothex\"".to_string(),
            format!("\"{}\"", "A".repeat(64)),
            format!("\"{}\"", "a".repeat(63)),
            format!("\"{}0\"", "a".repeat(64)),
            "5".to_string(),
            "null".to_string(),
        ] {
            let json = format!(r#"{{"states":{{"loud":{bad}}}}}"#);
            assert!(normalize(&json).is_err(), "{bad} must refuse the look");
            assert!(normalize_local(&json).is_err(), "{bad} must refuse a local look too");
        }
        assert!(normalize(r#"{"states":[]}"#).is_err());
        assert!(normalize("[1]").is_err());
        assert!(normalize("not json").is_err());
    }

    #[test]
    fn the_body_is_bounded() {
        let pad = "x".repeat(MAX_LOOK_BYTES);
        assert!(normalize(&format!(r#"{{"pad":"{pad}"}}"#)).is_err());
        let fits = format!(r#"{{"pad":"{}"}}"#, "x".repeat(MAX_LOOK_BYTES - 20));
        assert!(fits.len() <= MAX_LOOK_BYTES);
        assert!(normalize(&fits).is_ok());
    }

    #[test]
    fn a_local_look_keeps_absent_effects_absent() {
        let out = normalize_local(r#"{"effects":{"idle":"dim"}}"#).unwrap();
        let e = effects_of(&out);
        assert_eq!(e.len(), 1, "{out}");
        assert_eq!(e["idle"], "dim");
    }

    #[test]
    fn effective_lays_local_picks_over_the_shared_look() {
        let shared = normalize(&format!(
            r#"{{"stamp":9,"states":{{"idle":"{}","talking":"{}"}},"effects":{{"talking":"shake","hold_ms":100}}}}"#,
            h('a'),
            h('b')
        ))
        .unwrap();
        let local = normalize_local(&format!(
            r#"{{"states":{{"talking":"{}","muted":"{}"}},"effects":{{"hold_ms":400}}}}"#,
            h('c'),
            h('d')
        ))
        .unwrap();
        let eff: Value = serde_json::from_str(&effective(Some(&shared), Some(&local))).unwrap();
        assert_eq!(eff["states"]["idle"], h('a'), "an empty local state is not an override");
        assert_eq!(eff["states"]["talking"], h('c'));
        assert_eq!(eff["states"]["muted"], h('d'));
        assert_eq!(eff["effects"]["talking"], "shake", "an absent local key is not an override");
        assert_eq!(eff["effects"]["hold_ms"], 400);
        assert_eq!(eff["stamp"], 9);

        let only_local: Value = serde_json::from_str(&effective(None, Some(&local))).unwrap();
        assert_eq!(only_local["states"]["talking"], h('c'));
        assert_eq!(only_local["effects"]["talking"], "bounce", "the defaults stand in for a look we do not hold");
        assert_eq!(effective(None, None), normalize("{}").unwrap());
        assert_eq!(effective(Some(&shared), None), shared);
        assert_eq!(effective(Some("garbage"), Some("garbage")), normalize("{}").unwrap());
    }

    #[test]
    fn hashes_lists_each_image_once() {
        let look = normalize(&format!(r#"{{"states":{{"idle":"{}","blink":"{}","loud":"{}"}}}}"#, h('a'), h('a'), h('e'))).unwrap();
        assert_eq!(hashes(&look), vec![h('a'), h('e')]);
    }
}
