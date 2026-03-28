"""
create_indexes.py — MongoDB index setup for ITrack (SDWAN Tracker)

Analyses all query patterns across endpoints and creates optimal indexes.
Safe to run multiple times — skips indexes that already exist.

Usage:
    python create_indexes.py
    MONGO_URI=mongodb://... python create_indexes.py
"""

import os
import sys
from pymongo import MongoClient, ASCENDING, DESCENDING
from pymongo.errors import OperationFailure

# ─── Config ──────────────────────────────────────────────────────────────────
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017/sdwan_tracker")
DB_NAME   = MONGO_URI.rstrip("/").rsplit("/", 1)[-1].split("?")[0]

# ─── Index definitions ────────────────────────────────────────────────────────
# Format: (collection_name, key_list, options_dict, description)
#
# Key list uses pymongo tuples: [("field", ASCENDING), ...]
# ASCENDING = 1, DESCENDING = -1
#
# Design rationale per collection is documented inline.
# ─────────────────────────────────────────────────────────────────────────────

INDEXES = [

    # =========================================================================
    # trackers — most heavily queried collection
    # =========================================================================

    # sdwan_id: unique business key. Used in find_one lookups and duplicate
    # checks on tracker creation. Unique constraint enforces data integrity.
    (
        "trackers",
        [("sdwan_id", ASCENDING)],
        {"unique": True, "name": "trackers_sdwan_id_unique"},
        "Unique lookup by SDWAN ID (tracker creation + detail view)"
    ),

    # FE dashboard: each FE sees their own trackers sorted newest-first.
    # Compound (fe.id, created_at DESC) → index-only sort, no in-memory sort.
    (
        "trackers",
        [("fe.id", ASCENDING), ("created_at", DESCENDING)],
        {"name": "trackers_fe_id_created_at"},
        "FE dashboard — all trackers for a given field engineer, newest first"
    ),

    # FEG/FS dashboards: queries by field_engineer_group with date sort.
    # Covers both single-group (ROLE_FEG) and $in multi-group (ROLE_FS) queries.
    (
        "trackers",
        [("fe.field_engineer_group", ASCENDING), ("created_at", DESCENDING)],
        {"name": "trackers_feg_created_at"},
        "FEG/FS dashboard — trackers by field_engineer_group, newest first"
    ),

    # NOC dashboard: NS operator sees their assigned trackers sorted newest-first.
    # Also covers count_documents({noc_assignee, status}) — prefix match on
    # noc_assignee lets Mongo use this index for the count queries too.
    (
        "trackers",
        [("noc_assignee", ASCENDING), ("created_at", DESCENDING)],
        {"name": "trackers_noc_assignee_created_at"},
        "NOC dashboard — trackers assigned to an NS operator, newest first"
    ),

    # Unassigned queue: find({noc_assignee: None, status: 'waiting_noc_assignment'}).
    # Status is most selective (small set), so status leads; noc_assignee filters null.
    (
        "trackers",
        [("status", ASCENDING), ("noc_assignee", ASCENDING)],
        {"name": "trackers_status_noc_assignee"},
        "Unassigned queue — waiting-for-NOC trackers with no assignee"
    ),

    # Analytics date-range queries: created_at range is the primary filter for
    # most analytics endpoints. Covers $gte/$lte scans efficiently.
    (
        "trackers",
        [("created_at", ASCENDING)],
        {"name": "trackers_created_at"},
        "Analytics — date-range queries on creation timestamp"
    ),

    # Analytics: completed_at date-range queries (separate from created_at).
    # sparse=True: documents without completed_at are excluded from the index,
    # keeping it compact — most trackers in-progress have no completed_at.
    (
        "trackers",
        [("completed_at", ASCENDING)],
        {"sparse": True, "name": "trackers_completed_at"},
        "Analytics — date-range queries on completion timestamp (sparse)"
    ),

    # Per-NS per-day analytics: {created_at: {$gte, $lt}, noc_assignee: user_id}.
    # created_at leads because it's a range; noc_assignee narrows within the range.
    (
        "trackers",
        [("created_at", ASCENDING), ("noc_assignee", ASCENDING)],
        {"name": "trackers_created_at_noc_assignee"},
        "Analytics — per-NS activity stats filtered by date range then assignee"
    ),

    # Reassignment/transfer: find({reassignment_request.to_noc_id, status:'pending'}).
    # Covers the pending-transfer banner shown on NOC tracker detail view.
    (
        "trackers",
        [
            ("reassignment_request.to_noc_id", ASCENDING),
            ("reassignment_request.status", ASCENDING),
        ],
        {"sparse": True, "name": "trackers_reassignment_request"},
        "Pending transfer requests — find inbound reassignments for an NS operator"
    ),

    # =========================================================================
    # users — authentication, role lookups, hierarchy queries
    # =========================================================================

    # Login: find_one({username}) — primary auth lookup. Unique constraint
    # prevents duplicate accounts.
    (
        "users",
        [("username", ASCENDING)],
        {"unique": True, "name": "users_username_unique"},
        "Unique login lookup by username"
    ),

    # Role-only queries: find({role: X}) appear for every role type.
    # Many endpoints fetch all NS operators, all FS, all FSG, etc.
    (
        "users",
        [("role", ASCENDING)],
        {"name": "users_role"},
        "Role-filtered user lists (NS operators, FSG admins, etc.)"
    ),

    # Role + field_engineer_group: frequent compound for FE hierarchy lookups
    # and for mapping FEs under a given group.
    (
        "users",
        [("role", ASCENDING), ("field_engineer_group", ASCENDING)],
        {"sparse": True, "name": "users_role_feg"},
        "FE hierarchy — users by role + field_engineer_group"
    ),

    # Role + field_support: maps FEG users under an FS supervisor.
    (
        "users",
        [("role", ASCENDING), ("field_support", ASCENDING)],
        {"sparse": True, "name": "users_role_field_support"},
        "FS hierarchy — users by role + field_support"
    ),

    # =========================================================================
    # chat_messages — per-tracker chat feed
    # =========================================================================

    # Primary chat fetch: find({tracker_id}).sort('timestamp', 1).
    # Compound covers both the equality filter and the sort in one index scan.
    (
        "chat_messages",
        [("tracker_id", ASCENDING), ("timestamp", ASCENDING)],
        {"name": "chat_tracker_id_timestamp"},
        "Chat feed — all messages for a tracker sorted chronologically"
    ),

    # Mark-read update_many: {tracker_id, sender_role: {$ne: role}, read: False}.
    # tracker_id + read narrows to unread messages; sender_role is the exclusion filter.
    (
        "chat_messages",
        [("tracker_id", ASCENDING), ("read", ASCENDING)],
        {"name": "chat_tracker_id_read"},
        "Mark-read — find unread messages for a tracker"
    ),

    # =========================================================================
    # predefined_reasons — small reference collection
    # =========================================================================

    # Only query: find_one({category: X}). Unique because categories are distinct.
    (
        "predefined_reasons",
        [("category", ASCENDING)],
        {"unique": True, "name": "predefined_reasons_category"},
        "Reason lookup by category (unique)"
    ),

    # =========================================================================
    # notifications — user notification feed
    # =========================================================================

    # Typical pattern: find({user_id, read}) or find({user_id}).sort(created_at).
    (
        "notifications",
        [("user_id", ASCENDING), ("created_at", DESCENDING)],
        {"name": "notifications_user_id_created_at"},
        "Notification feed per user, newest first"
    ),

    (
        "notifications",
        [("user_id", ASCENDING), ("read", ASCENDING)],
        {"name": "notifications_user_id_read"},
        "Unread notification count per user"
    ),

]

# ─── Runner ──────────────────────────────────────────────────────────────────

def get_existing_index_names(collection):
    """Return a set of existing index names on a collection."""
    return {idx["name"] for idx in collection.list_indexes()}


def create_indexes(db):
    stats = {"created": 0, "skipped": 0, "failed": 0}

    # Group by collection for cleaner output
    by_collection: dict[str, list] = {}
    for entry in INDEXES:
        col_name = entry[0]
        by_collection.setdefault(col_name, []).append(entry)

    for col_name, entries in by_collection.items():
        collection = db[col_name]
        existing   = get_existing_index_names(collection)

        print(f"\n[{col_name}]")
        for _, keys, options, description in entries:
            index_name = options.get("name", "?")
            if index_name in existing:
                print(f"  SKIP    {index_name}")
                print(f"          {description}")
                stats["skipped"] += 1
                continue

            create_opts = {**options, "background": True}
            try:
                result = collection.create_index(keys, **create_opts)
                print(f"  CREATE  {result}")
                print(f"          {description}")
                stats["created"] += 1
            except OperationFailure as exc:
                print(f"  FAIL    {index_name} — {exc}")
                stats["failed"] += 1

    return stats


def main():
    print(f"Connecting to: {MONGO_URI}")
    print(f"Database:      {DB_NAME}")

    client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    try:
        client.admin.command("ping")
        print("Connection OK\n")
    except Exception as exc:
        print(f"Cannot connect to MongoDB: {exc}", file=sys.stderr)
        sys.exit(1)

    db    = client[DB_NAME]
    stats = create_indexes(db)

    print(f"\n{'─' * 50}")
    print(f"Done. Created: {stats['created']}  Skipped: {stats['skipped']}  Failed: {stats['failed']}")
    client.close()


if __name__ == "__main__":
    main()
