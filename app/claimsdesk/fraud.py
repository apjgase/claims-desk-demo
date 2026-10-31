"""Fraud signals for a claim. Fixed rules and fixed points, so a score is reproducible.

The chat assistant explains these signals; it does not compute or change the score.
Inputs are database rows (dicts with native types), the photo index from the document
service (None when the document tier is not active), and the WORM packet (None when
it was not checked).
"""
import re
import statistics
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Iterable, List, Optional

from .photos import hamming

POINTS = {
    "duplicate_photo": 40,
    "similar_photo": 30,
    "photo_before_loss": 25,
    "repeat_policy": 15,
    "shared_identity": 20,
    "similar_description": 15,
    "amount_outlier": 15,
    "below_threshold": 10,
    "late_report": 10,
    "packet_mismatch": 50,
}
REPEAT_WINDOW_DAYS = 90
REPEAT_MAX = 30
LATE_REPORT_DAYS = 60
SIMILAR_TEXT = 0.6
SIMILAR_PHOTO_BITS = 6
THRESHOLDS = (1000, 2500, 5000, 10000, 25000, 50000)
# Fields of the packet that must still match the row. Status moves on (APPROVED, PAID).
PACKET_FIELDS = ("policy_number", "claimant_name", "contact_email", "loss_date", "loss_type",
                 "amount", "description")
OPEN = ("SUBMITTED", "IN_REVIEW")
DECIDED = ("APPROVED", "PAID")
_WORD = re.compile(r"[a-z0-9]+")


def level(score: int) -> str:
    if score >= 50:
        return "high"
    if score >= 25:
        return "medium"
    return "low" if score > 0 else "none"


def _day(value: Any) -> Optional[date]:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return datetime.fromisoformat(str(value)).date()
    except ValueError:
        return None


def _money(value: Any) -> Optional[Decimal]:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError):
        return None


def _norm(value: Any) -> str:
    return " ".join(str(value or "").lower().split())


def _tokens(text: str) -> set:
    return {w for w in _WORD.findall(text.lower()) if len(w) > 2}


def _jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def _seeded(row: Dict[str, Any]) -> bool:
    # `claims-desk seed` reuses a few template sentences, so its rows would all match each other.
    return str(row.get("created_by_host") or "").endswith("(seed)")


def _robust_z(value: float, peers: List[float]) -> Optional[float]:
    if len(peers) < 5:
        return None
    med = statistics.median(peers)
    mad = statistics.median(abs(p - med) for p in peers)
    if mad == 0:
        return None
    return 0.6745 * (value - med) / mad


def _plain(value: Any) -> Any:
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    return value


def packet_diff(row: Dict[str, Any], packet: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Fields where the database row differs from the claim stored in the WORM packet."""
    stored = (packet or {}).get("claim") or {}
    out = []
    for field in PACKET_FIELDS:
        now, then = row.get(field), stored.get(field)
        if field == "amount":
            same = _money(now) == _money(then)
        elif field == "loss_date":
            same = _day(now) == _day(then)
        else:
            same = (now or None) == (then or None)
        if not same:
            out.append({"field": field, "packet": then, "database": _plain(now)})
    return out


def related(claim: Dict[str, Any], claims: Iterable[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Other claims on the same policy, with the same contact, or with a similar description."""
    me = claim["claim_number"]
    email, name, policy = _norm(claim.get("contact_email")), _norm(claim.get("claimant_name")), claim["policy_number"]
    words = _tokens(claim.get("description") or "")
    out: Dict[str, List[Dict[str, Any]]] = {"same_policy": [], "same_contact": [], "similar_description": []}
    for other in claims:
        if other["claim_number"] == me:
            continue
        brief = {k: _plain(other.get(k)) for k in
                 ("claim_number", "policy_number", "claimant_name", "loss_type", "loss_date", "amount", "status")}
        if other["policy_number"] == policy:
            out["same_policy"].append(brief)
        elif (email and _norm(other.get("contact_email")) == email) or _norm(other.get("claimant_name")) == name:
            out["same_contact"].append(brief)
        if len(words) >= 5 and not (_seeded(claim) or _seeded(other)):
            sim = _jaccard(words, _tokens(other.get("description") or ""))
            if sim >= SIMILAR_TEXT:
                out["similar_description"].append(dict(brief, similarity=round(sim, 2)))
    return out


def analyse(claim: Dict[str, Any], claims: List[Dict[str, Any]],
            photos: Optional[Dict[str, Dict[str, Any]]] = None,
            packet: Any = None) -> Dict[str, Any]:
    """Score one claim. `packet` is the packet document, "missing", or None (not checked)."""
    me = claim["claim_number"]
    signals: List[Dict[str, Any]] = []
    checked, skipped = ["postgresql"], []

    def add(rule: str, detail: str, evidence: Optional[List[str]] = None, points: Optional[int] = None):
        signals.append({"rule": rule, "points": POINTS[rule] if points is None else points,
                        "detail": detail, "evidence": evidence or []})

    loss = _day(claim.get("loss_date"))
    submitted = _day(claim.get("created_at"))
    amount = _money(claim.get("amount"))
    others = [c for c in claims if c["claim_number"] != me]

    # Photo on Files
    if photos is None:
        skipped.append("files: document tier not active")
    else:
        checked.append("files")
        mine = photos.get(me)
        if mine:
            same = sorted(n for n, p in photos.items() if n != me and p.get("sha256") == mine.get("sha256"))
            near = sorted(n for n, p in photos.items()
                          if n != me and n not in same and mine.get("dhash") and p.get("dhash")
                          and hamming(mine["dhash"], p["dhash"]) <= SIMILAR_PHOTO_BITS)
            if same:
                add("duplicate_photo", "The same photo file is on {}.".format(", ".join(same)), same)
            elif near:
                add("similar_photo", "A near-identical photo is on {}.".format(", ".join(near)), near)
            shot = _day(mine.get("taken_at"))
            if shot and loss and (loss - shot).days > 1:
                add("photo_before_loss", "The photo was taken on {}, {} days before the loss date {}.".format(
                    shot.isoformat(), (loss - shot).days, loss.isoformat()))

    # Policy and identity
    if loss:
        repeats = sorted(c["claim_number"] for c in others if c["policy_number"] == claim["policy_number"]
                         and _day(c.get("loss_date")) and abs((_day(c["loss_date"]) - loss).days) <= REPEAT_WINDOW_DAYS)
        if repeats:
            add("repeat_policy", "{} other claim(s) on policy {} within {} days.".format(
                len(repeats), claim["policy_number"], REPEAT_WINDOW_DAYS), repeats,
                min(REPEAT_MAX, POINTS["repeat_policy"] * len(repeats)))
    email, name = _norm(claim.get("contact_email")), _norm(claim.get("claimant_name"))
    shared = sorted(c["claim_number"] for c in others if c["policy_number"] != claim["policy_number"]
                    and ((email and _norm(c.get("contact_email")) == email) or _norm(c.get("claimant_name")) == name))
    if shared:
        add("shared_identity", "The same claimant name or email appears on another policy: {}.".format(
            ", ".join(shared)), shared)

    # Description
    words = _tokens(claim.get("description") or "")
    if len(words) >= 5 and not _seeded(claim):
        alike = sorted(c["claim_number"] for c in others if not _seeded(c)
                       and _jaccard(words, _tokens(c.get("description") or "")) >= SIMILAR_TEXT)
        if alike:
            add("similar_description", "The description is nearly the same as {}.".format(", ".join(alike)), alike)

    # Amount and timing
    if amount is not None:
        peers = [float(_money(c["amount"])) for c in others if c.get("loss_type") == claim.get("loss_type")]
        basis = "{} claims".format(claim.get("loss_type"))
        if len(peers) < 5:
            peers, basis = [float(_money(c["amount"])) for c in others], "all claims"
        z = _robust_z(float(amount), peers)
        if z is not None and z > 3.5:
            add("amount_outlier", "{} is far above the median {} of {} (robust z {:.1f}).".format(
                format(amount, ",.2f"), format(statistics.median(peers), ",.2f"), basis, z))
        for t in THRESHOLDS:
            if Decimal(t) * Decimal("0.97") <= amount < t:
                add("below_threshold", "{} is just under the round figure {:,}.".format(format(amount, ",.2f"), t))
                break
    if loss and submitted and (submitted - loss).days > LATE_REPORT_DAYS:
        add("late_report", "Reported {} days after the loss.".format((submitted - loss).days))

    # Packet on Objects
    if packet is None:
        if claim.get("status") in DECIDED and claim.get("packet_url"):
            skipped.append("objects: packet not checked")
    elif packet == "missing":
        checked.append("objects")
        skipped.append("objects: packet_url is set but the object is missing")
    else:
        checked.append("objects")
        changed = packet_diff(claim, packet)
        if changed:
            add("packet_mismatch", "The database no longer matches the WORM packet written at approval: {}.".format(
                ", ".join("{} {} -> {}".format(c["field"], c["packet"], c["database"]) for c in changed)))

    score = min(100, sum(s["points"] for s in signals))
    return {
        "claim_number": me,
        "status": claim.get("status"),
        "claimant_name": claim.get("claimant_name"),
        "loss_type": claim.get("loss_type"),
        "amount": _plain(claim.get("amount")),
        "score": score,
        "level": level(score),
        "signals": signals,
        "checked": checked,
        "skipped": skipped,
    }


def scope_statuses(scope: str) -> Iterable[str]:
    return {"open": OPEN, "decided": DECIDED}.get(scope, OPEN + DECIDED + ("REJECTED",))
