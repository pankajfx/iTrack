"""
migrate_media.py
----------------
Move inline base64 media out of documents and into GridFS.

Photos and voice notes were originally stored as `data:` URLs embedded directly in
tracker and chat documents. That made roughly 69% of tracker bytes image data, put
every photo into every dashboard list response, and re-sent whole media files on
every chat poll. See PROJECT_GUIDE.md section 15.

This script rewrites those documents in place:

    trackers.site_verification.images[].data   -> {file_id, mime, size}
    trackers.sim.sim1|sim2.images[].data       -> {file_id, mime, size}
    trackers.firmware.images[].data            -> {file_id, mime, size}
    trackers.router.images[].data              -> {file_id, mime, size}
    chat_messages.file_url                     -> media: {file_id, mime, size}

Reads stay backward compatible either way: the app renders a GridFS reference and a
legacy inline data URL identically, so running this is optional and can be done at
any time, including while the app is up.

Usage (from the project root):
    python scripts/migrate_media.py --dry-run     # report only, writes nothing
    python scripts/migrate_media.py               # perform the migration
    python scripts/migrate_media.py --batch 100   # limit documents touched

Requirements: pymongo, python-dotenv
"""

import argparse
import base64
import os
import re
import sys

import gridfs
from dotenv import load_dotenv
from pymongo import MongoClient

load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.env'))

MONGO_URI = os.environ.get('MONGO_URI', 'mongodb://localhost:27017/sdwan_tracker')
DATA_URL_RE = re.compile(r'^data:([^;,]+)(;base64)?,(.*)$', re.S)


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return '%.1f %s' % (n, unit)
        n /= 1024.0


def decode(data_url):
    """(raw_bytes, mime) for a data: URL, or None if it is not one."""
    if not data_url or not isinstance(data_url, str):
        return None
    m = DATA_URL_RE.match(data_url)
    if not m:
        return None
    mime, is_b64, payload = m.group(1), bool(m.group(2)), m.group(3)
    try:
        raw = base64.b64decode(payload) if is_b64 else payload.encode('utf-8')
    except Exception:
        return None
    return raw, mime


class Migrator:
    def __init__(self, db, dry_run):
        self.db = db
        self.fs = gridfs.GridFS(db, collection='media')
        self.dry_run = dry_run
        self.files = 0
        self.bytes = 0

    def offload(self, data_url, tracker_id, kind):
        """Inline data URL -> GridFS reference dict. None if not inline."""
        decoded = decode(data_url)
        if not decoded:
            return None
        raw, mime = decoded
        self.files += 1
        self.bytes += len(raw)
        if self.dry_run:
            return {'file_id': 'dry-run', 'mime': mime, 'size': len(raw)}
        file_id = self.fs.put(raw, contentType=mime,
                              metadata={'tracker_id': tracker_id, 'kind': kind})
        return {'file_id': str(file_id), 'mime': mime, 'size': len(raw)}

    def migrate_image_list(self, images, tracker_id, kind):
        """Returns (new_list, changed)."""
        changed = False
        out = []
        for img in images or []:
            if not isinstance(img, dict) or not img.get('data'):
                out.append(img)
                continue
            ref = self.offload(img['data'], tracker_id, kind)
            if not ref:
                out.append(img)
                continue
            entry = {k: v for k, v in img.items() if k != 'data'}
            entry.update(ref)
            out.append(entry)
            changed = True
        return out, changed


def migrate_trackers(mig, batch):
    db = mig.db
    query = {'$or': [
        {'site_verification.images.data': {'$exists': True}},
        {'sim.sim1.images.data': {'$exists': True}},
        {'sim.sim2.images.data': {'$exists': True}},
        {'firmware.images.data': {'$exists': True}},
        {'router.images.data': {'$exists': True}},
    ]}
    cursor = db.trackers.find(query)
    if batch:
        cursor = cursor.limit(batch)

    touched = 0
    for t in cursor:
        tid = str(t['_id'])
        updates = {}

        imgs, changed = mig.migrate_image_list(
            (t.get('site_verification') or {}).get('images'), tid, 'site_verification')
        if changed:
            updates['site_verification.images'] = imgs

        for key in ('sim1', 'sim2'):
            imgs, changed = mig.migrate_image_list(
                ((t.get('sim') or {}).get(key) or {}).get('images'), tid, 'sim')
            if changed:
                updates['sim.%s.images' % key] = imgs

        for field in ('firmware', 'router'):
            imgs, changed = mig.migrate_image_list(
                (t.get(field) or {}).get('images'), tid, field)
            if changed:
                updates['%s.images' % field] = imgs

        if updates:
            touched += 1
            if not mig.dry_run:
                db.trackers.update_one({'_id': t['_id']}, {'$set': updates})
    return touched


def migrate_chat(mig, batch):
    db = mig.db
    cursor = db.chat_messages.find({'file_url': {'$regex': '^data:'}})
    if batch:
        cursor = cursor.limit(batch)

    touched = 0
    for m in cursor:
        ref = mig.offload(m['file_url'], m.get('tracker_id'), m.get('type', 'image'))
        if not ref:
            continue
        touched += 1
        if not mig.dry_run:
            db.chat_messages.update_one(
                {'_id': m['_id']},
                {'$set': {'media': ref}, '$unset': {'file_url': ''}})
    return touched


def main():
    ap = argparse.ArgumentParser(
        description='Move inline base64 media from documents into GridFS.')
    ap.add_argument('--dry-run', action='store_true',
                    help='Report what would move without writing anything.')
    ap.add_argument('--batch', type=int, default=0,
                    help='Maximum documents to touch per collection (0 = all).')
    args = ap.parse_args()

    client = MongoClient(MONGO_URI)
    db = client.get_default_database()

    before = db.command('collstats', 'trackers').get('size', 0)
    mig = Migrator(db, args.dry_run)

    print('Mode: %s' % ('DRY RUN - nothing will be written' if args.dry_run else 'LIVE'))
    print('')
    trackers = migrate_trackers(mig, args.batch)
    chats = migrate_chat(mig, args.batch)

    print('  trackers rewritten     : %d' % trackers)
    print('  chat messages rewritten: %d' % chats)
    print('  media files moved      : %d' % mig.files)
    print('  media bytes moved      : %s' % human(mig.bytes))

    if not args.dry_run:
        after = db.command('collstats', 'trackers').get('size', 0)
        print('')
        print('  trackers collection    : %s -> %s' % (human(before), human(after)))
        print('')
        print('  Storage is reclaimed lazily by WiredTiger. To reclaim it now:')
        print('      db.runCommand({compact: "trackers"})')

    client.close()


if __name__ == '__main__':
    main()
