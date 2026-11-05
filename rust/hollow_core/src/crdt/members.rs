//! Who was a member when: every admission and removal an identity's record holds, as
//! events in clock order, and the spans they fold into.
//!
//! The spans are DERIVED: an op that arrives behind a checkpoint inserts its event at its
//! own clock and the spans fold again, so a late leave, a rejoin the owner never saw and
//! a re-admission it saw all land where history put them. The events ride the checkpoint,
//! so an op it holds is recognized exactly (`crdt::dominance`).

use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use super::server_state::MemberSpan;

/// The ask of an admission synthesized from a span persisted before 0.14: it always
/// opens and spends nothing, as those spans did.
pub(crate) const LEGACY_ASK: i64 = i64::MIN;

/// One change to an identity's membership, as the op that made it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "k")]
pub enum MemberEvent {
    /// A `MemberAdded` (or the founder's seat, `by` empty), with the `at` of its ask.
    #[serde(rename = "a")]
    Admit {
        at: HlcTimestamp,
        #[serde(default)]
        by: String,
        ask: i64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        name: String,
    },
    /// The member's own `MemberRemoved`.
    #[serde(rename = "l")]
    Leave { at: HlcTimestamp },
    /// A removal or ban by someone else.
    #[serde(rename = "r")]
    Remove { at: HlcTimestamp },
}

impl MemberEvent {
    pub fn at(&self) -> &HlcTimestamp {
        match self {
            Self::Admit { at, .. } | Self::Leave { at } | Self::Remove { at } => at,
        }
    }

    fn rank(&self) -> u8 {
        match self {
            Self::Admit { .. } => 0,
            Self::Leave { .. } => 1,
            Self::Remove { .. } => 2,
        }
    }
}

fn order(a: &MemberEvent, b: &MemberEvent) -> std::cmp::Ordering {
    a.at().cmp(b.at()).then(a.rank().cmp(&b.rank())).then_with(|| match (a, b) {
        (MemberEvent::Admit { by: x, ask: p, .. }, MemberEvent::Admit { by: y, ask: q, .. }) => x.cmp(y).then(p.cmp(q)),
        _ => std::cmp::Ordering::Equal,
    })
}

/// Whether `events` already holds the very event `e` (the op that made it).
pub(crate) fn holds(events: &[MemberEvent], e: &MemberEvent) -> bool {
    events.iter().any(|x| match (x, e) {
        (MemberEvent::Admit { at: a, by: b, .. }, MemberEvent::Admit { at, by, .. }) => a == at && b == by,
        _ => x == e,
    })
}

/// Insert `e` in clock order; false when it was already held.
pub(crate) fn insert(events: &mut Vec<MemberEvent>, e: MemberEvent) -> bool {
    if holds(events, &e) {
        return false;
    }
    let at = events.partition_point(|x| order(x, &e) != std::cmp::Ordering::Greater);
    events.insert(at, e);
    true
}

/// The spans `events` fold into: an admission opens a span only on an ask newer than every
/// one that opened a span before and than the member's last own leave before it (HOL-SEC-092,
/// F9); while open, it only records its author. A removal closes the open span.
pub(crate) fn derive(events: &[MemberEvent]) -> Vec<MemberSpan> {
    let mut spans: Vec<MemberSpan> = Vec::new();
    let mut spent: Option<i64> = None;
    let mut last_leave: Option<u64> = None;
    for e in events {
        let open = spans.last_mut().filter(|s| s.until_ms == u64::MAX);
        match e {
            MemberEvent::Admit { at, by, ask, .. } => match open {
                Some(span) => note(span, by, at),
                None if opens(*ask, spent, last_leave) => {
                    let exact = !at.actor.is_empty();
                    spans.push(MemberSpan {
                        from_ms: at.physical_ms,
                        until_ms: u64::MAX,
                        asked_at: if *ask == LEGACY_ASK { 0 } else { *ask },
                        from_hlc: exact.then(|| at.clone()),
                        admitted: if by.is_empty() { Vec::new() } else { vec![(by.clone(), at.clone())] },
                        until_hlc: None,
                    });
                    if *ask != LEGACY_ASK {
                        spent = Some(spent.map_or(*ask, |s| s.max(*ask)));
                    }
                }
                None => {}
            },
            MemberEvent::Leave { at } | MemberEvent::Remove { at } => {
                if let Some(span) = open {
                    span.until_ms = at.physical_ms.max(span.from_ms);
                    span.until_hlc = (!at.actor.is_empty()).then(|| at.clone());
                    if matches!(e, MemberEvent::Leave { .. }) {
                        last_leave = Some(at.physical_ms);
                    }
                }
            }
        }
    }
    spans
}

fn opens(ask: i64, spent: Option<i64>, last_leave: Option<u64>) -> bool {
    ask == LEGACY_ASK
        || (spent.is_none_or(|s| ask > s) && last_leave.is_none_or(|l| i128::from(ask) > i128::from(l)))
}

fn note(span: &mut MemberSpan, by: &str, at: &HlcTimestamp) {
    if by.is_empty() {
        return;
    }
    match span.admitted.iter_mut().find(|(author, _)| author == by) {
        Some((_, hlc)) if at < hlc => *hlc = at.clone(),
        Some(_) => {}
        None => span.admitted.push((by.to_string(), at.clone())),
    }
}

/// The events behind spans persisted before 0.14: each span's opening and closing, and
/// its recorded admitters on the span's own ask. Folds back into the same spans.
pub(crate) fn from_spans(spans: &[MemberSpan]) -> Vec<MemberEvent> {
    let mut events = Vec::new();
    for s in spans {
        let from = s.from_hlc.clone().unwrap_or_else(|| inexact(s.from_ms));
        let ask = if s.asked_at == 0 { LEGACY_ASK } else { s.asked_at };
        events.push(MemberEvent::Admit { at: from.clone(), by: String::new(), ask, name: String::new() });
        for (by, at) in &s.admitted {
            events.push(MemberEvent::Admit { at: at.clone(), by: by.clone(), ask, name: String::new() });
        }
        if s.until_ms != u64::MAX {
            let until = s.until_hlc.clone().unwrap_or_else(|| inexact(s.until_ms));
            events.push(MemberEvent::Remove { at: until });
        }
    }
    events.sort_by(order);
    events
}

/// A clock known only to the millisecond: sorts first within it and marks its span
/// inexact.
fn inexact(ms: u64) -> HlcTimestamp {
    HlcTimestamp { physical_ms: ms, counter: 0, actor: String::new() }
}

/// What inserting an admission at its clock does to the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admission {
    /// Its target rules refuse it at its clock (a spent ask, an ask older than a leave).
    Ignored,
    /// The member was already in at that clock: it records its author.
    Repeat,
    /// It opens the member's current span after everything the record holds.
    Opens,
    /// It moves the start of the span after it back to its clock, on that span's own ask.
    Extends,
    /// Anything else: a span opened inside the record's history or across another ask.
    Rewrites,
}

/// See [`Admission`]. `events` is the member's record without the admission.
pub(crate) fn admission(events: &[MemberEvent], e: &MemberEvent) -> Admission {
    let MemberEvent::Admit { at, ask, .. } = e else { return Admission::Ignored };
    let before = derive(events);
    let mut with = events.to_vec();
    if !insert(&mut with, e.clone()) {
        return Admission::Repeat;
    }
    let after = derive(&with);
    let inside = |s: &MemberSpan| span_contains(s, at);
    let Some(holder) = after.iter().find(|s| inside(s)) else { return Admission::Ignored };
    if holder.from_hlc.as_ref() != Some(at) {
        return Admission::Repeat;
    }
    if after.len() == before.len() + 1 && after[..before.len()] == before[..] && holder.until_ms == u64::MAX {
        return Admission::Opens;
    }
    // The one span after `at` it swallowed, opened on this same ask, no removal between.
    let next = before.iter().find(|s| s.from_hlc.as_ref().is_none_or(|f| f > at) && s.from_ms >= at.physical_ms);
    match next {
        Some(n) if n.asked_at == *ask && after.len() == before.len() && holder.until_ms == n.until_ms => Admission::Extends,
        _ => Admission::Rewrites,
    }
}

/// Whether `s` covers the clock `at`: from its opening up to, not including, its end.
pub(crate) fn span_contains(s: &MemberSpan, at: &HlcTimestamp) -> bool {
    let after_start = match &s.from_hlc {
        Some(from) => from <= at,
        None => s.from_ms <= at.physical_ms,
    };
    let before_end = s.until_ms == u64::MAX
        || match &s.until_hlc {
            Some(until) => at < until,
            None => at.physical_ms < s.until_ms,
        };
    after_start && before_end
}

/// The display name the member's current span opened with.
pub(crate) fn opening_name<'a>(events: &'a [MemberEvent], span: &MemberSpan) -> Option<&'a str> {
    events.iter().find_map(|e| match e {
        MemberEvent::Admit { at, name, .. }
            if !name.is_empty() && span.from_hlc.as_ref().map_or(at.physical_ms == span.from_ms, |f| f == at) =>
        {
            Some(name.as_str())
        }
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(ms: u64) -> HlcTimestamp {
        HlcTimestamp { physical_ms: ms, counter: 0, actor: "a".into() }
    }

    fn admit(ms: u64, ask: i64) -> MemberEvent {
        MemberEvent::Admit { at: t(ms), by: "b".into(), ask, name: String::new() }
    }

    #[test]
    fn a_late_leave_closes_the_span_and_a_newer_ask_reopens_it() {
        let mut ev = vec![admit(10, 5), admit(30, 25)];
        assert_eq!(derive(&ev).len(), 1);
        insert(&mut ev, MemberEvent::Leave { at: t(20) });
        let spans = derive(&ev);
        assert_eq!(spans.len(), 2, "the repeat on a newer ask opens again after the leave");
        assert_eq!(spans[0].until_ms, 20);
        assert_eq!(spans[1].until_ms, u64::MAX);
    }

    #[test]
    fn an_ask_older_than_the_leave_does_not_reopen() {
        let mut ev = vec![admit(10, 5), admit(30, 15)];
        insert(&mut ev, MemberEvent::Leave { at: t(20) });
        let spans = derive(&ev);
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].until_ms, 20, "F9: an ask signed before the leave never brings it back");
    }

    #[test]
    fn a_spent_ask_never_opens_a_span_in_a_gap() {
        let ev = vec![admit(1, 1), MemberEvent::Remove { at: t(5) }, admit(10, 8)];
        assert_eq!(admission(&ev, &admit(7, 1)), Admission::Ignored);
        assert_eq!(admission(&ev, &admit(7, 8)), Admission::Extends);
        assert_eq!(admission(&ev, &admit(7, 6)), Admission::Rewrites);
        assert_eq!(admission(&ev, &admit(3, 1)), Admission::Repeat);
        assert_eq!(admission(&ev, &admit(12, 9)), Admission::Repeat);
        let out = vec![admit(1, 1), MemberEvent::Remove { at: t(5) }];
        assert_eq!(admission(&out, &admit(9, 7)), Admission::Opens);
    }

    #[test]
    fn spans_written_before_0_14_fold_back_unchanged() {
        let spans = vec![
            MemberSpan { from_ms: 0, until_ms: 50, ..MemberSpan::default() },
            MemberSpan { from_ms: 60, until_ms: u64::MAX, asked_at: 59, from_hlc: Some(t(60)), admitted: vec![("b".into(), t(60))], until_hlc: None },
        ];
        assert_eq!(derive(&from_spans(&spans)), spans);
    }
}
