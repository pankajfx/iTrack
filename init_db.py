from pymongo import MongoClient
from datetime import datetime, timezone

# Connect to MongoDB
client = MongoClient('mongodb://localhost:27017/')
db = client['sdwan_tracker']

# Create collections
collections = ['trackers', 'noc_users', 'notifications', 'audit_logs', 'predefined_reasons', 'chat_messages']

for collection in collections:
    if collection not in db.list_collection_names():
        db.create_collection(collection)
        print(f"Created collection: {collection}")

# Create indexes
db.trackers.create_index('sdwan_id', unique=True)
db.trackers.create_index('tracker_id')
db.trackers.create_index('noc_assignee')
db.trackers.create_index('status')
db.trackers.create_index('created_at')

db.noc_users.create_index('username', unique=True)

db.chat_messages.create_index('tracker_id')
db.chat_messages.create_index('timestamp')
db.chat_messages.create_index([('tracker_id', 1), ('timestamp', 1)])

print("Indexes created successfully")

# Insert sample NOC users
noc_users = [
    {
        'username': 'noc_admin',
        'password': 'noc123',  # In production, use hashed passwords
        'name': 'NOC Admin',
        'email': 'noc.admin@example.com',
        'active': True,
        'created_at': datetime.now(timezone.utc)
    },
    {
        'username': 'noc_engineer1',
        'password': 'noc123',
        'name': 'John Doe',
        'email': 'john.doe@example.com',
        'active': True,
        'created_at': datetime.now(timezone.utc)
    },
    {
        'username': 'noc_engineer2',
        'password': 'noc123',
        'name': 'Jane Smith',
        'email': 'jane.smith@example.com',
        'active': True,
        'created_at': datetime.now(timezone.utc)
    }
]

for user in noc_users:
    try:
        db.noc_users.insert_one(user)
        print(f"Created NOC user: {user['username']}")
    except:
        print(f"NOC user already exists: {user['username']}")

# Insert predefined reasons
predefined_reasons = [
    {
        'category': 'sim_activation_failure',
        'reasons': [
            'Incorrect SIM Number',
            'Incorrect SIM Provider',
            'Provider Portal Issue',
            'Network Connectivity Issue',
            'SIM Not Registered',
            'Other'
        ]
    },
    {
        'category': 'ztp_failure',
        'reasons': [
            'Weak Signal',
            'Booster Issue',
            'Incorrect Firmware Info',
            'Configuration Error',
            'Network Timeout',
            'Hardware Issue',
            'Other'
        ]
    },
    {
        'category': 'hso_incomplete',
        'reasons': [
            'Delay due to approval for Single SIM',
            'Delay due to approval for VSAT Only installation',
            'Customer Not Available',
            'Documentation Pending',
            'Technical Issue',
            'Other'
        ]
    },
    {
        'category': 'delay_tags',
        'reasons': [
            'Waiting for Provider Response',
            'Hardware Issue',
            'Site Access Delay',
            'Customer Coordination Delay',
            'Weather Conditions',
            'Power Outage',
            'Other'
        ]
    }
]

for reason_set in predefined_reasons:
    db.predefined_reasons.update_one(
        {'category': reason_set['category']},
        {'$set': reason_set},
        upsert=True
    )
    print(f"Created/Updated predefined reasons for: {reason_set['category']}")

print("\nDatabase initialization completed successfully!")
print("\nDemo Credentials:")
print("FE: fe_user / fe123")
print("NOC: noc_admin / noc123")
