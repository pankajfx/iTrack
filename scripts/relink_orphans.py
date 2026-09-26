"""
relink_orphans.py
-----------------
Re-attach trackers to the accounts that own them after a destructive user reseed.

Why this exists: seed_users.py's full mode used to delete every user and insert
fresh documents, giving every account a new _id. Trackers store their owners by
id (fe.id, noc_assignee), so every existing tracker was orphaned: field
engineers opened their own trackers with every action disabled, "My" dashboard
tabs came up empty, and NOC operators were refused chat on trackers assigned to
them. seed_users.py now upserts by username, so this should not recur - but a
database reseeded before that fix needs this repair once.

What it changes - live ownership fields only:
    trackers.fe.id         <- the user whose username equals trackers.fe.username
    trackers.noc_assignee  <- the single current NOC user whose name the tracker
                              data itself recorded for that old id: noc_name,
                              noc_history[].assignee_name, or the NOC sender name
                              on chat messages sent from that id

What it never touches: events[] and noc_history[] (they are the audit trail) and
chat sender ids (display only).

An old id that does not resolve to exactly one current user is reported, never
guessed - typically someone who has left and whose trackers need reassigning.

Usage (from the project root):
    python scripts/relink_orphans.py                     # report only, writes nothing
    python scripts/relink_orphans.py --apply             # back up, then relink
    python scripts/relink_orphans.py --restore <file>    # undo a previous --apply
"""

import argparse
import json
import os
from datetime import datetime

from bson import ObjectId
from dotenv import load_dotenv
from pymongo import MongoClient

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(ROOT, '.env'))
MONGO_URI = os.environ.get('MONGO_URI', 'mongodb://localhost:27017/sdwan_tracker')
BACKUP_DIR = os.path.join(ROOT, 'backups')

FE_ROLES = {'FIELD_ENGINEER'}
NOC_ROLES = {'NOC_SUPPORT', 'NOC_SUPPORT_GROUP'}


def plan(db):
    """Return (fe_map, noc_map, unresolved) without writing anything."""
    users = list(db.users.find({}, {'username': 1, 'name': 1, 'role': 1}))
    live = {str(u['_id']) for u in users}
    fe_by_username = {u['username']: str(u['_id']) for u in users if u.get('role') in FE_ROLES}
    noc_by_name = {}
    for u in users:
        if u.get('role') in NOC_ROLES and u.get('name'):
            noc_by_name.setdefault(u['name'], []).append(str(u['_id']))

    unresolved = []

    fe_map = {}
    for old in db.trackers.distinct('fe.id'):
        if not old or old in live:
            continue
        usernames = [x for x in db.trackers.distinct('fe.username', {'fe.id': old}) if x]
        n = db.trackers.count_documents({'fe.id': old})
        if len(usernames) == 1 and usernames[0] in fe_by_username:
            fe_map[old] = (fe_by_username[usernames[0]], usernames[0], n)
        else:
            unresolved.append(('fe.id', old, n, usernames))

    noc_map = {}
    for old in db.trackers.distinct('noc_assignee'):
        if not old or old in live:
            continue
        names = set(db.trackers.distinct('noc_name', {'noc_assignee': old}))
        for t in db.trackers.find({'noc_history.assignee_id': old}, {'noc_history': 1}):
            names |= {h.get('assignee_name') for h in t.get('noc_history') or []
                      if h.get('assignee_id') == old}
        names |= set(db.chat_messages.distinct(
            'sender_name', {'sender_id': old, 'sender_role': {'$in': list(NOC_ROLES)}}))
        names = sorted(x for x in names if x)
        n = db.trackers.count_documents({'noc_assignee': old})
        if len(names) == 1 and len(noc_by_name.get(names[0], [])) == 1:
            noc_map[old] = (noc_by_name[names[0]][0], names[0], n)
        else:
            unresolved.append(('noc_assignee', old, n, names))

    return fe_map, noc_map, unresolved


def report(fe_map, noc_map, unresolved):
    fe_n = sum(v[2] for v in fe_map.values())
    noc_n = sum(v[2] for v in noc_map.values())
    print('Field engineers : %d old ids -> current accounts, covering %d trackers' % (len(fe_map), fe_n))
    print('NOC operators   : %d old ids -> current accounts, covering %d trackers' % (len(noc_map), noc_n))
    for old, (new, name, n) in sorted(noc_map.items(), key=lambda kv: -kv[1][2]):
        print('    %s -> %-14s (%d trackers)' % (old, name, n))
    if unresolved:
        print('\nUnresolved - left untouched, need a human decision:')
        for field, old, n, names in unresolved:
            who = ', '.join(names) if names else 'no name recorded anywhere'
            print('    %-13s %s  %3d trackers  (%s)' % (field, old, n, who))
        print('  Usually someone who has left. Reassign their open trackers from the NOC')
        print('  Support Group dashboard; completed ones can stay as they are.')


def apply(db, fe_map, noc_map):
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = os.path.join(BACKUP_DIR, 'relink_%s.json' % stamp)

    affected = db.trackers.find(
        {'$or': [{'fe.id': {'$in': list(fe_map)}}, {'noc_assignee': {'$in': list(noc_map)}}]},
        {'fe.id': 1, 'noc_assignee': 1})
    backup = [{'_id': str(t['_id']), 'fe_id': (t.get('fe') or {}).get('id'),
               'noc_assignee': t.get('noc_assignee')} for t in affected]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump({'database': db.name, 'created': stamp, 'trackers': backup}, f, indent=1)
    print('\nBacked up ownership of %d trackers to %s' % (len(backup), os.path.relpath(path, ROOT)))

    fe_done = sum(db.trackers.update_many({'fe.id': old}, {'$set': {'fe.id': new}}).modified_count
                  for old, (new, _, _) in fe_map.items())
    noc_done = sum(db.trackers.update_many({'noc_assignee': old}, {'$set': {'noc_assignee': new}}).modified_count
                   for old, (new, _, _) in noc_map.items())
    print('Relinked fe.id on %d trackers, noc_assignee on %d trackers' % (fe_done, noc_done))
    print('Undo with: python scripts/relink_orphans.py --restore %s' % os.path.relpath(path, ROOT))


def restore(db, path):
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    if data.get('database') != db.name:
        raise SystemExit('Backup is for database %r, connected to %r - refusing.'
                         % (data.get('database'), db.name))
    n = 0
    for t in data['trackers']:
        n += db.trackers.update_one({'_id': ObjectId(t['_id'])},
                                    {'$set': {'fe.id': t['fe_id'],
                                              'noc_assignee': t['noc_assignee']}}).modified_count
    print('Restored ownership fields on %d trackers from %s' % (n, path))


def main():
    ap = argparse.ArgumentParser(description='Re-attach trackers orphaned by a destructive user reseed.')
    ap.add_argument('--apply', action='store_true', help='Back up, then write the relink.')
    ap.add_argument('--restore', metavar='BACKUP', help='Undo a previous --apply from its backup file.')
    args = ap.parse_args()

    client = MongoClient(MONGO_URI)
    db = client.get_default_database()
    print('Database: %s' % db.name)

    if args.restore:
        restore(db, args.restore)
        return

    fe_map, noc_map, unresolved = plan(db)
    if not fe_map and not noc_map and not unresolved:
        print('No orphaned trackers. Nothing to do.')
        return
    report(fe_map, noc_map, unresolved)
    if args.apply:
        apply(db, fe_map, noc_map)
    else:
        print('\nReport only - nothing written. Re-run with --apply to relink.')
    client.close()


if __name__ == '__main__':
    main()
