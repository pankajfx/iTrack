"""
seed_form_options.py — seed the `form_options` collection for the Android app

Populates the dropdown lists served by GET /api/android/form-options
(customers, SIM providers, router types, router makes). Values come from
android_backend/form_defaults.py, which mirrors the lists hardcoded in
templates/fe_new_installation.html.

Idempotent and NON-destructive: each category is upserted only if missing.
Re-running never overwrites a list you have edited in the database —
use --force to reset all categories back to the defaults.

Usage (run from project root):
    python scripts/seed_form_options.py
    python scripts/seed_form_options.py --force
    MONGO_URI=mongodb://... python scripts/seed_form_options.py
"""

import os
import sys
from datetime import datetime, timezone

from pymongo import MongoClient, ASCENDING
from dotenv import load_dotenv

# Allow importing android_backend when run as `python scripts/seed_form_options.py`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from android_backend.form_defaults import DEFAULT_FORM_OPTIONS

# Load environment variables from the project-root .env (parent of scripts/).
load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))

MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017/sdwan_tracker")
DB_NAME   = MONGO_URI.rstrip("/").rsplit("/", 1)[-1].split("?")[0]


def get_utc_now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def seed(db, force=False):
    stats = {"created": 0, "updated": 0, "skipped": 0}

    db.form_options.create_index(
        [("category", ASCENDING)], unique=True, name="form_options_category"
    )

    for category, values in DEFAULT_FORM_OPTIONS.items():
        existing = db.form_options.find_one({"category": category})
        if existing and not force:
            print(f"  SKIP    {category} ({len(existing.get('values', []))} values already present)")
            stats["skipped"] += 1
            continue

        db.form_options.update_one(
            {"category": category},
            {"$set": {"values": values, "updated_at": get_utc_now()}},
            upsert=True,
        )
        action = "UPDATE" if existing else "CREATE"
        print(f"  {action}  {category} ({len(values)} values)")
        stats["updated" if existing else "created"] += 1

    return stats


def main():
    force = "--force" in sys.argv
    print(f"Connecting to: {MONGO_URI}")
    print(f"Database:      {DB_NAME}")
    if force:
        print("Mode:          FORCE (resetting all categories to defaults)")

    client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    try:
        client.admin.command("ping")
        print("Connection OK\n")
    except Exception as exc:
        print(f"Cannot connect to MongoDB: {exc}", file=sys.stderr)
        sys.exit(1)

    stats = seed(client[DB_NAME], force=force)

    print("\n" + "-" * 50)
    print(f"Done. Created: {stats['created']}  Updated: {stats['updated']}  Skipped: {stats['skipped']}")
    client.close()


if __name__ == "__main__":
    main()
