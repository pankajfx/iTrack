"""
seed_trackers.py
────────────────
Clears ALL existing trackers and chat_messages, then inserts 200 consistent
test trackers covering every lifecycle stage, spread across the last 40 days
with fewer trackers on weekends.

Run any time to reset test data relative to the current date.

Usage:
    python seed_trackers.py

Requirements:
    - MongoDB running, users already seeded (run init_db.py first)
    - At least 1 FIELD_ENGINEER and 1 NOC_SUPPORT user must exist in db.users
"""

import os
import random
from collections import Counter
from datetime import datetime, timedelta
from pymongo import MongoClient
from bson import ObjectId

random.seed()  # fresh seed each run so spread varies

MONGO_URI = os.environ.get('MONGO_URI', 'mongodb://localhost:27017/sdwan_tracker')
#prod
# MONGO_URI  = os.environ.get('MONGO_URI', 'mongodb://myAdminUser:MyStrongPassword123@localhost:27017/sdwan_tracker?authSource=admin')
client = MongoClient(MONGO_URI)
db = client.get_default_database()

ROLE_FE = 'FIELD_ENGINEER'
ROLE_NS = 'NOC_SUPPORT'

fe_users = list(db.users.find({'role': ROLE_FE}))
ns_users = list(db.users.find({'role': ROLE_NS}))

if not fe_users:
    print("ERROR: No FIELD_ENGINEER users found. Run init_db.py first.")
    exit(1)
if not ns_users:
    print("ERROR: No NOC_SUPPORT users found. Run init_db.py first.")
    exit(1)

print(f"Found {len(fe_users)} FE user(s) and {len(ns_users)} NS user(s).")

# ── Clear existing data ───────────────────────────────────────────────────────
print("\nClearing existing trackers and chat messages...")
dt = db.trackers.delete_many({}).deleted_count
dc = db.chat_messages.delete_many({}).deleted_count
print(f"  Deleted {dt} trackers, {dc} chat messages.")

# ── Low-level helpers ─────────────────────────────────────────────────────────
NOW = datetime.utcnow()

def mk_event(stage, actor_id, actor_role, remarks, ts):
    return {
        'stage': stage, 'timestamp': ts, 'actor': actor_id,
        'actor_role': actor_role, 'remarks': remarks,
        'metadata': {}, 'delay_tags': [],
    }

def sim_slot(provider, number, status='pending'):
    return {
        'provider': provider, 'number': number, 'status': status,
        'images': [], 'attempts': [], 'failure_reason': None,
        'root_cause_of_initial_failure': None, 'activation_started_at': None,
    }

def base_ts(created_at):
    return {
        'tracker_created_at': created_at,
        'noc_assigned_at': None,
        'sim1_activation_started_at': None, 'sim1_activation_done_at': None,
        'sim2_activation_started_at': None, 'sim2_activation_done_at': None,
        'ztp_config_verified_at': None, 'ztp_started_at': None, 'ztp_done_at': None,
        'ready_for_coordination_at': None, 'hso_submitted_at': None,
        'hso_approved_at': None, 'installation_complete_at': None,
    }

PROVIDERS    = ['Airtel', 'Jio', 'BSNL', 'Vi', 'Airtel']
ROUTER_MAKES = ['Peplink', 'Cisco', 'Zyxel', 'Fortinet', 'Cradlepoint']
STREET_TYPES = ['MG Road', 'Industrial Area', 'Tech Park', 'Commercial Zone',
                'Main Street', 'Export Zone', 'MIDC Road', 'NH Bypass']
REJECTION_REASONS = [
    'Router serial number photo is blurry. Please re-upload.',
    'Site completion photo missing. Attach full front-panel view.',
    'Cable management photo required. Re-upload with clear view.',
    'SIM ICCID not visible in photo. Retake with better lighting.',
    'Customer sign-off form missing. Obtain signature and resubmit.',
    'Installation date on form does not match tracker date.',
    'Router make/model on form does not match device.',
    'Incorrect site address on HSO form. Correct and resubmit.',
    'WAN LED status unclear in photo. Retake with device powered on.',
    'Firmware version on form is outdated. Correct and resubmit.',
]
SIM_FAIL_REASONS = [
    'SIM not registered on network',
    'ICCID mismatch with provisioning system',
    'Provider portal error — SIM blocked',
    'Network coverage issue at site',
    'SIM card damaged — replacement required',
]
CUSTOMERS = [
    'Sharma Enterprises', 'Mehta Textiles', 'Kapoor Foods', 'Patel Motors',
    'Gupta Pharma', 'Reddy Constructions', 'Singhania Retail', 'Verma Auto Parts',
    'Rao IT Solutions', 'Nair Textiles', 'Kumar Exports', 'Bose Electronics',
    'Pillai Hospitality', 'Agarwal Diamonds', 'Mishra Logistics', 'Joshi Agro',
    'Tata Teleservices', 'Birla Cement', 'Mahindra Tractors', 'Bajaj Electricals',
    'Hero Cycles', 'Wipro Infrastructure', 'Infosys Campus', 'HCL Technologies',
    'Tech Mahindra', 'Reliance Retail', 'HDFC Bank', 'ICICI Securities',
    'Axis Bank Branch', 'SBI Regional Office', 'Kotak Mahindra', 'IndusInd Bank',
    'Yes Bank', 'Godrej Properties', 'L&T Construction', 'Adani Ports',
    'Vedanta Mining', 'JSW Steel', 'ONGC Facility', 'BPCL Depot',
    'Hindustan Unilever', 'ITC Limited', 'Dabur India', 'Marico Industries',
    'Colgate India', 'Nestle India', 'Britannia Industries', 'Parle Products',
    'Amul Dairy', 'Mother Dairy', 'Haldirams', 'MDH Spices', 'Everest Masala',
    'Patanjali Store', 'Himalaya Drug', 'Sun Pharma', 'Cipla Medical',
    'Dr Reddys Labs', 'Lupin Limited', 'Aurobindo Pharma', 'Zydus Lifesciences',
    'Torrent Pharma', 'Alkem Labs', 'Glenmark', 'Apollo Hospitals',
    'Fortis Healthcare', 'Max Healthcare', 'Narayana Health', 'Manipal Hospitals',
    'DLF Office Park', 'Embassy REIT', 'Prestige Estates', 'Sobha Limited',
    'Brigade Group', 'Shapoorji Pallonji', 'Flipkart Warehouse', 'Amazon FC',
    'Meesho Office', 'Nykaa Warehouse', 'Myntra Fulfilment', 'Zomato HQ',
    'Swiggy Office', 'Ola Cabs', 'Uber India', 'Porter Logistics',
    'Delhivery Hub', 'BlueDart Centre', 'FedEx India', 'DHL Express',
    'Air India Cargo', 'IndiGo Ground', 'SpiceJet Ops', 'Indian Railways Depot',
    'DMRC Station', 'BMRCL Control', 'Hyderabad Metro', 'Chennai Metro',
    'Pune Metro', 'Nagpur Metro', 'Ahmedabad BRTS', 'Kochi Water Metro',
    'Titan Industries', 'Malabar Gold', 'PC Jeweller', 'Tanishq Outlet',
]
CITIES = [
    'Delhi', 'Mumbai', 'Bangalore', 'Chennai', 'Hyderabad', 'Pune', 'Ahmedabad',
    'Kolkata', 'Jaipur', 'Lucknow', 'Surat', 'Chandigarh', 'Coimbatore',
    'Nagpur', 'Indore', 'Bhopal', 'Patna', 'Ludhiana', 'Agra', 'Nashik',
    'Vadodara', 'Rajkot', 'Madurai', 'Kochi', 'Visakhapatnam', 'Bhubaneswar',
    'Guwahati', 'Dehradun', 'Raipur', 'Ranchi', 'Mysuru', 'Mangaluru',
]

def pick_fe(idx):
    u = fe_users[idx % len(fe_users)]
    return {
        'id': str(u['_id']),
        'username': u.get('username', 'fe'),
        'name': u.get('name', u.get('username', 'FE User')),
        'phone': u.get('contact', '9800000001'),
        'email': u.get('email', ''),
        'field_engineer_group': u.get('field_engineer_group', ''),
        'field_support': u.get('field_support', ''),
        'region': u.get('region', ''),
        'zone': u.get('zone', ''),
        'history': [{'fe_name': u.get('name', 'FE User'),
                     'assigned_at': NOW - timedelta(days=60), 'left_at': None}],
    }

def pick_ns(idx):
    u = ns_users[idx % len(ns_users)]
    return {'id': str(u['_id']), 'name': u.get('name', u.get('username', 'NS User'))}

def sim_num(n):
    return f"8991{n:016d}"[:20]

# ── Generate 200 creation timestamps spread over 40 days ─────────────────────
# Weekdays: 5-9 trackers/day, weekends: 0-2 trackers/day
creation_times = []
for days_back in range(40, 0, -1):
    base_date = NOW - timedelta(days=days_back)
    is_weekend = base_date.weekday() >= 5
    count = random.randint(0, 2) if is_weekend else random.randint(5, 9)
    for _ in range(count):
        ts = base_date.replace(
            hour=random.randint(7, 18),
            minute=random.randint(0, 59),
            second=random.randint(0, 59),
            microsecond=0,
        )
        creation_times.append(ts)

# Ensure exactly 200, trim excess or pad with recent weekday times
while len(creation_times) < 200:
    days_back = random.randint(2, 10)
    base_date = NOW - timedelta(days=days_back)
    creation_times.append(base_date.replace(
        hour=random.randint(8, 17), minute=random.randint(0, 59), second=0, microsecond=0
    ))

random.shuffle(creation_times)
creation_times = sorted(creation_times[:200])
print(f"Scheduled {len(creation_times)} creation timestamps across "
      f"{len(set(t.date() for t in creation_times))} days.")

# ── Profile assignment by tracker age ─────────────────────────────────────────
# Newer trackers → active stages; older → mostly completed
def assign_profile(created_at):
    age_days = (NOW - created_at).total_seconds() / 86400

    if age_days < 1:
        weights = {
            'waiting': 0.60,
            'sim_in_progress': 0.30,
            'both_sims_done': 0.10,
        }
    elif age_days < 3:
        weights = {
            'waiting': 0.20,
            'sim_in_progress': 0.25,
            'sim1_done_sim2_inprogress': 0.10,
            'both_sims_done': 0.10,
            'sim2_failed': 0.05,
            'ztp_verified': 0.10,
            'fe_requested_noc_ztp': 0.05,
            'ready_for_coordination': 0.10,
            'hso_submitted': 0.05,
        }
    elif age_days < 7:
        weights = {
            'waiting': 0.05,
            'sim_in_progress': 0.10,
            'sim1_done_sim2_inprogress': 0.05,
            'both_sims_done': 0.05,
            'sim2_failed': 0.05,
            'ztp_verified': 0.05,
            'fe_requested_noc_ztp': 0.05,
            'ready_for_coordination': 0.15,
            'hso_submitted': 0.10,
            'hso_rejected_pending': 0.10,
            'hso_rejected_multi': 0.05,
            'complete': 0.20,
        }
    else:
        weights = {
            'waiting': 0.01,
            'sim_in_progress': 0.02,
            'ready_for_coordination': 0.05,
            'hso_submitted': 0.05,
            'hso_rejected_pending': 0.05,
            'hso_rejected_multi': 0.05,
            'complete': 0.77,
        }

    total = sum(weights.values())
    r = random.random() * total
    cumulative = 0.0
    for profile, w in weights.items():
        cumulative += w
        if r <= cumulative:
            return profile
    return 'complete'

# ── Tracker factory ───────────────────────────────────────────────────────────
trackers_to_insert = []
chat_msgs_to_insert = []

for idx, created_at in enumerate(creation_times):
    n   = idx + 1
    fe  = pick_fe(random.randrange(len(fe_users)))
    ns  = pick_ns(random.randrange(len(ns_users)))
    tid = ObjectId()
    profile = assign_profile(created_at)

    # ── Skeleton ──────────────────────────────────────────────────────────────
    tracker = {
        '_id': tid,
        'tracker_id': f"SDWAN-{created_at.year}-{n:06d}",
        'sdwan_id': f"SW{n:05d}",
        'customer': CUSTOMERS[n % len(CUSTOMERS)],
        'site_name': f"{CUSTOMERS[n % len(CUSTOMERS)]} {['HQ', 'Branch', 'Site', 'Unit', 'Depot'][n % 5]}",
        'site_address': (f"{random.randint(1, 250)} "
                         f"{STREET_TYPES[n % len(STREET_TYPES)]}, "
                         f"{CITIES[n % len(CITIES)]}"),
        'fe': fe,
        'noc_assignee': None,
        'noc_history': [],
        'noc_name': None,
        'sim': {
            'sim1': sim_slot(PROVIDERS[n % len(PROVIDERS)],       sim_num(n * 10 + 1)),
            'sim2': sim_slot(PROVIDERS[(n + 1) % len(PROVIDERS)], sim_num(n * 10 + 2)),
        },
        'router': {
            'type': 'LTE',
            'make': ROUTER_MAKES[n % len(ROUTER_MAKES)],
            'firmware_version': f'v{random.randint(1,4)}.{random.randint(0,9)}.{random.randint(0,5)}',
            'images': [],
        },
        'firmware': {
            'version': f'v{random.randint(1,4)}.{random.randint(0,9)}.{random.randint(0,5)}',
            'images': [],
        },
        'ztp': {
            'config_status': 'pending', 'config_verified_at': None,
            'config_failure_reason': None, 'status': 'pending',
            'performed_by': None, 'fe_requested_ns': False,
            'initiated_at': None, 'completed_at': None,
            'failure_reason': None, 'root_cause_of_initial_failure': None,
            'attempts': [],
        },
        'hso': {
            'status': 'pending', 'submitted_at': None,
            'approved_at': None, 'rejected_at': None,
            'rejection_reason': None, 'attempts': [],
        },
        'stage_timestamps': base_ts(created_at),
        'events': [mk_event('tracker_created', fe['id'], ROLE_FE,
                             'Installation tracker created at site', created_at)],
        'status': 'waiting_noc_assignment',
        'created_at': created_at,
        'updated_at': created_at,
        'completed_at': None,
        'reassignment_request': None,
    }

    # ── Timeline mutation helpers (close over `tracker`, `fe`, `ns`) ──────────
    def assign_ns_fn(t):
        tracker['noc_assignee'] = ns['id']
        tracker['noc_name']     = ns['name']
        tracker['noc_history']  = [{'noc_id': ns['id'], 'noc_name': ns['name'],
                                    'assigned_at': t, 'left_at': None}]
        tracker['stage_timestamps']['noc_assigned_at'] = t
        tracker['events'].append(mk_event('noc_assigned', ns['id'], ROLE_NS,
                                          f"Assigned to {ns['name']}", t))
        tracker['status']     = 'noc_working'
        tracker['updated_at'] = t

    def start_sim1_fn(t):
        tracker['sim']['sim1'].update({
            'status': 'activation_in_process', 'activation_started_at': t,
            'attempts': [{'attempt_no': 1, 'started_at': t, 'result': None, 'reason': None}],
        })
        tracker['stage_timestamps']['sim1_activation_started_at'] = t
        tracker['events'].append(mk_event('sim1_activation_in_process', ns['id'], ROLE_NS,
                                          'SIM1 activation initiated with provider', t))
        tracker['updated_at'] = t

    def done_sim1_fn(t):
        tracker['sim']['sim1']['status'] = 'activation_complete_manual'
        tracker['sim']['sim1']['attempts'][0]['result'] = 'success'
        tracker['stage_timestamps']['sim1_activation_done_at'] = t
        tracker['events'].append(mk_event('sim1_activation_complete_manual', ns['id'], ROLE_NS,
                                          'SIM1 activated successfully', t))
        tracker['updated_at'] = t

    def start_sim2_fn(t):
        tracker['sim']['sim2'].update({
            'status': 'activation_in_process', 'activation_started_at': t,
            'attempts': [{'attempt_no': 1, 'started_at': t, 'result': None, 'reason': None}],
        })
        tracker['stage_timestamps']['sim2_activation_started_at'] = t
        tracker['events'].append(mk_event('sim2_activation_in_process', ns['id'], ROLE_NS,
                                          'SIM2 activation initiated with provider', t))
        tracker['updated_at'] = t

    def done_sim2_fn(t):
        tracker['sim']['sim2']['status'] = 'activation_complete_manual'
        tracker['sim']['sim2']['attempts'][0]['result'] = 'success'
        tracker['stage_timestamps']['sim2_activation_done_at'] = t
        tracker['events'].append(mk_event('sim2_activation_complete_manual', ns['id'], ROLE_NS,
                                          'SIM2 activated successfully', t))
        tracker['updated_at'] = t

    def fail_sim2_fn(t, reason):
        tracker['sim']['sim2']['status'] = 'failed'
        tracker['sim']['sim2']['failure_reason'] = reason
        tracker['sim']['sim2']['attempts'][0].update({'result': 'failed', 'reason': reason})
        tracker['stage_timestamps']['sim2_activation_done_at'] = t
        tracker['events'].append(mk_event('sim2_activation_failed', ns['id'], ROLE_NS,
                                          f'SIM2 activation failed: {reason}', t))
        tracker['updated_at'] = t

    def verify_ztp_fn(t):
        tracker['ztp']['config_status']   = 'config_verified'
        tracker['ztp']['config_verified_at'] = t
        tracker['stage_timestamps']['ztp_config_verified_at'] = t
        tracker['events'].append(mk_event('ztp_config_verified', ns['id'], ROLE_NS,
                                          'ZTP configuration verified by NS', t))
        tracker['status']     = 'ztp_pull_pending'
        tracker['updated_at'] = t

    def fe_req_noc_ztp_fn(t):
        tracker['ztp']['fe_requested_ns'] = True
        tracker['events'].append(mk_event('fe_requested_noc_ztp', fe['id'], ROLE_FE,
                                          'FE cannot perform ZTP on-site — requesting NS to execute remotely', t))
        tracker['status']     = 'fe_requested_ztp'
        tracker['updated_at'] = t

    def do_ztp_fn(performer, t_start, t_end):
        aid   = fe['id'] if performer == 'FE' else ns['id']
        arole = ROLE_FE  if performer == 'FE' else ROLE_NS
        init  = f'ztp_initiated_by_{"fe" if performer == "FE" else "noc"}'
        done  = f'ztp_completed_by_{"fe" if performer == "FE" else "noc"}'
        tracker['ztp'].update({
            'status': 'completed', 'performed_by': performer,
            'initiated_at': t_start, 'completed_at': t_end,
            'attempts': [{'performed_by': performer, 'started_at': t_start,
                          'result': 'success', 'reason': None}],
        })
        tracker['stage_timestamps']['ztp_started_at'] = t_start
        tracker['stage_timestamps']['ztp_done_at']    = t_end
        tracker['events'].append(mk_event(init, aid, arole, f'ZTP initiated by {performer}', t_start))
        tracker['events'].append(mk_event(done, aid, arole, f'ZTP completed by {performer}', t_end))
        tracker['updated_at'] = t_end

    def mark_ready_fn(t):
        tracker['stage_timestamps']['ready_for_coordination_at'] = t
        tracker['events'].append(mk_event('ready_for_coordination', ns['id'], ROLE_NS,
                                          'SIM & ZTP complete. Chat unlocked. Ready for FE coordination.', t))
        tracker['status']     = 'ready_for_coordination'
        tracker['updated_at'] = t

    def submit_hso_fn(t, attempt_no):
        if attempt_no == 1:
            tracker['hso']['submitted_at'] = t
            tracker['stage_timestamps']['hso_submitted_at'] = t
        tracker['hso']['status'] = 'submitted'
        tracker['hso']['attempts'].append({
            'attempt_no': attempt_no, 'submitted_at': t,
            'action': 'submitted', 'actor': fe['id'], 'reason': None,
        })
        tracker['events'].append(mk_event('hso_submitted', fe['id'], ROLE_FE,
                                          f'HSO submitted by FE (attempt #{attempt_no})', t))
        tracker['status']     = 'hso_submitted'
        tracker['updated_at'] = t

    def reject_hso_fn(t, reason):
        sub_count = sum(1 for a in tracker['hso']['attempts'] if a['action'] == 'submitted')
        tracker['hso'].update({'status': 'rejected', 'rejected_at': t, 'rejection_reason': reason})
        tracker['hso']['attempts'].append({
            'attempt_no': sub_count, 'submitted_at': t,
            'action': 'rejected', 'actor': ns['id'], 'reason': reason,
        })
        tracker['events'].append(mk_event('hso_rejected', ns['id'], ROLE_NS,
                                          f'HSO rejected: {reason}', t))
        tracker['status']     = 'hso_rejected'
        tracker['updated_at'] = t

    def approve_hso_fn(t):
        sub_count = sum(1 for a in tracker['hso']['attempts'] if a['action'] == 'submitted')
        tracker['hso'].update({'status': 'approved', 'approved_at': t})
        tracker['hso']['attempts'].append({
            'attempt_no': sub_count, 'submitted_at': t,
            'action': 'approved', 'actor': ns['id'], 'reason': None,
        })
        tracker['stage_timestamps'].update({
            'hso_approved_at': t, 'installation_complete_at': t,
        })
        tracker['events'].append(mk_event('hso_approved', ns['id'], ROLE_NS,
                                          'HSO approved. Installation complete.', t))
        tracker['events'].append(mk_event('installation_complete', 'system', 'system',
                                          'Installation completed successfully', t))
        tracker['status']       = 'installation_complete'
        tracker['completed_at'] = t
        tracker['updated_at']   = t

    def chat(sender_id, sender_role, sender_name, text, t):
        chat_msgs_to_insert.append({
            'tracker_id': str(tid), 'sender_id': sender_id,
            'sender_role': sender_role, 'sender_name': sender_name,
            'message': text, 'type': 'text', 'timestamp': t, 'read': True,
        })

    # ── Randomised time deltas (vary per tracker) ──────────────────────────────
    td = lambda lo, hi, unit='minutes': timedelta(**{unit: random.randint(lo, hi)})

    t_assign   = created_at   + td(30, 180)
    t_s1start  = t_assign     + td(10,  45)
    t_s1done   = t_s1start    + td(30,  90)
    t_s2start  = t_s1done     + td(5,   20)
    t_s2done   = t_s2start    + td(25,  75)
    t_ztpver   = t_s2done     + td(15,  60)
    t_ztpstart = t_ztpver     + td(5,   30)
    t_ztpdone  = t_ztpstart   + td(10,  30)
    t_ready    = t_ztpdone    + td(3,   15)
    t_hso1     = t_ready      + td(60, 240)
    t_rev1     = t_hso1       + td(60, 360)
    t_hso2     = t_rev1       + td(60, 480)
    t_rev2     = t_hso2       + td(60, 360)
    t_hso3     = t_rev2       + td(60, 300)
    t_rev3     = t_hso3       + td(60, 360)

    # 35% of installations: NS performs ZTP (either via FE request or directly)
    ztp_by_ns = random.random() < 0.35

    # ── Build timeline per profile ─────────────────────────────────────────────
    if profile == 'waiting':
        pass  # status already 'waiting_noc_assignment'

    elif profile == 'sim_in_progress':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)

    elif profile == 'sim1_done_sim2_inprogress':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)

    elif profile == 'both_sims_done':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)

    elif profile == 'sim2_failed':
        # SIM2 failed; only SIM1 active — installation can still proceed
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        fail_sim2_fn(t_s2done, random.choice(SIM_FAIL_REASONS))
        verify_ztp_fn(t_ztpver)

    elif profile == 'ztp_verified':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)

    elif profile == 'fe_requested_noc_ztp':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        fe_req_noc_ztp_fn(t_ztpver + td(30, 120))

    elif profile == 'ready_for_coordination':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        if ztp_by_ns:
            fe_req_noc_ztp_fn(t_ztpver + td(15, 60))
        do_ztp_fn('NS' if ztp_by_ns else 'FE', t_ztpstart, t_ztpdone)
        mark_ready_fn(t_ready)
        chat(fe['id'], ROLE_FE, fe['name'], 'Hi, all equipment is connected and ready.', t_ready + td(3, 10))
        chat(ns['id'], ROLE_NS, ns['name'], 'Good. Check router LEDs — power and LTE should be green.', t_ready + td(8, 18))
        chat(fe['id'], ROLE_FE, fe['name'], 'Confirmed. Power and LTE LEDs are solid green, WAN blinking.', t_ready + td(15, 25))
        chat(ns['id'], ROLE_NS, ns['name'], 'Perfect. Submit HSO with all required photos when ready.', t_ready + td(20, 35))

    elif profile == 'hso_submitted':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        if ztp_by_ns:
            fe_req_noc_ztp_fn(t_ztpver + td(15, 60))
        do_ztp_fn('NS' if ztp_by_ns else 'FE', t_ztpstart, t_ztpdone)
        mark_ready_fn(t_ready)
        submit_hso_fn(t_hso1, 1)
        chat(ns['id'], ROLE_NS, ns['name'], 'All looks good on our end. Submit HSO when ready.', t_ready + td(5, 20))
        chat(fe['id'], ROLE_FE, fe['name'], 'Done. HSO submitted with all required photos.', t_hso1 + td(2, 8))

    elif profile == 'hso_rejected_pending':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        if ztp_by_ns:
            fe_req_noc_ztp_fn(t_ztpver + td(15, 60))
        do_ztp_fn('NS' if ztp_by_ns else 'FE', t_ztpstart, t_ztpdone)
        mark_ready_fn(t_ready)
        submit_hso_fn(t_hso1, 1)
        reason = random.choice(REJECTION_REASONS)
        reject_hso_fn(t_rev1, reason)
        chat(ns['id'], ROLE_NS, ns['name'], f'HSO rejected: {reason}', t_rev1 + td(2, 8))
        chat(fe['id'], ROLE_FE, fe['name'], 'Understood. I will correct the issue and resubmit.', t_rev1 + td(10, 30))

    elif profile == 'hso_rejected_multi':
        # Rejected twice — waiting for 3rd submission
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        if ztp_by_ns:
            fe_req_noc_ztp_fn(t_ztpver + td(15, 60))
        do_ztp_fn('NS' if ztp_by_ns else 'FE', t_ztpstart, t_ztpdone)
        mark_ready_fn(t_ready)
        submit_hso_fn(t_hso1, 1)
        reason1 = random.choice(REJECTION_REASONS[:5])
        reject_hso_fn(t_rev1, reason1)
        submit_hso_fn(t_hso2, 2)
        reason2 = random.choice(REJECTION_REASONS[5:])
        reject_hso_fn(t_rev2, reason2)
        chat(ns['id'], ROLE_NS, ns['name'], f'Rejected again: {reason2}', t_rev2 + td(3, 10))
        chat(fe['id'], ROLE_FE, fe['name'], 'My apologies. Will fix all issues and resubmit.', t_rev2 + td(15, 45))

    elif profile == 'complete':
        assign_ns_fn(t_assign)
        start_sim1_fn(t_s1start)
        done_sim1_fn(t_s1done)
        start_sim2_fn(t_s2start)
        # ~12% of completed trackers had SIM2 fail (installation still completed with SIM1 only)
        if random.random() < 0.12:
            fail_sim2_fn(t_s2done, random.choice(SIM_FAIL_REASONS))
        else:
            done_sim2_fn(t_s2done)
        verify_ztp_fn(t_ztpver)
        if ztp_by_ns:
            fe_req_noc_ztp_fn(t_ztpver + td(15, 60))
        do_ztp_fn('NS' if ztp_by_ns else 'FE', t_ztpstart, t_ztpdone)
        mark_ready_fn(t_ready)
        # HSO outcome: ~5% rejected twice then approved, ~20% rejected once then approved, ~75% straight approval
        roll = random.random()
        if roll < 0.05:
            submit_hso_fn(t_hso1, 1)
            reject_hso_fn(t_rev1, random.choice(REJECTION_REASONS[:5]))
            submit_hso_fn(t_hso2, 2)
            reject_hso_fn(t_rev2, random.choice(REJECTION_REASONS[5:]))
            submit_hso_fn(t_hso3, 3)
            approve_hso_fn(t_rev3)
        elif roll < 0.25:
            submit_hso_fn(t_hso1, 1)
            reject_hso_fn(t_rev1, random.choice(REJECTION_REASONS))
            submit_hso_fn(t_hso2, 2)
            approve_hso_fn(t_rev2)
        else:
            submit_hso_fn(t_hso1, 1)
            approve_hso_fn(t_rev1)
        t_final = tracker['updated_at']
        chat(ns['id'], ROLE_NS, ns['name'], 'All looks good. Submit HSO when ready.', t_ready + td(10, 25))
        chat(fe['id'], ROLE_FE, fe['name'], 'Done. All photos uploaded and HSO submitted.', t_hso1 + td(2, 10))
        chat(ns['id'], ROLE_NS, ns['name'], 'HSO approved. Installation complete. Well done!', t_final)

    trackers_to_insert.append(tracker)

# ── Insert ────────────────────────────────────────────────────────────────────
print(f"\nInserting {len(trackers_to_insert)} trackers...")
db.trackers.insert_many(trackers_to_insert)

if chat_msgs_to_insert:
    print(f"Inserting {len(chat_msgs_to_insert)} chat messages...")
    db.chat_messages.insert_many(chat_msgs_to_insert)

# ── Summary ───────────────────────────────────────────────────────────────────
counts = Counter(t['status'] for t in trackers_to_insert)
print("\nDone. Trackers by status:")
for status, count in sorted(counts.items()):
    print(f"  {status:<42} {count}")

ztp_ns  = sum(1 for t in trackers_to_insert if t['ztp'].get('performed_by') == 'NS')
ztp_fe  = sum(1 for t in trackers_to_insert if t['ztp'].get('performed_by') == 'FE')
sim2f   = sum(1 for t in trackers_to_insert if t['sim']['sim2']['status'] == 'failed')
multi_r = sum(1 for t in trackers_to_insert
              if sum(1 for a in t['hso']['attempts'] if a['action'] == 'rejected') >= 2)

print(f"\nVariants:")
print(f"  ZTP by FE                                  {ztp_fe}")
print(f"  ZTP by NS                                  {ztp_ns}")
print(f"  SIM2 failed (SIM1-only installations)      {sim2f}")
print(f"  Multiple HSO rejections (>=2)              {multi_r}")
print(f"\nTotal: {len(trackers_to_insert)} trackers, {len(chat_msgs_to_insert)} chat messages")
client.close()
