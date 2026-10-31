"""Demo data for the stage 5 assistant: a few suspicious claims, with photos on Files.

  sudo claims-desk seed-fraud

Claims, photos and the approval go through the middleware API (CLAIMS_API_URL), so this
works at stage 4 and 5 when the portal itself may not reach PostgreSQL. One step, the
change to an approved claim behind the packet's back, needs a database login from this
VM; it is skipped with a note when the Flow policy drops that path.

What the fraud scan should find:
  ring      two claimants, one email, the same car photo, nearly the same story (high)
  repeat    a second claim on the ring's policy within 90 days; its photo shows a kitchen in
            use, not a flood (the vision model should say so; the rules cannot)
  old photo hail damage photographed a year before the loss, amount just under 10,000 (medium)
  outlier   a travel claim far above every other amount, reported late (medium)
  tamper    an approved claim whose amount was raised after its WORM packet was written (high)
  control   an ordinary windscreen claim (none)

Photos in samples/ are public domain or CC0, from Wikimedia Commons: "Oh deer!.jpg" (Nyttend),
"FEMA - 43964 - Volunteers working in a kitchen in Tennessee.jpg" (David Fine, FEMA),
"Hail damage car.jpg" (Simiprof, CC0; EXIF date added here), "Windshield-spiderweb.jpg" (Tysto).
"""
import sys
from datetime import date, timedelta
from pathlib import Path

import httpx
import psycopg

from . import config, db

SAMPLES = Path(__file__).parent / "samples"
MARKER = "POL-77120"


def _claims(today: date):
    d = lambda n: (today - timedelta(days=n)).isoformat()  # noqa: E731
    ring_email = "d.brooks.claims@example.net"
    return [
        ("ring", {"policy_number": MARKER, "claimant_name": "Daniel Brooks", "contact_email": ring_email,
                  "loss_date": d(12), "loss_type": "Auto", "amount": "6400.00", "adjuster": "J. Doyle",
                  "description": "Hit a deer on a country road at dusk. Front bumper split and the "
                                 "left headlight unit pushed in."}, "car_front.jpg"),
        ("ring", {"policy_number": "POL-80455", "claimant_name": "Dana Brookes", "contact_email": ring_email,
                  "loss_date": d(6), "loss_type": "Auto", "amount": "6900.00", "adjuster": "S. Ito",
                  "description": "Hit a deer on the country road at dusk; front bumper is split and "
                                 "the left headlight unit pushed in."}, "car_front.jpg"),
        ("repeat", {"policy_number": MARKER, "claimant_name": "Daniel Brooks", "contact_email": ring_email,
                    "loss_date": d(41), "loss_type": "Property", "amount": "3100.00", "adjuster": "J. Doyle",
                    "description": "Washing machine hose burst overnight and flooded the laundry "
                                   "and kitchen floor."}, "kitchen.jpg"),
        ("old photo", {"policy_number": "POL-64211", "claimant_name": "Priya Raman",
                       "contact_email": "priya.raman@example.com", "loss_date": d(4), "loss_type": "Auto",
                       "amount": "9850.00", "adjuster": "M. Fernandes",
                       "description": "Hail storm on Tuesday night smashed the rear window and dented "
                                      "the roof and boot of the car."}, "hail_car.jpg"),
        ("outlier", {"policy_number": "POL-59033", "claimant_name": "Tom Okafor",
                     "contact_email": "tom.okafor@example.com", "loss_date": d(95), "loss_type": "Travel",
                     "amount": "68000.00", "adjuster": None,
                     "description": "Medical evacuation from a ski resort: helicopter transfer, "
                                    "hospital stay and flights home."}, None),
        ("control", {"policy_number": "POL-31876", "claimant_name": "Grace Lee",
                     "contact_email": "grace.lee@example.com", "loss_date": d(2), "loss_type": "Auto",
                     "amount": "1250.00", "adjuster": "A. Rahman",
                     "description": "Stone thrown up by a truck on the motorway cracked the windscreen."},
         "windscreen.jpg"),
        ("tamper", {"policy_number": "POL-42290", "claimant_name": "Henry Walker",
                    "contact_email": "henry.walker@example.com", "loss_date": d(20), "loss_type": "Property",
                    "amount": "4200.00", "adjuster": "S. Ito",
                    "description": "A fallen branch broke three fence panels along the back boundary."}, None),
    ]


def _check(r: httpx.Response, what: str):
    if r.status_code >= 400:
        sys.exit("ERROR: {} failed: HTTP {} {}".format(what, r.status_code, r.text[:200]))
    return r.json()


def _tamper(cfg, claim_number: str) -> str:
    try:
        with psycopg.connect(db.conninfo(cfg, app_name="claims-desk-seed-fraud", connect_timeout=5),
                             autocommit=True) as conn:
            conn.execute("UPDATE claims SET amount = amount + 10000, updated_at = now() "
                         "WHERE claim_number = %s", [claim_number])
        return "amount raised by 10,000 in PostgreSQL; the WORM packet keeps the approved amount"
    except psycopg.Error as exc:
        return ("skipped: this VM cannot log in to PostgreSQL ({}). At stage 4 and 5 the Flow policy "
                "may drop it. Run the UPDATE from a host that can: UPDATE {}.claims SET amount = "
                "amount + 10000 WHERE claim_number = '{}';").format(str(exc).strip().splitlines()[0][:120],
                                                                     cfg["db_schema"], claim_number)


def _existing(api: httpx.Client, claim: dict):
    """The demo claim already in the database: same policy, claimant and description."""
    rows = _check(api.get("/api/v1/claims", params={"q": claim["claimant_name"], "limit": 100}), "search")
    for row in rows:
        if (row["policy_number"], row["claimant_name"], row["description"]) == \
                (claim["policy_number"], claim["claimant_name"], claim["description"]):
            return row
    return None


def _upload(api: httpx.Client, number: str, photo: str) -> None:
    blob = (SAMPLES / photo).read_bytes()
    _check(api.post("/api/v1/claims/{}/photo".format(number),
                    files={"photo": (photo, blob, "image/jpeg")}), "photo upload")


def main() -> None:
    """Adds the demo claims that are missing. Safe to run on every --stage 5: existing ones are kept
    as they are (a missing photo is added once the document tier is active), never duplicated."""
    cfg = config.load()
    with httpx.Client(base_url=cfg["api_url"], timeout=60) as api:
        documents = bool((_check(api.get("/api/v1/info"), "info").get("documents") or {}).get("enabled"))
        if not documents:
            print("seed-fraud: the document tier is not active, so no photos and no packet")
        lines, added = [], 0
        for label, claim, photo in _claims(date.today()):
            row = _existing(api, claim)
            if row is not None:
                number, note = row["claim_number"], "already there"
                if photo and documents and not row.get("photo_path"):
                    _upload(api, number, photo)
                    note += "; photo " + photo + " added"
                lines.append((number, label, note))
                continue
            number = _check(api.post("/api/v1/claims", json=claim), "create claim")["claim_number"]
            added += 1
            note = "added"
            if photo and documents:
                _upload(api, number, photo)
                note += ", photo " + photo
            if label == "tamper":
                _check(api.patch("/api/v1/claims/" + number, json={"status": "APPROVED"}), "approve")
                note += ", approved"
                if documents:
                    note += ", packet written to Objects; " + _tamper(cfg, number)
            elif label in ("ring", "old photo"):
                _check(api.patch("/api/v1/claims/" + number, json={"status": "IN_REVIEW"}), "status")
            lines.append((number, label, note))
    for number, label, note in lines:
        print("  {}  {:<9}  {}".format(number, label, note))
    print("seed-fraud: {} added, {} already there. Ask the assistant: Which open claims look suspicious?".format(
        added, len(lines) - added))


if __name__ == "__main__":
    main()
